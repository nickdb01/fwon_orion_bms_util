import Foundation
import Testing
@testable import BMSCore

private func port(_ name: String) -> SerialPortInfo { .init(path: "/dev/cu." + name, name: name) }
@Test func discoveryDetectsUSBAddedAfterStartupWithoutRestart() {
    let internalPort = port("debug-console"), usb = port("usbserial-TEST")
    let change = PortDiscovery.reconcile(previous: [internalPort], current: [internalPort,usb], selected: "")
    #expect(change.added == [usb]); #expect(change.selectedPath == usb.path)
    #expect(change.removed.isEmpty)
}
@Test func discoveryPreservesSelectionAndHandlesRemovalAndMultipleAdapters() {
    let a = port("usbserial-A"), b = port("usbserial-B")
    #expect(PortDiscovery.reconcile(previous: [a], current: [a,b], selected: a.path).selectedPath == a.path)
    let removed = PortDiscovery.reconcile(previous: [a,b], current: [b], selected: a.path)
    #expect(removed.removed == [a]); #expect(removed.selectedPath == b.path)
    #expect(PortDiscovery.reconcile(previous: [], current: [a,b], selected: "").selectedPath == "")
    #expect(PortDiscovery.reconcile(previous: [], current: [port("debug-console")], selected: "").selectedPath == "")
}
@Test func twoBytePIDsAndCellFlagsHaveCorrectWireShapes() throws {
    #expect(ReadRequest.parameter(.packVoltage).body.hex == "0322F00D")
    #expect(ReadRequest.cells(.voltage,1).body.hex == "0322F101")
    #expect(ReadRequest.cellFlag(.populated).body.hex == "02B000")
    let reply = try WireReply(bytes: [5,0x62,0xF0,0x0D,2,0x10])
    #expect(reply.pid == 0xF00D); #expect(reply.payload == [2,0x10])
    #expect(ReadRequest.parameter(.packVoltage).matches(reply))
    #expect(!ReadRequest.parameter(.packCurrent).matches(reply))
    #expect(throws: BMSError.self) { try WireReply(bytes: [2,0x62,0xF0]) }
}
@Test func telemetryPreservesSignsScalingAndRejectsTruncatedValues() throws {
    #expect(abs(try ParameterPID.packCurrent.decode([0xFB,0x2E]) + 123.4) < 0.00001)
    #expect(try ParameterPID.highTemperature.decode([0xFB]) == -5)
    #expect(try ParameterPID.soc.decode([171]) == 85.5)
    #expect(abs(try ParameterPID.packVoltage.decode([2,0x10]) - 52.8) < 0.00001)
    #expect(throws: BMSError.self) { try ParameterPID.packVoltage.decode([1]) }
    #expect(try LiveDecoding.flags([0x81,0x01], maximum:16) == [true,false,false,false,false,false,false,true,false,false,false,false,false,false,false,true])
}
@Test func cellsRespectBankOffsetsCountAndResistanceMask() throws {
    let data = Array(repeating: [UInt8(0x80),UInt8(0x64)], count:12).flatMap { $0 }
    let result = try CellQuantity.resistance.decode(data, bank:1, maximum:16)
    #expect(result.count == 4); #expect(result[13] == 1.0); #expect(result[16] == 1.0)
    #expect(result[17] == nil)
    #expect(throws: BMSError.self) { try CellQuantity.voltage.decode([0], bank:0, maximum:16) }
}
@Test func demoLiveReaderUsesProductionParsingForEveryMeasurement() throws {
    let transport = DemoTransport(), reader = LiveReader(transport: transport)
    let device = DeviceInfo(signature:"ORIONBMS08",serialNumber:"DEMO0001",firmware:"DEMO01",port:"Demo",isDemo:true)
    let snapshot = try reader.sample(device:device)
    #expect(snapshot.reading(.packVoltage)?.value != nil)
    #expect(snapshot.cells.count == 16)
    #expect(snapshot.cells.allSatisfy { $0.populated == true })
    #expect(snapshot.cells[13].balancing == true)
    #expect(snapshot.cells[0].voltage != nil)
    let resistance = try reader.sample(device:device,quantity:.resistance)
    #expect(resistance.cells[0].voltage == nil)
    #expect(resistance.cells[0].resistance != nil)
    #expect(resistance.cellRaw.count == 4)
}
@Test func recordingRoundTripRecoversWithoutFooterAndTruncatedFinalLine() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".orionlog")
    defer { try? FileManager.default.removeItem(at:file) }
    let device = DeviceInfo(signature:"ORIONBMS04",serialNumber:"TEST",firmware:"030702",port:"Demo",isDemo:true)
    let snapshot = try LiveReader(transport:DemoTransport()).sample(device:device)
    let writer = try RecordingWriter(url:file,device:device)
    try writer.append(snapshot); try writer.note("Disconnected")
    let incomplete = try RecordingFiles.read(file)
    #expect(incomplete.totalSamples == 1)
    #expect(incomplete.messages.contains { $0.contains("footer") })
    try writer.finish()
    let complete = try RecordingFiles.read(file)
    #expect(complete.snapshots.first?.readings.count == snapshot.readings.count)
    #expect(complete.messages == ["Disconnected"])
    let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd(); try handle.write(contentsOf:Data("{\"kind\":\"sam".utf8)); try handle.close()
    let recovered = try RecordingFiles.read(file)
    #expect(recovered.totalSamples == 1)
    #expect(recovered.messages.contains { $0.contains("incomplete final line") })
}
@Test func recordingRetainsBoundedWindowAndCSVKeepsPerSignalTimeAndMissingValues() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:directory) }
    let file = directory.appendingPathComponent("test.orionlog")
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    var snapshot = LiveSnapshot(device:device)
    snapshot.readings = [.init(key:"packCurrent",title:"Current",unit:"A",value:nil,acquiredAt:Date(),rawHex:"",note:"Unsupported")]
    let writer = try RecordingWriter(url:file,device:device)
    for _ in 0..<5 { try writer.append(snapshot) }; try writer.finish()
    let reopened = try RecordingFiles.read(file,retain:2)
    #expect(reopened.totalSamples == 5); #expect(reopened.snapshots.count == 2)
    let csv = directory.appendingPathComponent("test.csv")
    try RecordingFiles.exportCSV(reopened.snapshots,to:csv)
    let text = try String(contentsOf:csv,encoding:.utf8)
    #expect(text.contains("packCurrent_acquired_utc")); #expect(text.contains("Unsupported"))
}

