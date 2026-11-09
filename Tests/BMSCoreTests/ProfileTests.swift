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
    var authenticationReply: [UInt8]?
    var challengeError: BMSError?
    var challengeReply: [UInt8]?
    init(password: String? = nil) { demo = DemoTransport(profilePassword:password) }
    func close() { closed = true; demo.close() }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        requests.append(request)
        if request == .profileChallenge, let challengeError { throw challengeError }
        if request == .profileChallenge, let challengeReply {
            return try WireReply(bytes:[UInt8(challengeReply.count+2),0x67,5] + challengeReply)
        }
        if case .profileAuthenticate = request, let authenticationReply {
            _ = try demo.exchange(request)
            return try WireReply(bytes:[UInt8(authenticationReply.count+2),0x67,6] + authenticationReply)
        }
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

@Test func unexpectedAuthenticationAcknowledgementIsNotCalledPasswordRejection() throws {
    for payload: [UInt8] in [[], [0], [0,1], [1,0], [0,1,0,0,0,0,0,0]] {
        let transport = ProfileFixtureTransport(password:"testpass")
        transport.authenticationReply = payload
        var details: [String] = []
        do {
            _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass",diagnostic:{ details.append($0) }) { _ in }
            Issue.record("Expected unexpected reply")
        } catch ProfileAccessError.unexpectedAuthenticationReply(let stage,let count) {
            #expect(stage == "password acknowledgement")
            #expect(count == payload.count)
        } catch { Issue.record("Misclassified reply: \(error)") }
        #expect(details.contains { $0.contains("unexpected status or length") })
        #expect(details.last == "Session re-lock confirmed.")
    }
}

@Test func explicitPasswordRejectionReportsCodeAndStageWithoutAuthenticationValues() throws {
    let transport = ProfileFixtureTransport(password:"testpass")
    var details: [String] = []
    do {
        _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"wrong",diagnostic:{ details.append($0) }) { _ in }
        Issue.record("Expected rejection")
    } catch ProfileAccessError.invalidPassword {
        #expect(ProfileAccessError.invalidPassword.localizedDescription.contains("0x35"))
    } catch { Issue.record("Unexpected \(error)") }
    let summary = details.joined(separator:"\n")
    #expect(summary.contains("Password response (0x27/06): BMS negative response 0x35"))
    for secret in ["testpass", "wrong", "1223344556677819", "7465737470617373", "77726F6E67000000"] {
        #expect(!summary.contains(secret))
    }
    #expect(details.last == "Session re-lock confirmed.")
}

@Test func challengeRejectionAndTimeoutDoNotImplyPasswordWasSent() throws {
    for failure: BMSError in [.rejected(0x35), .rejected(0x36), .rejected(0x37), .timeout] {
        let transport = ProfileFixtureTransport(password:"testpass")
        transport.challengeError = failure
        var details: [String] = []
        do {
            _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass",diagnostic:{ details.append($0) }) { _ in }
            Issue.record("Expected challenge failure")
        } catch let error as BMSError { #expect(error == failure) }
        catch { Issue.record("Challenge failure misclassified: \(error)") }
        #expect(!transport.requests.contains { if case .profileAuthenticate = $0 { true } else { false } })
        #expect(details.contains { $0.hasPrefix("Authentication challenge (0x27/05):") && ($0.contains("negative response") || $0.contains("timed out")) })
        #expect(details.last == "Session re-lock confirmed.")
    }
}

@Test func malformedChallengeIsReportedBeforeAnyPasswordResponseIsSent() throws {
    for count in [0,2,7,9] {
        let transport = ProfileFixtureTransport(password:"testpass")
        transport.challengeReply = [UInt8](repeating:0xAB,count:count)
        var details: [String] = []
        do {
            _ = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass",diagnostic:{ details.append($0) }) { _ in }
            Issue.record("Expected malformed challenge")
        } catch ProfileAccessError.unexpectedAuthenticationReply(let stage,let size) {
            #expect(stage == "challenge")
            #expect(size == count)
        } catch { Issue.record("Unexpected \(error)") }
        #expect(!transport.requests.contains { if case .profileAuthenticate = $0 { true } else { false } })
        #expect(details.contains("Authentication challenge (0x27/05): reply received (\(count) payload bytes)."))
        #expect(!details.joined().contains("ABAB"))
    }
}

@Test func profileAuthenticationAcceptsExtendedAcknowledgementsUsingLeadingStatus() throws {
    // Synthetic payloads: the reference checks only the first two status bytes.
    for payload: [UInt8] in [[0,0], [0,0,0], [0,0,0,0,0,0,0,0], [0,0,0xAB,0xCD,0xEF,0x98,0x76,0x54]] {
        let transport = ProfileFixtureTransport(password:"testpass")
        transport.authenticationReply = payload
        var details: [String] = []
        let profile = try ProfileReader(transport:transport).read(device:profileDevice,password:"testpass",diagnostic:{ details.append($0) }) { _ in }
        #expect(profile.authenticated)
        #expect(profile.data.count == ProfileDecoder.byteCount)
        #expect(details.contains("Password response (0x27/06): reply received (\(payload.count) payload bytes)."))
        #expect(details.contains("Authentication access confirmed."))
        #expect(details.contains("Session re-lock confirmed."))
        #expect(!details.joined().contains("ABCDEF987654"))
        #expect(try transport.demo.exchange(.profileLockStatus).payload[1] == 0)
    }
}
