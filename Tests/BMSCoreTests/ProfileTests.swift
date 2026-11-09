import Foundation
import Testing
@testable import BMSCore

private let profileDevice = DeviceInfo(signature:"ORIONBMS04",firmware:"030702",port:"Synthetic fixture",isDemo:false)
private final class ProfileFixtureTransport: DiagnosticTransport {
    let demo: DemoTransport
    var trace: [TraceEntry] { demo.trace }
    var requests: [ReadRequest] = []
    var corruptBlock = false
    var failRelock = false
    var statusUnsupported = false
    var closed = false
    var cancelAfterBlock = false
    init(password: String? = nil) { demo = DemoTransport(profilePassword:password) }
    func close() { closed = true; demo.close() }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        requests.append(request)
        if request == .profileLockStatus, statusUnsupported { throw BMSError.unsupported(0x11) }
        let reply = try demo.exchange(request)
        if case .profileBlock = request {
            if cancelAfterBlock { throw CancellationError() }
            if corruptBlock {
                var bytes = reply.bytes; bytes[6] ^= 1
                return try WireReply(bytes:bytes)
            }
        }
        return reply
    }
    func relockProfileSession() throws {
        requests.append(.profileRelock)
        if failRelock { throw BMSError.timeout }
        _ = try demo.exchange(.profileRelock)
    }
}
@Test func profileRequestsMatchReferenceSerializer() throws {
    #expect(ReadRequest.profileBlock(offset:112,count:56).body.hex == "073C0038007000E4")
    #expect(ReadRequest.profileLockStatus.body.hex == "02B203")
    #expect(ReadRequest.profileChallenge.body.hex == "022705")
    #expect(ReadRequest.profileRelock.body.hex == "022000")
    #expect(ReadRequest.profileAuthenticate([UInt8](repeating:1,count:8)).body.hex == "0A27060101010101010101")
    let reply = try DemoTransport().exchange(.profileBlock(offset:112,count:56))
    #expect(ReadRequest.profileBlock(offset:112,count:56).matches(reply))
    #expect(!ReadRequest.profileBlock(offset:0,count:56).matches(reply))
    #expect(reply.profileDescriptor == 0x00380070)
    #expect(try ProfileDecoder.block(reply,offset:112,count:56).count == 56)
}
@Test func unlockedProfileReadsAllBlocksAndVerifiedCoreSettingsWithoutAuth() throws {
    let transport = ProfileFixtureTransport()
    let result = try ProfileReader(transport:transport).read(device:profileDevice,password:nil) { _ in }
    #expect(result.data.count == 3474)
    #expect(!result.authenticated)
    #expect(result.settings.first { $0.id == "MaximumCellVoltage" }?.rawValue == 36500)
    #expect(result.settings.first { $0.id == "MaximumCellVoltage" }?.value == "3.6500 V")
    #expect(result.settings.count == 66)
    #expect(!transport.requests.contains(.profileChallenge))
    #expect(!transport.requests.contains(.profileRelock))
    #expect(transport.requests.last == .profileBlock(offset:3472,count:2))
}
@Test func lockedProfilePromptsWithoutAttemptingPasswordOrReadingBytes() throws {
    let transport = ProfileFixtureTransport(password:"testpass")
    #expect(throws:ProfileAccessError.self) {
        try ProfileReader(transport:transport).read(device:profileDevice,password:nil) { _ in }
    }
    #expect(transport.requests == [.profileLockStatus])
}
@Test func validProfilePasswordAuthenticatesOnceAndRelocksAndIsNotExported() throws {
    let transport = ProfileFixtureTransport(password:"testpass")
    let result = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass") { _ in }
    #expect(result.authenticated)
    #expect(transport.requests.filter { if case .profileAuthenticate = $0 { true } else { false } }.count == 1)
    #expect(transport.requests.last == .profileRelock)
    #expect(try transport.demo.exchange(.profileLockStatus).payload[1] == 0)
    let json = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
    #expect(!json.contains("testpass"))
    #expect(!transport.trace.map(\.text).joined().contains("7465737470617373"))
}
@Test func wrongPasswordIsNotRetriedAndSessionIsRelocked() throws {
    let transport = ProfileFixtureTransport(password:"testpass")
    do { _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"wrong") { _ in }; Issue.record("Expected invalid password") }
    catch ProfileAccessError.invalidPassword {} catch { Issue.record("Unexpected \(error)") }
    #expect(transport.requests.filter { if case .profileAuthenticate = $0 { true } else { false } }.count == 1)
    #expect(transport.requests.last == .profileRelock)
}
@Test func badProfileBlockAndCancellationBothRelockAuthenticatedSession() throws {
    for cancel in [false,true] {
        let transport = ProfileFixtureTransport(password:"testpass")
        transport.corruptBlock = !cancel; transport.cancelAfterBlock = cancel
        #expect(throws:(any Error).self) { try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass") { _ in } }
        #expect(transport.requests.last == .profileRelock)
        #expect(try transport.demo.exchange(.profileLockStatus).payload[1] == 0)
    }
}
@Test func failedProfileRelockClosesTransport() throws {
    let transport = ProfileFixtureTransport(password:"testpass"); transport.failRelock = true
    do { _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass") { _ in }; Issue.record("Expected relock failure") }
    catch ProfileAccessError.relockFailed {} catch { Issue.record("Unexpected \(error)") }
    #expect(transport.closed)
}
@Test func unsupportedLockStatusStillRequiresAuthenticationWhenReadIsDenied() throws {
    let transport = ProfileFixtureTransport(password:"testpass"); transport.statusUnsupported = true
    #expect(throws:ProfileAccessError.self) { try ProfileReader(transport:transport).read(device:profileDevice,password:nil) { _ in } }
    let result = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass") { _ in }
    #expect(result.authenticated)
    #expect(transport.requests.last == .profileRelock)
}
@Test func profileValidationRejectsWholeProfileCorruptionAndUnverifiedFirmware() throws {
    var bytes = DemoTransport.profileData(); bytes[120] ^= 1
    #expect(throws:BMSError.self) { try ProfileDecoder.validate(bytes) }
    let transport = ProfileFixtureTransport()
    let device = DeviceInfo(signature:"ORIONBMS04",firmware:"020700",port:"Synthetic fixture",isDemo:false)
    #expect(throws:ProfileAccessError.self) { try ProfileReader(transport:transport).read(device:device,password:nil) { _ in } }
    #expect(transport.requests.isEmpty)
}
@Test func profilePasswordValidationDoesNotTruncateOrChangeUserInput() throws {
    #expect(try ProfileDecoder.passwordKey("abc") == [97,98,99,0,0,0,0,0])
    for password in ["", "123456789", "päss"] {
        #expect(throws:ProfileAccessError.self) { try ProfileDecoder.passwordKey(password) }
    }
}