@Test func historicalCountersUseLittleEndianAndMissingFieldsStayUnavailable() throws {
    var bytes = [UInt8](repeating:0,count:64)
    bytes[0] = 0x78; bytes[1] = 0x56; bytes[2] = 0x34; bytes[3] = 0x12
    bytes[8] = 0x34; bytes[9] = 0x12; bytes[40] = 7
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    let response = try WireReply(bytes:[66,0xF3,1] + bytes)
    let history = try HistoricalSnapshot.decode(response,device:device)
    #expect(history.runtimeSeconds == 0x12345678)
    #expect(history.statistics.first { $0.name == "Power-ups" }?.value == 0x1234)
    #expect(history.statistics.first { $0.name == "Over-voltage events" }?.value == 7)
    let short = try WireReply(bytes:[16,0xF3,1] + Array(bytes.prefix(14)))
    let partial = try HistoricalSnapshot.decode(short,device:device)
    #expect(partial.statistics.first { $0.name == "Time above 45°C" }?.value == nil)
}
@Test func firmwareVersionComparisonIsNumeric() {
    #expect(FirmwareVersion(code:"030702")?.description == "3.7.2")
    #expect(FirmwareVersion(code:"030609")! < FirmwareVersion(code:"030700")!)
    #expect(FirmwareVersion(code:"DEMO01") == nil)
}
@Test func serviceCanRecordLiveDataAndStillDownloadDiagnosticsAndHistory() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".orionlog")
    defer { try? FileManager.default.removeItem(at:file) }
    let service = DiagnosticService()
    _ = try await service.connect(path:"",demo:true)
    try await service.startRecording(at:file)
    let sample = try await service.sample()
    let diagnostics = try await service.download { _ in }
    let history = try await service.readHistory()
    _ = try await service.sample(quantity:.openVoltage)
    try await service.stopRecording()
    await service.disconnect()
    let recording = try RecordingFiles.read(file)
    #expect(sample.readings.count >= 13)
    #expect(diagnostics.isComplete)
    #expect(history.runtimeSeconds == 432300)
    #expect(recording.totalSamples == 2)
    #expect(recording.messages.count == 2)
}
@Test func negativeCurrentExportsAsNumericCSVWithoutFormulaPrefix() throws {
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    var snapshot = LiveSnapshot(device:device)
    snapshot.readings = [.init(key:"packCurrent",title:"Current",unit:"A",value:-12.3,acquiredAt:Date(),rawHex:"",note:nil)]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
    defer { try? FileManager.default.removeItem(at:url) }
    try RecordingFiles.exportCSV([snapshot],to:url)
    let csv = try String(contentsOf:url,encoding:.utf8)
    #expect(csv.contains("\"-12.3\""))
    #expect(!csv.contains("'-12.3"))
}

