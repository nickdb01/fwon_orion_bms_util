import Foundation
import Testing
import Darwin
@testable import BMSCore

private func reply(_ service: UInt8, _ pid: UInt8, _ data: [UInt8] = []) throws -> WireReply {
    try WireReply(bytes: [UInt8(data.count + 2), service, pid] + data)
}

@Test func requestAllowlistMatchesVendorSerializer() {
    let cases: [(ReadRequest, String)] = [
        (.identify, "02090B"), (.serialNumber, "02090A"), (.firmware, "020904"),
        (.faults(.active), "0103"), (.faults(.stored), "0107"), (.faults(.history), "010A"),
        (.eventHeader, "02B302"), (.event(0), "03B30200"), (.event(49), "03B30231")
    ]
    for (request, body) in cases { #expect(String(data: request.frame, encoding: .ascii) == "\r:\(body)\n\r") }
    #expect(FaultStatus.active.service == 3)
    #expect(FaultStatus.stored.service == 7)
    #expect(FaultStatus.history.service == 10)
}
@Test func parserHandlesFragmentationNoiseAndCoalescing() throws {
    var parser = FrameParser()
    #expect(parser.feed(Data("noise\r\n:0443".utf8)).isEmpty)
    let results = parser.feed(Data("010A9C\r\n:024700\n\r".utf8))
    #expect(results.count == 2)
    #expect(try results[0].get().payload == [0x0A, 0x9C])
    #expect(try results[1].get().pid == 0)
}
@Test func parserRejectsCorruptionAndRecovers() throws {
    for corrupt in [":0G43\r", ":043\n", ":FF43010A9C\r", ":044301\r", ":0103\r", ":037F03\r"] {
        var parser = FrameParser()
        let results = parser.feed(Data((corrupt + ":024300\r").utf8))
        #expect(results.count == 2)
        if case .success = results[0] { Issue.record("Accepted corrupt frame \(corrupt)") }
        #expect(try results[1].get().service == 0x43)
    }
}
@Test func parserBoundsMemoryAndResynchronizes() throws {
    var parser = FrameParser()
    let results = parser.feed(Data((":" + String(repeating: "A", count: 600) + "\r:024300\n").utf8))
    #expect(results.count == 2)
    #expect(try results.last!.get().pid == 0)
}
@Test func dtcCountsPrefixesAndTruncation() throws {
    #expect(DiagnosticDecoder.dtc(0x0A9C) == "P0A9C")
    #expect(DiagnosticDecoder.dtc(0xC100) == "U0100")
    #expect(DiagnosticDecoder.dtc(0x8001) == "B0001")
    #expect(try DiagnosticDecoder.faultCodes(reply(0x43, 2, [0x0A, 0x9C, 0xC1, 0])) == [0x0A9C, 0xC100])
    #expect(throws: BMSError.self) { try DiagnosticDecoder.faultCodes(reply(0x43, 2, [0x0A, 0x9C])) }
    #expect(try DiagnosticDecoder.faultCodes(reply(0x47, 0)).isEmpty)
}
@Test func eventsUseUnsignedBigEndianAndValidateSlotAndLength() throws {
    let data: [UInt8] = [9, 0xFE, 0xDC, 0xBA, 0x98, 4, 0x0A, 0x9C]
    let event = try DiagnosticDecoder.event(reply(0xF3, 2, data), expectedSlot: 9)
    #expect(event.runtimeSeconds == 0xFEDCBA98)
    #expect(event.parameter == 0x0A9C)
    #expect(event.summary.contains("P0A9C"))
    #expect(throws: BMSError.self) { try DiagnosticDecoder.event(reply(0xF3, 2, Array(data.prefix(6))), expectedSlot: 9) }
    #expect(throws: BMSError.self) { try DiagnosticDecoder.event(reply(0xF3, 2, data), expectedSlot: 8) }
    #expect(BMSEvent.formatRuntime(86461) == "1d 00:01:01")
}
@Test func matchingRejectsStaleEventSlotsAndUnrelatedServices() throws {
    #expect(!ReadRequest.event(2).matches(try reply(0xF3, 2, [1, 0, 0, 0, 0, 4, 0x0A, 0x9C])))
    #expect(!ReadRequest.eventHeader.matches(try reply(0xF3, 2, [0, 0, 0, 0, 0, 0, 0, 0])))
    #expect(ReadRequest.faults(.active).matches(try reply(0x43, 0)))
    #expect(!ReadRequest.faults(.active).matches(try reply(0x47, 0)))
}
@Test func deviceIdentificationRejectsWrongProductAndTruncation() throws {
    #expect(try DiagnosticDecoder.signature(reply(0x49, 11, [1] + Array("ORIONBMS08".utf8))) == "ORIONBMS08")
    #expect(try DiagnosticDecoder.signature(reply(0x49, 11, [1] + Array("ORIONBMS04".utf8))) == "ORIONBMS04")
    #expect(throws: BMSError.self) { try DiagnosticDecoder.signature(reply(0x49, 11, [1] + Array("ORIONBMS01".utf8))) }
    #expect(throws: BMSError.self) { try DiagnosticDecoder.signature(reply(0x49, 11, [1] + Array("ORIONBMS99".utf8))) }
    #expect(throws: BMSError.self) { try DiagnosticDecoder.signature(reply(0x49, 11, [1, 2, 3])) }
}
@Test func decodingPreservesUnmappedValuesAndBalancingLowByte() {
    #expect(DiagnosticDecoder.eventDescription(type: 0xEE, parameter: 0xABCD).contains("ABCD"))
    #expect(DiagnosticDecoder.eventDescription(type: 3, parameter: 0x0105).contains("chip temperature"))
    #expect(DiagnosticDecoder.eventDescription(type: 3, parameter: 4) == "Balancing resumed")
}

private final class FaultInjectingTransport: DiagnosticTransport {
    let demo = DemoTransport()
    var fail: ReadRequest?
    var error: Error = BMSError.unsupported(0x11)
    var changedHeader = false
    var headerReads = 0
    var trace: [TraceEntry] { demo.trace }
    func close() { demo.close() }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        if request == fail { throw error }
        if request == .eventHeader {
            headerReads += 1
            if changedHeader && headerReads > 1 { return try reply(0xF3, 2, [6, 1]) }
        }
        return try demo.exchange(request)
    }
}
private func connectedReader(_ t: any DiagnosticTransport) throws -> DiagnosticReader {
    let reader = DiagnosticReader(transport: t)
    _ = try reader.connect(port: "TEST", demo: true)
    return reader
}
@Test func fullDemoRunsProductionReaderAndMergesFaultStates() throws {
    let report = try connectedReader(DemoTransport()).download { _ in }
    #expect(report.isComplete)
    #expect(report.faults.count == 2)
    #expect(report.faults.first(where: { $0.code == "P0A9C" })?.statuses == [.active, .stored])
    #expect(report.events.count == 6)
    #expect(report.events.first?.runtimeSeconds == 432201)
    #expect(report.device.isDemo)
    #expect(report.trace.contains { $0.text == ":03B30205" })
}
@Test func unsupportedFaultSectionDoesNotMasqueradeAsEmptySuccess() throws {
    let t = FaultInjectingTransport(); t.fail = .faults(.stored)
    let report = try connectedReader(t).download { _ in }
    #expect(report.sections[1].state == .unsupported)
    #expect(report.sections[3].state == .complete)
    #expect(!report.isComplete)
}
@Test func eventFailureRetainsPartialRecords() throws {
    let t = FaultInjectingTransport(); t.fail = .event(2); t.error = BMSError.timeout
    let report = try connectedReader(t).download { _ in }
    #expect(report.events.count == 2)
    #expect(report.sections[3].state == .partial)
    #expect(report.finishedAt != nil)
}
@Test func cancelledDownloadRetainsRecordsAndStopsRequests() throws {
    let t = FaultInjectingTransport(); t.fail = .event(3); t.error = CancellationError()
    let report = try connectedReader(t).download { _ in }
    #expect(report.events.count == 3)
    #expect(report.sections[3].state == .cancelled)
    #expect(!report.trace.contains { $0.text == ":03B30204" })
}
@Test func headerChangeMarksUnstableSnapshot() throws {
    let t = FaultInjectingTransport(); t.changedHeader = true
    let report = try connectedReader(t).download { _ in }
    #expect(report.events.count == 6)
    #expect(report.sections[3].state == .changed)
    #expect(!report.isComplete)
}
@Test func jsonAndCSVExportsRoundTripWithDemoAndCompleteness() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try connectedReader(DemoTransport()).download { _ in }
    let destination = try ReportFiles.exportBundle(report, into: root)
    let reopened = try ReportFiles.read(destination.appendingPathComponent("diagnostics.json"))
    #expect(reopened.device == report.device)
    #expect(reopened.events == report.events)
    #expect(reopened.faults == report.faults)
    #expect(reopened.isComplete)
    #expect(try String(contentsOf: destination.appendingPathComponent("events.csv"), encoding: .utf8).contains("432201"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 4)
    #expect(ReportFiles.csvCell("=SUM(A1)") == "\"'=SUM(A1)\"")
    #expect(ReportFiles.csvCell("a,\"b\"\nc") == "\"a,\"\"b\"\"\nc\"")
}
@Test func importingDuplicateSlotsIsRejected() throws {
    var report = try connectedReader(DemoTransport()).download { _ in }
    report.events.append(report.events[0])
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try ReportFiles.json(report).write(to: file)
    #expect(throws: BMSError.self) { try ReportFiles.read(file) }
}

