import Foundation

public enum BMSError: Error, LocalizedError, Equatable, Sendable {
    case io(String), timeout, invalid(String), unsupported(UInt8), rejected(UInt8), wrongDevice(String), disconnected
    public var errorDescription: String? {
        switch self {
        case .io(let text): text
        case .timeout: "No valid reply. Check BMS power, the selected port, and the adapter’s RTS wiring. Close other serial utilities."
        case .invalid(let text): "Invalid BMS reply: \(text)"
        case .unsupported(let code): String(format: "Unsupported diagnostic request (0x%02X).", code)
        case .rejected(let code): String(format: "BMS rejected the request (0x%02X).", code)
        case .wrongDevice(let name): "Device identification ‘\(name)’ is not a recognized Orion Junior signature."
        case .disconnected: "The serial device disconnected. Reconnect the adapter and BMS."
        }
    }
}

public enum FaultStatus: String, Codable, CaseIterable, Sendable {
    // Vendor UI labels, verified in ScannerDTCMap. These differ from generic OBD labels.
    case active = "Active", stored = "Stored", history = "History"
    public var service: UInt8 { switch self { case .active: 3; case .stored: 7; case .history: 10 } }
}
public struct Fault: Codable, Identifiable, Equatable, Sendable {
    public var rawCode: UInt16
    public var statuses: [FaultStatus]
    public var id: UInt16 { rawCode }
    public var code: String { DiagnosticDecoder.dtc(rawCode) }
    public var summary: String { DiagnosticDecoder.faultDescription(code) }
    public var statusText: String { statuses.map(\.rawValue).joined(separator: ", ") }
}
public struct BMSEvent: Codable, Identifiable, Equatable, Sendable {
    public var slot: UInt8
    public var runtimeSeconds: UInt32
    public var type: UInt8
    public var parameter: UInt16
    public var id: UInt8 { slot }
    public var summary: String { DiagnosticDecoder.eventDescription(type: type, parameter: parameter) }
    public var runtime: String { Self.formatRuntime(runtimeSeconds) }
    public var rawText: String { String(format: "0x%02X / 0x%04X", type, parameter) }
    public static func formatRuntime(_ value: UInt32) -> String {
        let n = UInt64(value)
        return String(format: "%llud %02llu:%02llu:%02llu", n / 86400, n / 3600 % 24, n / 60 % 60, n % 60)
    }
}
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var signature: String
    public var serialNumber: String?
    public var firmware: String?
    public var port: String
    public var isDemo: Bool
    public var metadataNotes: [String] = []
}
public enum SectionState: String, Codable, Sendable {
    case notRead, reading, complete, partial, unsupported, failed, cancelled, changed
    public var label: String {
        switch self {
        case .notRead: "Not downloaded"
        case .reading: "Downloading"
        case .complete: "Complete"
        case .partial: "Partial"
        case .unsupported: "Unsupported"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .changed: "Log changed during download"
        }
    }
}
public struct SectionResult: Codable, Equatable, Sendable {
    public var name: String
    public var state: SectionState = .notRead
    public var detail: String = ""
}
public struct TraceEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var time = Date()
    public var direction: String
    public var text: String
    public init(direction: String, text: String) { self.direction = direction; self.text = text }
}
public struct DiagnosticReport: Codable, Sendable {
    public var schemaVersion = 1
    public static let currentAppVersion = "0.4.1"
    public var appVersion = DiagnosticReport.currentAppVersion
    public var sessionID = UUID()
    public var acquiredAt = Date()
    public var finishedAt: Date?
    public var timeZone = TimeZone.current.identifier
    public var device: DeviceInfo
    public var liveSnapshot: LiveSnapshot? = nil
    public var historySnapshot: HistoricalSnapshot? = nil
    public var faultDetails: [FaultDetail]? = nil
    public var faults: [Fault] = []
    public var events: [BMSEvent] = []
    public var sections: [SectionResult] = FaultStatus.allCases.map { SectionResult(name: $0.rawValue + " faults") } + [SectionResult(name: "Recent events")]
    public var eventHeaderBefore: [UInt8]?
    public var eventHeaderAfter: [UInt8]?
    public var trace: [TraceEntry] = []
    public var notes = ["Event times are cumulative BMS operating seconds, not calendar dates.", "Selected fault details are included when downloaded separately."]
    public var isComplete: Bool { sections.allSatisfy { $0.state == .complete } }
    public init(device: DeviceInfo) { self.device = device }
}
public struct DownloadProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}
