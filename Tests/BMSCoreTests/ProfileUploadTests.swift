import Foundation
import Testing
@testable import BMSCore

private struct UploadOracle: Decodable {
    var hex: String
    var requests: [String]
    var editedHex: String
    var authenticationRequests: [String]
    var xml: String
    var bytes: [UInt8] {
        let chars = Array(hex.utf8)
        return stride(from:0,to:chars.count,by:2).map { UInt8(String(decoding:chars[$0..<$0+2],as:UTF8.self),radix:16)! }
    }
    static func load() throws -> UploadOracle {
        try JSONDecoder().decode(Self.self,from:Data(contentsOf:Bundle.module.url(forResource:"ProfileUploadOracle",withExtension:"json")!))
    }
}
private final class UploadFixture: DiagnosticTransport {
    var demo: DemoTransport
    var requests: [ReadRequest] = []
    var trace: [TraceEntry] { demo.trace }
    var closed = false
    var rejectWriteAccess = false
    var extendWriteChallenge = false
    var blockFailure: Error?
    var askRetransmit = false
    var rejectAllBlocks = false
    var loseCommitReply = false
    var corruptAfterCommit = false
    var failUploadRelock = false
    private var writeAttempted = false
    let temporary: URL
    init(password: String? = "testpass") throws {
        demo = DemoTransport(profilePassword:password,profileData:try UploadOracle.load().bytes)
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
    }
    deinit { try? FileManager.default.removeItem(at:temporary) }
    var backup: URL { temporary.appendingPathComponent("before-upload.json") }
    func close() { closed = true; demo.close() }
    func relockProfileSession() throws {
        requests.append(.profileRelock)
        if failUploadRelock, writeAttempted { throw BMSError.timeout }
        _ = try demo.exchange(.profileRelock)
    }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        requests.append(request)
        if case .profileWriteAuthenticate = request, rejectWriteAccess { throw BMSError.rejected(0x35) }
        if case .profileWriteBlock = request {
            writeAttempted = true
            if let blockFailure { throw blockFailure }
            if rejectAllBlocks { return try WireReply(bytes:[3,0x7F,0x3B,0x75]) }
            if askRetransmit { askRetransmit = false; return try WireReply(bytes:[3,0x7F,0x3B,0x75]) }
        }
        let result = try demo.exchange(request)
        if request == .profileWriteChallenge, extendWriteChallenge { return try WireReply(bytes:[10,0x67,1,0x45,0x67,1,2,3,4,5,6]) }
        if request == .profileCommit {
            if corruptAfterCommit {
                var bytes = try UploadOracle.load().bytes; bytes[11] ^= 1
                demo = DemoTransport(profilePassword:"testpass",profileData:Array(ProfileDecoder.checksummed(bytes)))
            }
            if loseCommitReply { throw BMSError.timeout }
        }
        return result
    }
    func baseline() throws -> ProfileSnapshot {
        let device = try DiagnosticReader(transport:self).connect(port:"Synthetic upload fixture",demo:true)
        return try ProfileReader(transport:self).read(device:device,password:"testpass") { _ in }
    }
    func draft() throws -> ProfileDraft {
        var draft = try ProfileDraft(baseline:baseline())
        try draft.setDisplayValue("3.6",for:"MaximumCellVoltage")
        return draft
    }
    var mutations: [ReadRequest] { requests.filter(\.isProfileMutation) }
}

@Test func allUploadFramesMatchIndependentReferenceSerializer() throws {
    let oracle = try UploadOracle.load()
    try ProfileDecoder.validate(oracle.bytes)
    var actual: [String] = []
    for offset in stride(from:0,to:oracle.bytes.count,by:56) {
        actual.append(ReadRequest.profileWriteBlock(offset:UInt16(offset),data:Array(oracle.bytes[offset..<min(offset+56,oracle.bytes.count)])).body.hex)
    }
    actual.append(ReadRequest.profileCommit.body.hex)
    #expect(actual == oracle.requests)
    #expect(actual.count == 64)
    #expect(ReadRequest.profileWriteChallenge.body.hex == "022701")
    #expect(ReadRequest.profileWriteAuthenticate([1,2]).body.hex == "0427020102")
    #expect(ReadRequest.profileCommit.matches(try WireReply(bytes:[3,0x7F,0x3B,0x72])))
}