private final class UnsupportedLiveTransport: DiagnosticTransport {
    var trace: [TraceEntry] = []
    var parameterCalls = 0
    var allUnsupported = false
    let demo = DemoTransport()
    func close() { demo.close() }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        if allUnsupported { throw BMSError.unsupported(0x11) }
        if case .parameter(let pid) = request, pid == .packCurrent {
            parameterCalls += 1; throw BMSError.unsupported(0x11)
        }
        return try demo.exchange(request)
    }
}
@Test func unsupportedLiveValuesStayMissingAndAreNotRepeatedEveryPoll() throws {
    let transport = UnsupportedLiveTransport()
    let reader = LiveReader(transport:transport)
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    let first = try reader.sample(device:device)
    let second = try reader.sample(device:device)
    #expect(first.reading(.packCurrent)?.value == nil)
    #expect(second.reading(.packCurrent)?.value == nil)
    #expect(first.reading(.packVoltage)?.value != nil)
    #expect(transport.parameterCalls == 1)
}
@Test func entirelyUnsupportedLiveDataDoesNotReportADeviceDisconnect() throws {
    let transport = UnsupportedLiveTransport(); transport.allUnsupported = true
    let reader = LiveReader(transport:transport)
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    do { _ = try reader.sample(device:device); Issue.record("Expected no decoded values") }
    catch { if case .invalid = error as? BMSError { } else { Issue.record("Incorrectly classified no live support as \(error)") } }
}
@Test func recordingRetainsMillisecondAcquisitionTimes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".orionlog")
    defer { try? FileManager.default.removeItem(at:url) }
    let device = DeviceInfo(signature:"ORIONBMS04",port:"TEST",isDemo:true)
    var snapshot = LiveSnapshot(device:device)
    snapshot.finishedAt = Date(timeIntervalSince1970:1_800_000_000.123)
    let writer = try RecordingWriter(url:url,device:device)
    try writer.append(snapshot); try writer.finish()
    let loaded = try RecordingFiles.read(url)
    #expect(abs(loaded.snapshots[0].finishedAt.timeIntervalSince(snapshot.finishedAt)) < 0.001)
}

// Frames captured from the connected ORIONBMS04 (firmware 3.7.2), 8 Nov 2026.
private final class CapturedJuniorCellsTransport: DiagnosticTransport {
    var trace: [TraceEntry] = []
    let demo = DemoTransport()
    var rejectParameters = false
    var malformedPopulation = false
    func close() {}
    func exchange(_ request: ReadRequest) throws -> WireReply {
        let frame: String?
        switch request {
        case .parameter(.maximumCells): frame = ":0462F00600\n"
        case .parameter where rejectParameters: throw BMSError.unsupported(0x11)
        case .cellFlag(.populated): frame = malformedPopulation ? ":02F000\n" : ":04F000FFFF\n"
        case .cells(.voltage, 0): frame = ":1B62F100824D82698291828F832D8297825882598244825F8266828E\n"
        case .cells(.voltage, 1): frame = ":1B62F101830F82DB8284829B00000000000000000000000000000000\n"
        case .cells(.resistance, 0): frame = ":1B62F200000E000E0011000E000C000C00110010000D00130010000D\n"
        case .cells(.resistance, 1): frame = ":1B62F201000C000D0011001000000000000000000000000000000000\n"
        case .cells(.openVoltage, 0): frame = ":1B62F3008269828382A1828382A0827D827182698263827482748281\n"
        case .cells(.openVoltage, 1): frame = ":1B62F3018295828C8270827400000000000000000000000000000000\n"
        default: return try demo.exchange(request)
        }
        var parser = FrameParser()
        return try parser.feed(Data(frame!.utf8))[0].get()
    }
}
@Test func physicalJuniorZeroCountUsesPopulationAndDecodesAllSixteenCells() throws {
    let transport = CapturedJuniorCellsTransport(), reader = LiveReader(transport: transport)
    let device = DeviceInfo(signature: "ORIONBMS04", firmware: "030702", port: "Captured fixture", isDemo: false)
    let voltage = try reader.sample(device: device)
    #expect(voltage.cells.count == 16)
    #expect(voltage.cells.allSatisfy { $0.populated == true && $0.voltage != nil })
    #expect(abs(voltage.cells[0].voltage! - 3.3357) < 0.000001)
    #expect(abs(voltage.cells[15].voltage! - 3.3435) < 0.000001)
    #expect(voltage.notes.contains { $0.contains("population bitmap") })
    let resistance = try reader.sample(device: device, quantity: .resistance)
    #expect(resistance.cells[0].resistance == 0.14)
    #expect(resistance.cells[15].resistance == 0.16)
    let open = try reader.sample(device: device, quantity: .openVoltage)
    #expect(abs(open.cells[0].openVoltage! - 3.3385) < 0.000001)
    #expect(open.cells.allSatisfy { $0.openVoltage != nil })
}
@Test func cellReadingsSurviveUnsupportedOverviewParameters() throws {
    let transport = CapturedJuniorCellsTransport(); transport.rejectParameters = true
    let reader = LiveReader(transport: transport)
    let device = DeviceInfo(signature: "ORIONBMS04", port: "Captured fixture", isDemo: false)
    let snapshot = try reader.sample(device: device)
    #expect(snapshot.readings.allSatisfy { $0.value == nil })
    #expect(snapshot.cells.count == 16)
    #expect(snapshot.cells.allSatisfy { $0.voltage != nil })
}
@Test func zeroCellCountWithoutPopulationDoesNotInventCellReadings() throws {
    let transport = CapturedJuniorCellsTransport(); transport.malformedPopulation = true
    let reader = LiveReader(transport: transport)
    let device = DeviceInfo(signature: "ORIONBMS04", port: "Captured fixture", isDemo: false)
    let snapshot = try reader.sample(device: device)
    #expect(snapshot.cells.isEmpty)
    #expect(snapshot.notes.contains { $0.contains("Cell layout") })
}
