import AppKit
import Observation
import UniformTypeIdentifiers
import BMSCore

enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview = "Overview", cells = "Cells", charts = "Live Charts", recordings = "Recordings", history = "History", diagnostics = "Diagnostics", profile = "Profile"
    var id: String { rawValue }
    var icon: String { switch self { case .overview: "gauge.with.dots.needle.50percent"; case .cells: "square.grid.2x2"; case .charts: "chart.xyaxis.line"; case .recordings: "record.circle"; case .history: "clock.arrow.circlepath"; case .diagnostics: "stethoscope"; case .profile: "doc.text.magnifyingglass" } }
}

enum ChartPreset: String, CaseIterable, Identifiable {
    case packHealth = "Pack Health", charging = "Charging", socInvestigation = "SOC Investigation"
    var id: String { rawValue }
    var keys: Set<String> {
        switch self {
        case .packHealth: ["packVoltage", "packCurrent", "soc", "highTemperature"]
        case .charging: ["packCurrent", "chargeLimit", "soc", "packVoltage"]
        case .socInvestigation: ["soc", "observedSOC", "observedCapacity", "packCurrent", "highCell", "lowCell"]
        }
    }
}

@MainActor @Observable final class AppModel {
    var ports: [SerialPortInfo] = []
    var selectedPort = ""
    var device: DeviceInfo?
    var report: DiagnosticReport?
    var busy = false
    var connecting = false
    var progress = 0.0
    var status = "Connect your BMS to download diagnostics"
    var errorMessage: String?
    var sourceLabel = ""
    var query = ""
    var selectedTab = 0
    var selectedFaultID: UInt16?
    var selectedFaultDetail: FaultDetail?
    var page: WorkspacePage = .overview
    var isMonitoring = false
    var profileSnapshot: ProfileSnapshot?
    var profileDownloading = false
    var profileNeedsPassword = false
    var profileAuthMessage = "Enter the BMS profile password. It will not be saved."
    var history: HistoricalSnapshot?
    var latest: LiveSnapshot?
    var snapshots: [LiveSnapshot] = []
    var cellQuantity: CellQuantity = .voltage
    var chartKeys: Set<String> = ChartPreset.packHealth.keys
    var chartPreset: ChartPreset? { ChartPreset.allCases.first { $0.keys == chartKeys } }
    var chartWindow: Double = 600
    var chartsPaused = false
    var followLiveCharts = true
    var frozenChartSnapshots: [LiveSnapshot] = []
    var recordingURL: URL?
    var openedRecording: RecordedSession?
    var recordingMessages: [String] = []
    var knownRecordings: [URL] = []
    var portRefreshDescription = "Watching for USB serial adapters"
    private var monitoringTask: Task<Void, Never>?
    private var monitorGeneration = UUID()
    private var connectionGeneration = UUID()
    private var shuttingDown = false
    private let service = DiagnosticService()
    private var operation: Task<Void, Never>?
    @ObservationIgnored private let portProvider: () -> [SerialPortInfo]
    init(portProvider: @escaping () -> [SerialPortInfo] = SerialPortInfo.available) {
        self.portProvider = portProvider; refreshPorts()
    }
    func refreshPorts(silent: Bool = false) {
        guard !shuttingDown else { return }
        let found = portProvider()
        let change = PortDiscovery.reconcile(previous: ports, current: found, selected: selectedPort)
        ports = found; selectedPort = change.selectedPath
        if !change.added.isEmpty { portRefreshDescription = "Detected: " + change.added.map(\.name).joined(separator: ", ") }
        else if !silent { portRefreshDescription = "Refreshed \(Date().formatted(date: .omitted, time: .standard)) · \(found.count) serial ports" }
        if let info = device, !info.isDemo, !found.contains(where: { $0.path == info.port }) {
            operation?.cancel(); stopMonitoring(); connectionGeneration = UUID()
            device = nil; status = "USB adapter disconnected · collected data retained"
            Task { await service.disconnect(); recordingURL = nil }
        }
    }
    func watchConnections() async {
        refreshPorts(silent: true)
        while !Task.isCancelled, !shuttingDown {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            refreshPorts(silent: true)
        }
    }
    func reconnect() {
        guard !shuttingDown else { return }
        guard !shuttingDown, !busy, let info = device else { refreshPorts(); return }
        stopMonitoring(); busy = true
        operation = Task {
            await service.disconnect(); recordingURL = nil; device = nil; busy = false
            if !info.isDemo { selectedPort = info.port }
            connect(demo: info.isDemo)
        }
    }
    func connect(demo: Bool = false, demoProfilePassword: String? = nil) {
        guard !shuttingDown, !busy, device == nil else { return }
        busy = true; connecting = true; errorMessage = nil; progress = 0
        status = demo ? "Opening the offline demo…" : "Identifying the BMS…"
        let path = selectedPort
        let generation = UUID(); connectionGeneration = generation
        operation = Task {
            defer { busy = false; connecting = false; operation = nil }
            do {
                let connected = try await service.connect(path: path, demo: demo, demoProfilePassword:demoProfilePassword)
                try Task.checkCancellation()
                guard generation == connectionGeneration else { throw CancellationError() }
                device = connected; profileSnapshot = nil; profileNeedsPassword = false; report = nil; sourceLabel = ""; query = ""
                status = demo ? "Demo connected — all records are synthetic" : "Connected · ready to download"
                latest = nil; snapshots = []; openedRecording = nil; page = demoProfilePassword == nil ? .overview : .profile
                startMonitoring(force: true)
            } catch {
                await service.disconnect()
                device = nil
                if error is CancellationError { status = "Connection cancelled" }
                else { errorMessage = error.localizedDescription; status = "Connection failed" }
            }
        }
    }
    func download() {
        guard !shuttingDown, !busy, device != nil else { return }
        let resume = isMonitoring
        stopMonitoring(); page = .diagnostics
        busy = true; progress = 0; errorMessage = nil; status = "Starting download…"
        operation = Task {
            defer { busy = false; operation = nil; if resume && device != nil { startMonitoring() } }
            do {
                let snapshot = try await service.download { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy else { return }
                        self.progress = update.fraction; self.status = update.message
                    }
                }
                if !(await service.isConnected()) { device = nil }
                selectedFaultID = nil; selectedFaultDetail = nil
                report = snapshot; sourceLabel = "Downloaded \(snapshot.acquiredAt.formatted(date: .abbreviated, time: .standard))"
                progress = 1
                status = snapshot.isComplete ? "Download complete" : "Download finished — review section status"
            } catch {
                if error is CancellationError { status = "Download cancelled" }
                else { errorMessage = error.localizedDescription; status = "Download failed" }
            }
        }
    }
    func cancel() { operation?.cancel(); status = "Cancelling…" }
    func disconnect() {
        guard !shuttingDown, !busy else { return }
        stopMonitoring(); connectionGeneration = UUID()
        busy = true
        operation = Task {
            await service.disconnect(); recordingURL = nil; device = nil; busy = false; operation = nil
            status = report == nil ? "Disconnected" : "Disconnected · downloaded records retained"
        }
    }
    func openReport() {
        guard !shuttingDown, !busy, device == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Open an Orion Diagnostics JSON export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            report = try ReportFiles.read(url)
            selectedFaultID = nil; selectedFaultDetail = nil
            sourceLabel = url.lastPathComponent + " · offline report"
            page = .diagnostics
            status = "Opened saved diagnostics"; errorMessage = nil; query = ""
        } catch { errorMessage = error.localizedDescription }
    }
    func saveJSON() {
        guard let report = reportForExport(), !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = report.device.isDemo ? "Orion-DEMO.json" : "Orion-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ReportFiles.json(report).write(to: url, options: .atomic); status = "Saved \(url.lastPathComponent)" }
        catch { errorMessage = error.localizedDescription }
    }
    func export() {
        guard let report = reportForExport(), !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Export here"
        panel.message = "A new folder will contain the JSON report, fault and event CSVs, and download status."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try ReportFiles.exportBundle(report, into: url)
            status = "Exported \(result.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([result])
        } catch { errorMessage = error.localizedDescription }
    }
    var filteredFaults: [Fault] {
        (report?.faults ?? []).filter { query.isEmpty || "\($0.code) \($0.summary) \($0.statusText)".localizedCaseInsensitiveContains(query) }
    }
    var filteredEvents: [BMSEvent] {
        (report?.events ?? []).filter { query.isEmpty || "\($0.summary) \($0.runtime) \($0.rawText) \($0.slot)".localizedCaseInsensitiveContains(query) }
    }
}


