import Foundation

public struct RecordingLine: Codable, Sendable {
    public var kind: String
    public var time = Date()
    public var schemaVersion = 1
    public var device: DeviceInfo?
    public var snapshot: LiveSnapshot?
    public var message: String?
}
public struct RecordedSession: Sendable {
    public var device: DeviceInfo
    public var snapshots: [LiveSnapshot]
    public var totalSamples: Int
    public var messages: [String]
    public var url: URL
}
final class RecordingWriter {
    let url: URL
    private let file: FileHandle
    private let encoder: JSONEncoder
    private var bytesWritten = 0
    private var closed = false
    private var samples = 0
    init(url: URL, device: DeviceInfo) throws {
        self.url = url
        // The caller uses NSSavePanel for any overwrite approval.
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw BMSError.io("Cannot create recording file") }
        file = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder(); RecordingDates.configure(encoder)
        try write(.init(kind: "header", device: device, message: device.isDemo ? "SYNTHETIC DEMO" : "Host acquisition timestamps; BMS runtime events have separate timestamps."))
    }
    deinit { try? file.close() }
    private func write(_ line: RecordingLine) throws {
        guard !closed else { throw BMSError.io("Recording is closed") }
        let bytes = try encoder.encode(line) + Data([10])
        guard bytesWritten + bytes.count <= 100_000_000 else { throw BMSError.io("Recording reached its 100 MB limit. Start another file.") }
        try file.write(contentsOf: bytes); bytesWritten += bytes.count
    }
    func append(_ snapshot: LiveSnapshot) throws {
        try write(.init(kind: "sample", snapshot: snapshot)); samples += 1
        if samples % 10 == 0 { try file.synchronize() }
    }
    func note(_ message: String) throws { try write(.init(kind: "gap", message: message)); try file.synchronize() }
    func finish() throws {
        guard !closed else { return }
        do {
            try write(.init(kind: "footer", message: "\(samples) samples recorded"))
            try file.synchronize(); try file.close(); closed = true
        } catch { closed = true; try? file.close(); throw error }
    }
}
public enum RecordingFiles {
    public static func read(_ url: URL, retain: Int = 2000) throws -> RecordedSession {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let decoder = JSONDecoder(); RecordingDates.configure(decoder)
        var pending = Data(), device: DeviceInfo?, snapshots: [LiveSnapshot] = [], messages: [String] = []
        var total = 0, footer = false, bytesRead = 0
        func consume(_ data: Data) throws {
            let line = try decoder.decode(RecordingLine.self, from: data)
            guard line.schemaVersion == 1 else { throw BMSError.invalid("unsupported recording version") }
            switch line.kind {
            case "header":
                guard device == nil, let info = line.device else { throw BMSError.invalid("invalid recording header") }
                device = info
            case "sample":
                guard let info = device, let snapshot = line.snapshot,
                      snapshot.device == info, snapshot.readings.count <= 100, snapshot.cells.count <= 16,
                      snapshot.cells.allSatisfy({ (1...16).contains($0.number) && ($0.voltage?.isFinite ?? true) && ($0.resistance?.isFinite ?? true) && ($0.openVoltage?.isFinite ?? true) }),
                      snapshot.readings.allSatisfy({ $0.value?.isFinite ?? true }),
                      Set(snapshot.readings.map(\.key)).count == snapshot.readings.count,
                      Set(snapshot.cells.map(\.number)).count == snapshot.cells.count else { throw BMSError.invalid("invalid recording sample") }
                total += 1; snapshots.append(snapshot)
                if snapshots.count > retain { snapshots.removeFirst() }
            case "gap": if let note = line.message { messages.append(note) }
            case "footer": footer = true
            default: throw BMSError.invalid("unrecognized recording entry")
            }
        }
        while let block = try file.read(upToCount: 65536), !block.isEmpty {
            try Task.checkCancellation()
            bytesRead += block.count
            guard bytesRead <= 100_000_000 else { throw BMSError.invalid("recording exceeds 100 MB") }
            pending.append(block)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard line.count <= 1_000_000 else { throw BMSError.invalid("recording line too large") }
                if !line.isEmpty { try consume(line) }
            }
            guard pending.count <= 1_000_000 else { throw BMSError.invalid("recording line too large") }
        }
        if !pending.isEmpty { messages.append("An incomplete final line was ignored; earlier samples were recovered.") }
        if !footer { messages.append("Recording ended without a clean footer; saved complete samples were recovered.") }
        guard let device else { throw BMSError.invalid("recording has no device header") }
        if total > snapshots.count { messages.append("Showing the latest \(snapshots.count) of \(total) saved samples; the original file retains all samples.") }
        return RecordedSession(device: device, snapshots: snapshots, totalSamples: total, messages: messages, url: url)
    }
    public static func exportCSV(_ snapshots: [LiveSnapshot], to url: URL) throws {
        let keys = ParameterPID.allCases.filter { $0 != .maximumCells }
        let heading = ["acquisition_utc","device_serial","demo"] + keys.flatMap { [$0.key, $0.key + "_acquired_utc", $0.key + "_status"] }
        var lines = [heading.map(ReportFiles.csvCell).joined(separator: ",")]
        for snapshot in snapshots {
            var row = [RecordingDates.format(snapshot.finishedAt),snapshot.device.serialNumber ?? "", String(snapshot.device.isDemo)]
            for key in keys {
                let reading = snapshot.reading(key)
                row += [reading?.value.map { String($0) } ?? "", reading.map { RecordingDates.format($0.acquiredAt) } ?? "", reading?.note ?? (reading?.value == nil ? "Unavailable" : "Measured")]
            }
            lines.append(row.map { field in
                if let number = Double(field), number.isFinite { return "\"" + field + "\"" }
                return ReportFiles.csvCell(field)
            }.joined(separator: ","))
        }
        try (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum RecordingDates {
    static func format(_ date: Date) -> String {
        ISO8601DateFormatter.string(from:date,timeZone:TimeZone(secondsFromGMT:0)!,formatOptions:[.withInternetDateTime,.withFractionalSeconds])
    }
    static func configure(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer(); try value.encode(format(date))
        }
    }
    static func configure(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            if let date = parser.date(from:value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            if let date = parser.date(from:value) { return date }
            throw BMSError.invalid("invalid acquisition timestamp")
        }
    }
}
