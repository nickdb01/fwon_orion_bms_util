import Foundation

public enum ReportFiles {
    public static func json(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
    public static func read(_ url: URL) throws -> DiagnosticReport {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 16_000_001) ?? Data()
        guard data.count <= 16_000_000 else { throw BMSError.invalid("report file exceeds 16 MB") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        guard report.schemaVersion == 1, report.sections.count == 4,
              report.events.count <= 255, report.faults.count <= 768,
              (report.liveSnapshot?.readings.count ?? 0) <= 100,
              (report.historySnapshot?.statistics.count ?? 0) <= 100,
              (report.faultDetails?.count ?? 0) <= 256,
              report.faultDetails?.allSatisfy({ $0.readings.count <= 100 && $0.rawReplies.count <= 500 }) ?? true,
              report.trace.count <= 20_000,
              Set(report.events.map(\.slot)).count == report.events.count,
              Set(report.faults.map(\.rawCode)).count == report.faults.count else {
            throw BMSError.invalid("unsupported schema or inconsistent report records")
        }
        return report
    }
    public static func csvCell(_ value: String) -> String {
        // Prevent spreadsheet formula execution when a field came from device/file data.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = ["=", "+", "-", "@"].contains(String(trimmed.prefix(1))) ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    public static func faultsCSV(_ report: DiagnosticReport) -> String {
        csv([["code", "description", "vendor_status", "raw_code", "demo", "download_time"]] + report.faults.map {
            [$0.code, $0.summary, $0.statusText, String(format: "%04X", $0.rawCode), String(report.device.isDemo), report.acquiredAt.ISO8601Format()]
        })
    }
    public static func eventsCSV(_ report: DiagnosticReport) -> String {
        csv([["slot", "bms_runtime_seconds", "runtime_display", "event", "type_hex", "parameter_hex", "demo", "download_time"]] + report.events.map {
            [String($0.slot), String($0.runtimeSeconds), $0.runtime, $0.summary, String(format: "%02X", $0.type), String(format: "%04X", $0.parameter), String(report.device.isDemo), report.acquiredAt.ISO8601Format()]
        })
    }
    public static func sectionsCSV(_ report: DiagnosticReport) -> String {
        csv([["section", "state", "detail", "demo"]] + report.sections.map {
            [$0.name, $0.state.label, $0.detail, String(report.device.isDemo)]
        })
    }
    @discardableResult public static func exportBundle(_ report: DiagnosticReport, into parent: URL) throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = report.device.isDemo ? "Orion-DEMO" : "Orion-Diagnostics"
        let destination = parent.appendingPathComponent("\(prefix)-\(formatter.string(from: report.acquiredAt))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try json(report).write(to: destination.appendingPathComponent("diagnostics.json"), options: .atomic)
            try faultsCSV(report).write(to: destination.appendingPathComponent("faults.csv"), atomically: true, encoding: .utf8)
            try eventsCSV(report).write(to: destination.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
            try sectionsCSV(report).write(to: destination.appendingPathComponent("download-status.csv"), atomically: true, encoding: .utf8)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
}