@Test func profileEditingPreservesUnknownDataAndUsesExactUnitsAndSignedRanges() throws {
    let fixture = try UploadFixture()
    var draft = try ProfileDraft(baseline:fixture.baseline())
    let original = draft.data
    try draft.setDisplayValue("3.6000",for:"MaximumCellVoltage")
    #expect(draft.editorValue(for:"MaximumCellVoltage") == "3.6")
    #expect(draft.settings.first { $0.id == "MaximumCellVoltage" }?.rawValue == 36000)
    #expect(draft.data.map { String(format:"%02X",$0) }.joined() == (try UploadOracle.load()).editedHex)
    #expect(draft.changes.count == 1)
    #expect(draft.otherChangedByteCount == 0)
    for index in 0..<(ProfileDecoder.byteCount-3) where ![11,12].contains(index) { #expect(draft.data[index] == original[index]) }
    try draft.setRawValue("-10",for:"DerateLowTempDCLStart")
    #expect(draft.data[59] == 246)
    try ProfileDecoder.validate(Array(draft.data))
    for value in ["3.60001","99999","nan","3,6","3.6x","1e2"] {
        #expect(throws:ProfileEditingError.self) { try draft.setDisplayValue(value,for:"MaximumCellVoltage") }
    }
    #expect(throws:ProfileEditingError.self) { try draft.setDisplayValue("1.5",for:"MaximumCCL") }
    #expect(throws:ProfileEditingError.self) { try draft.setRawValue("-129",for:"DerateLowTempDCLStart") }
}

@Test func vendorXMLRawAndJSONProfilesRoundTripWithoutExecutingXML() throws {
    let fixture = try UploadFixture(); let oracle = try UploadOracle.load(); let baseline = try fixture.baseline()
    for (name,text) in [("vendor.j2bms",oracle.xml),("raw.hex",oracle.hex),("raw.j2ps","3.0.0\n"+oracle.hex)] {
        let url = fixture.temporary.appendingPathComponent(name); try Data(text.utf8).write(to:url)
        #expect(try ProfileFiles.read(url,for:baseline) == Data(oracle.bytes))
    }
    try ProfileFiles.save(baseline,to:fixture.backup)
    #expect(try ProfileFiles.read(fixture.backup,for:baseline) == baseline.data)
    let permissions = try FileManager.default.attributesOfItem(atPath:fixture.backup.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let attacks = ["<!DOCTYPE java [<!ENTITY x SYSTEM 'file:///private/secret'>]><java/>","<java><object><void property='profileStr'><string>\(oracle.hex)</string></void><void property='profileStr'><string>\(oracle.hex)</string></void></object></java>","<?xml version='1.0'?><java><object><void property='profileStr'><string><object/>\(oracle.hex)</string></void></object></java>"]
    for text in attacks {
        let url = fixture.temporary.appendingPathComponent("bad.j2bms"); try Data(text.utf8).write(to:url)
        #expect(throws:(any Error).self) { try ProfileFiles.read(url,for:baseline) }
    }
}

@Test func uploadsAreRejectedForInvalidLimitsAndIncompatibleUnitTypes() throws {
    let fixture = try UploadFixture(); var draft = try fixture.draft()
    try draft.setDisplayValue("4.0",for:"MinimumCellVoltage")
    #expect(throws:ProfileEditingError.self) { try draft.validateForUpload() }
    var bytes = Array(draft.data); bytes[149] ^= 1
    #expect(throws:ProfileEditingError.self) { try draft.replace(with:ProfileDecoder.checksummed(bytes),source:"Wrong unit") }
}

@Test func profileUploadBacksUpAuthenticatesCommitsRelocksAndVerifiesFullReadback() throws {
    let fixture = try UploadFixture(); fixture.extendWriteChallenge = true
    let draft = try fixture.draft()
    var details: [String] = []
    let receipt = try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup,diagnostic:{ details.append($0) }) { _ in }
    #expect(receipt.verifiedProfile.data == draft.data)
    #expect(fixture.mutations.count == 64)
    #expect(fixture.mutations.last == .profileCommit)
    #expect(try ProfileFiles.read(fixture.backup,for:draft.baseline) == draft.baseline.data)
    #expect(details.last == "Full profile read-back matches the reviewed upload.")
    #expect(!details.joined().contains("testpass"))
    #expect(!fixture.trace.map(\.text).joined().contains("3F3B0038"))
}

@Test func wrongPasswordOrDeniedWriteAccessSendsNoConfigurationWrites() throws {
    for writeDenied in [false,true] {
        let fixture = try UploadFixture(); let draft = try fixture.draft(); fixture.rejectWriteAccess = writeDenied
        #expect(throws:(any Error).self) {
            try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:writeDenied ? "testpass" : "wrong",backupURL:fixture.backup) { _ in }
        }
        #expect(fixture.mutations.isEmpty)
    }
}

