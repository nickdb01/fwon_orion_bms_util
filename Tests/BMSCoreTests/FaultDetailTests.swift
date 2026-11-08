import Foundation
import Testing
@testable import BMSCore

@Test func frozenFaultRequestsMatchVendorServiceAndPIDWidths() throws {
    #expect(ReadRequest.subcodes(0x0A11).body.hex == "04170A1100")
    #expect(ReadRequest.freezeDirectory(3).body.hex == "0402030102")
    #expect(ReadRequest.freezeParameter(3,.packVoltage).body.hex == "05020322F00D")
    let subcodes = try WireReply(bytes:[10,0x57,0x0A,0x11,0,1,0,0,0,0,0])
    #expect(try FaultDetail.decodeSubcodes(subcodes,code:0x0A11) == [0x100,0,0])
    #expect(throws: BMSError.self) { try FaultDetail.decodeSubcodes(subcodes,code:0x0A9C) }
}
@Test func frozenValuesValidateTrailingParameterAndPreserveCurrentSign() throws {
    let current = try WireReply(bytes:[7,0x42,1,0xFF,0x9C,0x22,0xF0,0x0C])
    let reading = try FaultDetail.decodeReading(current,parameter:.packCurrent,frame:1)
    #expect(reading.value == -10)
    #expect(!ReadRequest.freezeParameter(1,.packVoltage).matches(current))
    #expect(ReadRequest.freezeParameter(1,.packCurrent).matches(current))
    #expect(throws: BMSError.self) { try FaultDetail.decodeReading(current,parameter:.packVoltage,frame:1) }
    let directory = try WireReply(bytes:[6,0x42,1,0x0A,0x9C,1,2])
    #expect(try FaultDetail.frameCode(directory,index:1) == 0x0A9C)
}
@Test func serviceDownloadsFaultSubcodesAndFrozenDataWithoutAffectingLiveSamples() async throws {
    let service = DiagnosticService()
    _ = try await service.connect(path:"",demo:true)
    let detail = try await service.readFaultDetail(code:0x0A9C) { _ in }
    #expect(detail.frameIndex == 0)
    #expect(detail.readings.count == 11)
    #expect(detail.readings.allSatisfy { $0.value != nil })
    #expect(detail.subcodes == [0x100,0,0])
    #expect(try await service.sample().device.isDemo)
    await service.disconnect()
}
@Test func faultDetailCanBeExportedInsideExistingDiagnosticReports() async throws {
    let service = DiagnosticService()
    _ = try await service.connect(path:"",demo:true)
    var report = try await service.download { _ in }
    report.faultDetails = [try await service.readFaultDetail(code:0x0A0C) { _ in }]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:directory) }
    let file = directory.appendingPathComponent("report.json")
    try ReportFiles.json(report).write(to:file)
    let reopened = try ReportFiles.read(file)
    #expect(reopened.faultDetails?.first?.frameIndex == 1)
    #expect(reopened.faultDetails?.first?.readings.count == 11)
    await service.disconnect()
}

private final class CancelledDetailTransport: DiagnosticTransport {
    let demo = DemoTransport()
    var trace: [TraceEntry] { demo.trace }
    func close() { demo.close() }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        if case .freezeParameter(_, .soc) = request { throw CancellationError() }
        return try demo.exchange(request)
    }
}
@Test func cancelledFrozenDetailRetainsAlreadyDownloadedFields() throws {
    let reader = DiagnosticReader(transport:CancelledDetailTransport())
    _ = try reader.connect(port:"TEST",demo:true)
    let detail = try reader.faultDetail(code:0x0A9C) { _ in }
    #expect(detail.state == .cancelled)
    #expect(detail.readings.count == 2)
    #expect(detail.subcodes == [0x100,0,0])
    #expect(detail.frameIndex == 0)
}