extension AppModel {
    func startMonitoring(force: Bool = false) {
        guard (!busy || force), !shuttingDown, device != nil, monitoringTask == nil else { return }
        let generation = UUID(); monitorGeneration = generation
        if openedRecording != nil { snapshots = []; latest = nil; chartsPaused = false }
        isMonitoring = true; openedRecording = nil
        monitoringTask = Task {
            defer { if monitorGeneration == generation { isMonitoring = false; monitoringTask = nil } }
            while !Task.isCancelled, device != nil, monitorGeneration == generation {
                do {
                    let sample = try await service.sample(quantity: cellQuantity)
                    try Task.checkCancellation()
                    guard monitorGeneration == generation else { return }
                    latest = sample; snapshots.append(sample)
                    if snapshots.count > 2000 { snapshots.removeFirst(snapshots.count - 2000) }
                    if !busy { status = "Live · acquired " + sample.finishedAt.formatted(date: .omitted, time: .standard) }
                } catch {
                    if error is CancellationError || Task.isCancelled || monitorGeneration != generation { return }
                    if case .invalid = error as? BMSError {
                        try? await service.stopRecording(); recordingURL = nil
                        status = "Monitoring paused · " + error.localizedDescription
                        return
                    } else if case .io(let note) = error as? BMSError, note.hasPrefix("Recording stopped:") {
                        recordingURL = nil; errorMessage = note
                    } else {
                        await service.disconnect(); device = nil; recordingURL = nil
                        status = "Live connection lost · " + error.localizedDescription
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func stopMonitoring() {
        monitorGeneration = UUID(); monitoringTask?.cancel(); monitoringTask = nil; isMonitoring = false
    }
    func toggleChartPause() {
        if !chartsPaused { frozenChartSnapshots = snapshots }
        chartsPaused.toggle()
    }
    func startRecording() {
        guard !shuttingDown, device != nil, recordingURL == nil, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "orionlog") ?? .data]
        panel.nameFieldStringValue = device?.isDemo == true ? "Orion-DEMO.orionlog" : "Orion-Recording.orionlog"
        panel.message = "Records acquired values and timestamps to disk. Pausing charts does not pause recording. Maximum file size: 100 MB."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await service.startRecording(at: url); recordingURL = url
                if !knownRecordings.contains(url) { knownRecordings.insert(url, at: 0) }
                startMonitoring(force: true); status = "Recording to " + url.lastPathComponent
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func stopRecording() {
        guard !shuttingDown, recordingURL != nil, !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil; recordingURL = nil }
            do { try await service.stopRecording(); status = "Recording saved" }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func openRecording(url supplied: URL? = nil) {
        guard !shuttingDown, !busy, recordingURL == nil else { return }
        let url: URL
        if let supplied { url = supplied }
        else {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "orionlog") ?? .data]
            guard panel.runModal() == .OK, let selected = panel.url else { return }; url = selected
        }
        stopMonitoring(); busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let session = try await service.loadRecording(url)
                if session.snapshots.last?.cells.first?.resistance != nil { cellQuantity = .resistance }
                else if session.snapshots.last?.cells.first?.openVoltage != nil { cellQuantity = .openVoltage }
                else { cellQuantity = .voltage }
                openedRecording = session; snapshots = session.snapshots; latest = session.snapshots.last
                recordingMessages = session.messages; chartsPaused = false; page = .charts
                if !knownRecordings.contains(url) { knownRecordings.insert(url, at: 0) }
                status = "Offline recording · \(session.totalSamples) samples"
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func exportLiveCSV() {
        guard !snapshots.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Orion-Telemetry.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = snapshots
        busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await Task.detached { try RecordingFiles.exportCSV(data, to: url) }.value
                status = "Exported visible session buffer · \(data.count) samples"
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

extension AppModel {
    func downloadHistory() {
        guard !shuttingDown, !busy, device != nil else { return }
        let resume = isMonitoring; stopMonitoring(); busy = true
        operation = Task {
            defer { busy = false; operation = nil; if resume && device != nil { startMonitoring() } }
            do { history = try await service.readHistory(); status = "Historical statistics downloaded" }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func exportHistory() {
        guard let history else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Orion-History.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(history).write(to:url,options:.atomic)
        } catch { errorMessage = error.localizedDescription }
    }
}

extension AppModel {
    func prepareToQuit() async {
        shuttingDown = true
        connectionGeneration = UUID()
        let pendingOperation = operation
        let pendingMonitoring = monitoringTask
        pendingOperation?.cancel(); stopMonitoring()
        // Let cancelled profile reads re-lock before closing the transport, and
        // prevent their completion handlers racing with the final disconnect.
        await pendingOperation?.value
        await pendingMonitoring?.value
        do { try await service.stopRecording() } catch { recordingMessages.append(error.localizedDescription) }
        await service.disconnect(); recordingURL = nil; device = nil
        profileNeedsPassword = false
    }
}

extension AppModel {
    func downloadFaultDetail() {
        guard !shuttingDown, !busy, device != nil, let code = selectedFaultID else { return }
        let resume = isMonitoring; stopMonitoring(); busy = true; progress = 0
        operation = Task {
            defer { busy = false; operation = nil; if resume && device != nil { startMonitoring() } }
            do {
                let result = try await service.readFaultDetail(code:code) { [weak self] update in
                    Task { @MainActor [weak self] in if let self, self.busy { self.progress = update.fraction; self.status = update.message } }
                }
                if !(await service.isConnected()) { device = nil }
                selectedFaultDetail = result
                var details = report?.faultDetails ?? []
                details.removeAll { $0.rawCode == code }; details.append(result); report?.faultDetails = details
                status = "Fault detail: " + result.state.label.lowercased() + " · review values and notes"
            } catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
        }
    }
}

extension AppModel {
    private func reportForExport() -> DiagnosticReport? {
        guard var copy = report else { return nil }
        func matches(_ info: DeviceInfo) -> Bool {
            info.signature == copy.device.signature && info.isDemo == copy.device.isDemo && info.serialNumber != nil && info.serialNumber == copy.device.serialNumber
        }
        if let latest, matches(latest.device), abs(latest.finishedAt.timeIntervalSince(copy.acquiredAt)) < 300 { copy.liveSnapshot = latest }
        if let history, matches(history.device), abs(history.acquiredAt.timeIntervalSince(copy.acquiredAt)) < 300 { copy.historySnapshot = history }
        let note = "Additional snapshots retain their own acquisition timestamps; this is not an atomic device snapshot."
        if (copy.liveSnapshot != nil || copy.historySnapshot != nil) && !copy.notes.contains(note) { copy.notes.append(note) }
        return copy
    }
}

extension AppModel {
    func downloadProfile(password: String? = nil) {
        guard !shuttingDown, !busy, device != nil else { return }
        let resume = isMonitoring
        stopMonitoring(); busy = true; profileDownloading = true; progress = 0
        profileNeedsPassword = false; errorMessage = nil
        operation = Task {
            defer {
                busy = false; profileDownloading = false; operation = nil
                if resume && device != nil { startMonitoring() }
            }
            do {
                let result = try await service.readProfile(password:password) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.profileDownloading else { return }
                        self.progress = update.fraction; self.status = update.message
                    }
                }
                profileSnapshot = result; progress = 1
                status = result.device.isDemo ? "Synthetic demo profile downloaded" : "Profile downloaded · settings unchanged"
            } catch {
                if !(await service.isConnected()) { device = nil }
                if let access = error as? ProfileAccessError {
                    switch access {
                    case .passwordRequired, .invalidPassword, .passwordFormat:
                        profileAuthMessage = access.localizedDescription
                        profileNeedsPassword = device != nil
                        status = "Profile locked · password required"
                    default: errorMessage = access.localizedDescription; status = "Profile download failed"
                    }
                } else if error is CancellationError { status = "Profile download cancelled · previous profile retained" }
                else { errorMessage = error.localizedDescription; status = "Profile download failed · previous profile retained" }
            }
        }
    }
    func exportProfile() {
        guard let profileSnapshot, !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Orion-Profile.json"
        panel.message = "Saves the complete downloaded profile and decoded core settings. This is a read-only backup, not a vendor .j2bms upload file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(profileSnapshot).write(to:url,options:.atomic)
            status = "Profile backup saved locally"
        } catch { errorMessage = error.localizedDescription }
    }
}