@Test func staleProfilePreventsUploadAndDoesNotCreateMisleadingBackup() throws {
    let fixture = try UploadFixture(); let draft = try fixture.draft()
    fixture.demo = DemoTransport(profilePassword:"testpass",profileData:Array(draft.data))
    #expect(throws:ProfileEditingError.self) {
        try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
    }
    #expect(fixture.mutations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath:fixture.backup.path))
}

@Test func uploadBlockFailureOrCancellationNeverCommitsAndRetainsOriginalBackup() throws {
    for failure: Error in [BMSError.timeout,CancellationError()] {
        let fixture = try UploadFixture(); let draft = try fixture.draft(); fixture.blockFailure = failure
        do {
            _ = try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
            Issue.record("Expected interrupted upload")
        } catch let error as ProfileUploadFailure { #expect(!error.commitWasSent) }
        catch { Issue.record("Unexpected \(error)") }
        #expect(fixture.mutations.count == 1)
        #expect(!fixture.mutations.contains(.profileCommit))
        #expect(fixture.requests.last == .profileRelock)
        #expect(try fixture.baseline().data == draft.baseline.data)
        #expect(FileManager.default.fileExists(atPath:fixture.backup.path))
    }
}

@Test func explicitBlockRetransmissionIsBoundedAndDoesNotRepeatCommit() throws {
    let fixture = try UploadFixture(); let draft = try fixture.draft(); fixture.askRetransmit = true
    _ = try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
    #expect(fixture.mutations.count == 65)
    #expect(fixture.mutations.filter { $0 == .profileCommit }.count == 1)
}

@Test func lostCommitReplyAndMismatchedReadbackNeverReportSuccessOrRetryCommit() throws {
    for mismatch in [false,true] {
        let fixture = try UploadFixture(); let draft = try fixture.draft()
        fixture.loseCommitReply = !mismatch; fixture.corruptAfterCommit = mismatch
        do {
            _ = try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
            Issue.record("Expected unverified outcome")
        } catch let error as ProfileUploadFailure { #expect(error.commitWasSent) }
        catch { Issue.record("Unexpected \(error)") }
        #expect(fixture.mutations.filter { $0 == .profileCommit }.count == 1)
        #expect(FileManager.default.fileExists(atPath:fixture.backup.path))
    }
}

@Test func uploadRelockFailureClosesTransportAndRetainsBackup() throws {
    let fixture = try UploadFixture(); let draft = try fixture.draft(); fixture.failUploadRelock = true
    #expect(throws:ProfileUploadFailure.self) {
        try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
    }
    #expect(fixture.closed)
    #expect(FileManager.default.fileExists(atPath:fixture.backup.path))
}

private final class AuthenticationOracleTransport: DiagnosticTransport {
    var trace: [TraceEntry] = []
    var responsesSent: [String] = []
    func close() {}
    func exchange(_ request: ReadRequest) throws -> WireReply {
        switch request {
        case .profileChallenge: return try WireReply(bytes:[10,0x67,5,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88])
        case .profileWriteChallenge: return try WireReply(bytes:[10,0x67,1,0x45,0x67,1,2,3,4,5,6])
        case .profileAuthenticate:
            responsesSent.append(request.body.hex)
            return try WireReply(bytes:[10,0x67,6,0,0,0xAB,0xCD,0xEF,0x98,0x76,0x54])
        case .profileWriteAuthenticate:
            responsesSent.append(request.body.hex)
            return try WireReply(bytes:[10,0x67,2,0,0,0xAB,0xCD,0xEF,0x98,0x76,0x54])
        default: throw BMSError.invalid("Unexpected authentication oracle request")
        }
    }
}
@Test func bothAuthenticationLevelsMatchIndependentJavaOracleAndAcceptExtendedReplies() throws {
    let transport = AuthenticationOracleTransport()
    try ProfileAuthentication.unlockProfile(transport:transport,key:ProfileDecoder.passwordKey("testpass"),diagnostic:{ _ in })
    try ProfileAuthentication.unlockWrites(transport:transport,diagnostic:{ _ in })
    #expect(transport.responsesSent == (try UploadOracle.load()).authenticationRequests)
}

@Test func repeatedBlockRetransmissionRequestsStopAtThreeAttemptsWithoutCommit() throws {
    let fixture = try UploadFixture(); let draft = try fixture.draft(); fixture.rejectAllBlocks = true
    #expect(throws:ProfileUploadFailure.self) {
        try ProfileUploader(transport:fixture).upload(draft,device:draft.baseline.device,password:"testpass",backupURL:fixture.backup) { _ in }
    }
    #expect(fixture.mutations.count == 3)
    #expect(!fixture.mutations.contains(.profileCommit))
    #expect(try fixture.baseline().data == draft.baseline.data)
}
