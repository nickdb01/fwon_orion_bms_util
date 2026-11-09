import Foundation

final class DiagnosticReader {
    let transport: any DiagnosticTransport
    private(set) var device: DeviceInfo?
    init(transport: any DiagnosticTransport) { self.transport = transport }
    func connect(port: String, demo: Bool) throws -> DeviceInfo {
        do {
            let reply = try transport.exchange(.identify)
            let signature = try DiagnosticDecoder.signature(reply)
            var info = DeviceInfo(signature: signature, port: port, isDemo: demo)
            do {
                let value = try transport.exchange(.serialNumber)
                guard value.payload.first == 0 else { throw BMSError.invalid("serial number belongs to a remote device") }
                info.serialNumber = try DiagnosticDecoder.ascii(value.payload, range: 1..<9)
            } catch {
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                info.metadataNotes.append("Serial number: " + error.localizedDescription)
            }
            do {
                let value = try transport.exchange(.firmware)
                info.firmware = try DiagnosticDecoder.ascii(value.payload, range: 1..<7)
            } catch {
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                info.metadataNotes.append("Firmware: " + error.localizedDescription)
            }
            device = info
            return info
        } catch { transport.close(); device = nil; throw error }
    }
    func download(progress: @Sendable (DownloadProgress) -> Void) throws -> DiagnosticReport {
        guard let device else { throw BMSError.disconnected }
        var report = DiagnosticReport(device: device)
        if device.isDemo { report.notes.insert("SYNTHETIC DEMO — this report contains no measurements from a real BMS.", at: 0) }
        var stop = false
        for (index, status) in FaultStatus.allCases.enumerated() {
            if stop { continue }
            progress(.init(Double(index) / 4, "Downloading \(status.rawValue.lowercased()) faults…"))
            report.sections[index].state = .reading
            do {
                try Task.checkCancellation()
                let codes = try DiagnosticDecoder.faultCodes(transport.exchange(.faults(status)))
                for code in codes {
                    if let i = report.faults.firstIndex(where: { $0.rawCode == code }) {
                        if !report.faults[i].statuses.contains(status) { report.faults[i].statuses.append(status) }
                    } else { report.faults.append(Fault(rawCode: code, statuses: [status])) }
                }
                report.sections[index].state = .complete
                report.sections[index].detail = "\(codes.count) codes returned"
            } catch {
                report.sections[index] = failure(error, name: report.sections[index].name)
                stop = error is CancellationError || (error as? BMSError) == .disconnected
            }
        }
        if !stop {
            let i = 3
            report.sections[i].state = .reading
            progress(.init(0.75, "Reading the recent-event buffer…"))
            do {
                try Task.checkCancellation()
                let header = try transport.exchange(.eventHeader).payload
                guard header.count == 2 else { throw BMSError.invalid("event header must contain capacity and write pointer") }
                report.eventHeaderBefore = header
                let count = Int(header[0])
                for index in 0..<count {
                    try Task.checkCancellation()
                    let slot = UInt8(index)
                    let reply = try transport.exchange(.event(slot))
                    report.events.append(try DiagnosticDecoder.event(reply, expectedSlot: slot))
                    progress(.init(0.75 + 0.24 * Double(index + 1) / Double(max(1, count)), "Downloading event slot \(index + 1) of \(count)…"))
                }
                try Task.checkCancellation()
                report.eventHeaderAfter = try transport.exchange(.eventHeader).payload
                if report.eventHeaderBefore != report.eventHeaderAfter {
                    report.sections[i].state = .changed
                    report.sections[i].detail = "The event buffer changed while it was being read. Download again for a fresh snapshot."
                } else {
                    report.sections[i].state = .complete
                    report.sections[i].detail = "\(count) buffer slots read; all raw records retained."
                }
            } catch {
                report.sections[i] = failure(error, name: "Recent events")
                if !report.events.isEmpty && report.sections[i].state == .failed { report.sections[i].state = .partial }
            }
        }
        report.faults.sort { $0.code < $1.code }
        report.events.sort { a, b in a.runtimeSeconds == b.runtimeSeconds ? a.slot < b.slot : a.runtimeSeconds > b.runtimeSeconds }
        report.finishedAt = Date()
        report.trace = transport.trace
        progress(.init(1, report.isComplete ? "Diagnostics downloaded" : "Download finished with incomplete sections"))
        return report
    }
    private func failure(_ error: Error, name: String) -> SectionResult {
        if (error as? BMSError) == .disconnected { transport.close(); device = nil }
        var state: SectionState = .failed
        if error is CancellationError { state = .cancelled }
        if case .unsupported = error as? BMSError { state = .unsupported }
        return .init(name: name, state: state, detail: error is CancellationError ? "Download cancelled; records received so far were retained." : error.localizedDescription)
    }
    func close() { transport.close(); device = nil }
}