private struct PseudoTerminal: Sendable {
    let master: Int32
    let slave: Int32
    let path: String
    init() throws {
        var m: Int32 = -1, s: Int32 = -1
        guard openpty(&m, &s, nil, nil, nil) == 0, let name = ttyname(s) else { throw BMSError.io("Cannot create test pseudo-terminal") }
        master = m; slave = s; path = String(cString: name)
    }
    func close() { Darwin.close(master); Darwin.close(slave) }
}
@Test func nativeTransportExchangesFragmentedReplyOverPseudoTerminal() async throws {
    let pty = try PseudoTerminal(); defer { pty.close() }
    let transport = try SerialTransport(path: pty.path, timeout: 0.5, requireRTS: false)
    defer { transport.close() }
    let peer = Task.detached {
        var buffer = [UInt8](repeating: 0, count: 100)
        var p = pollfd(fd: pty.master, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 2000) > 0 else { throw BMSError.timeout }
        let n = read(pty.master, &buffer, buffer.count)
        let incoming = String(bytes: buffer.prefix(max(0, n)), encoding: .ascii)
        for part in [":0443", "010A9C\r\n"] {
            let bytes = Array(part.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(pty.master, $0.baseAddress!, $0.count) }
            usleep(10_000)
        }
        return incoming
    }
    let result = try transport.exchange(.faults(.active))
    #expect(try DiagnosticDecoder.faultCodes(result) == [0x0A9C])
    #expect(try await peer.value == "\r:0103\n\r")
}
@Test func nativeTransportTimeoutIsBounded() throws {
    let pty = try PseudoTerminal(); defer { pty.close() }
    let transport = try SerialTransport(path: pty.path, timeout: 0.05, requireRTS: false)
    defer { transport.close() }
    let start = ProcessInfo.processInfo.systemUptime
    #expect(throws: BMSError.timeout) { try transport.exchange(.faults(.active)) }
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    #expect(transport.trace.filter { $0.direction == "TX" }.count == 2)
}
@Test func nativeTransportCancellationIsPrompt() async throws {
    let pty = try PseudoTerminal(); defer { pty.close() }
    let task = Task.detached {
        let transport = try SerialTransport(path: pty.path, timeout: 2, requireRTS: false)
        defer { transport.close() }
        return try transport.exchange(.faults(.active))
    }
    try await Task.sleep(for: .milliseconds(60))
    let start = ProcessInfo.processInfo.systemUptime
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.5)
}

@Test func observedOrionBMS04CanConnectAndDownloadDiagnostics() throws {
    let reader = try connectedReader(DemoTransport(signature: "ORIONBMS04"))
    let report = try reader.download { _ in }
    #expect(report.device.signature == "ORIONBMS04")
    #expect(report.isComplete)
    #expect(report.faults.count == 2)
    #expect(report.events.count == 6)
}

@Test func abnormalStateOfChargeFaultHasDescriptionInFaultsAndEvents() throws {
    let codes = try DiagnosticDecoder.faultCodes(reply(0x43, 1, [0x0A, 0x11]))
    let fault = Fault(rawCode: codes[0], statuses: [.active])
    #expect(fault.code == "P0A11")
    #expect(fault.summary == "Abnormal state of charge behavior")
    #expect(fault.statusText == "Active")
    #expect(DiagnosticDecoder.eventDescription(type: 4, parameter: 0x0A11).contains(fault.summary))
}