// Owns the port on a background actor. A download has no suspension points, so
// requests cannot interleave. Cancellation is checked at <=50 ms I/O intervals.
public actor DiagnosticService {
    private var reader: DiagnosticReader?
    private var liveReader: LiveReader?
    private var recorder: RecordingWriter?
    public init() {}
    public func connect(path: String, demo: Bool = false, demoProfilePassword: String? = nil) throws -> DeviceInfo {
        reader?.close(); reader = nil; liveReader = nil
        let transport: any DiagnosticTransport
        if demo { transport = DemoTransport(profilePassword:demoProfilePassword) }
        else {
            guard SerialPortInfo.available().contains(where: { $0.path == path }) else {
                throw BMSError.io("The selected serial port is no longer available. Refresh the port list.")
            }
            transport = try SerialTransport(path: path)
        }
        let candidate = DiagnosticReader(transport: transport)
        let device = try candidate.connect(port: demo ? "Demo (no hardware)" : path, demo: demo)
        reader = candidate
        liveReader = LiveReader(transport: transport)
        return device
    }
    public func download(progress: @Sendable (DownloadProgress) -> Void) throws -> DiagnosticReport {
        guard let reader else { throw BMSError.disconnected }
        try recorder?.note("Live polling paused for diagnostic download")
        return try reader.download(progress: progress)
    }
    public func readFaultDetail(code: UInt16, progress: @Sendable (DownloadProgress) -> Void) throws -> FaultDetail {
        guard let reader else { throw BMSError.disconnected }
        try recorder?.note("Live polling paused for frozen fault detail")
        return try reader.faultDetail(code:code,progress:progress)
    }
    public func readHistory() throws -> HistoricalSnapshot {
        guard let reader, let info = reader.device else { throw BMSError.disconnected }
        try recorder?.note("Live polling paused for historical statistics")
        return try HistoricalSnapshot.decode(reader.transport.exchange(.history), device:info)
    }
    public func readProfile(password: String? = nil, progress: @Sendable (DownloadProgress) -> Void) throws -> ProfileSnapshot {
        guard let reader, let device = reader.device else { throw BMSError.disconnected }
        try recorder?.note("Live polling paused for profile download")
        do { return try ProfileReader(transport:reader.transport).read(device:device,password:password,progress:progress) }
        catch {
            if case ProfileAccessError.relockFailed = error { reader.close() }
            if (error as? BMSError) == .disconnected { reader.close() }
            throw error
        }
    }
    public func isConnected() -> Bool { reader?.device != nil }
    public func disconnect() {
        try? recorder?.note("Disconnected; recording ended")
        try? recorder?.finish(); recorder = nil
        reader?.close(); reader = nil; liveReader = nil
    }
    public func sample(quantity: CellQuantity = .voltage) throws -> LiveSnapshot {
        guard let info = reader?.device, let liveReader else { throw BMSError.disconnected }
        let snapshot = try liveReader.sample(device: info, quantity: quantity)
        do { try recorder?.append(snapshot) }
        catch { try? recorder?.finish(); recorder = nil; throw BMSError.io("Recording stopped: " + error.localizedDescription) }
        return snapshot
    }
    public func startRecording(at url: URL) throws {
        guard let info = reader?.device else { throw BMSError.disconnected }
        guard recorder == nil else { throw BMSError.io("A recording is already active") }
        recorder = try RecordingWriter(url: url, device: info)
    }
    public func stopRecording() throws { defer { recorder = nil }; try recorder?.finish() }
    public func loadRecording(_ url: URL) throws -> RecordedSession { try RecordingFiles.read(url) }

}
