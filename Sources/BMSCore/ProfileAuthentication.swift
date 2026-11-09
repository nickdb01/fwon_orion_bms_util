import Foundation

enum ProfileAuthentication {
    static func acknowledgement(_ reply: WireReply, stage: String, diagnostic: (String) -> Void) throws {
        // The reference tests the leading 16-bit status, not the payload length.
        guard reply.payload.count >= 2, reply.payload.prefix(2).allSatisfy({ $0 == 0 }) else {
            diagnostic("\(stage): expected two leading zero status bytes; received unexpected status or length.")
            throw ProfileAccessError.unexpectedAuthenticationReply(stage:stage,byteCount:reply.payload.count)
        }
    }
    static func exchange(_ request: ReadRequest, transport: any DiagnosticTransport, stage: String, diagnostic: (String) -> Void) throws -> WireReply {
        diagnostic(stage + ": requesting reply.")
        do {
            let reply = try transport.exchange(request)
            diagnostic(stage + ": reply received (\(reply.payload.count) payload bytes).")
            return reply
        } catch {
            let outcome: String
            switch error {
            case BMSError.rejected(let code): outcome = String(format:"BMS negative response 0x%02X",code)
            case BMSError.unsupported(let code): outcome = String(format:"unsupported request, code 0x%02X",code)
            case BMSError.timeout: outcome = "reply timed out"
            case BMSError.disconnected: outcome = "connection lost"
            case BMSError.invalid: outcome = "invalid serial reply"
            case is CancellationError: outcome = "cancelled"
            default: outcome = "transport failure (raw details omitted)"
            }
            diagnostic(stage + ": " + outcome + "."); throw error
        }
    }
    static func unlockProfile(transport: any DiagnosticTransport, key: [UInt8]?, diagnostic: (String) -> Void) throws {
        let challenge = try exchange(.profileChallenge,transport:transport,stage:"Authentication challenge (0x27/05)",diagnostic:diagnostic)
        guard challenge.payload.count == 8 else { throw ProfileAccessError.unexpectedAuthenticationReply(stage:"challenge",byteCount:challenge.payload.count) }
        if challenge.payload.contains(where: { $0 != 0 }) {
            guard let key else { throw ProfileAccessError.passwordRequired }
            let response = zip(challenge.payload,key).map { $0 ^ $1 }
            let reply: WireReply
            do { reply = try exchange(.profileAuthenticate(response),transport:transport,stage:"Password response (0x27/06)",diagnostic:diagnostic) }
            catch BMSError.rejected(0x35) { throw ProfileAccessError.invalidPassword }
            try acknowledgement(reply,stage:"password acknowledgement",diagnostic:diagnostic)
        }
        diagnostic("Authentication access confirmed.")
    }
    static func unlockWrites(transport: any DiagnosticTransport, diagnostic: (String) -> Void) throws {
        let challenge = try exchange(.profileWriteChallenge,transport:transport,stage:"Write challenge (0x27/01)",diagnostic:diagnostic)
        guard challenge.payload.count >= 2 else { throw ProfileAccessError.unexpectedAuthenticationReply(stage:"write challenge",byteCount:challenge.payload.count) }
        if challenge.payload.prefix(2).contains(where: { $0 != 0 }) {
            // Reference utility's public write-session key; not the user's password.
            let response = zip(challenge.payload.prefix(2),[UInt8(0x12),0x34]).map { $0 ^ $1 }
            let reply = try exchange(.profileWriteAuthenticate(response),transport:transport,stage:"Write response (0x27/02)",diagnostic:diagnostic)
            try acknowledgement(reply,stage:"Write acknowledgement",diagnostic:diagnostic)
        }
        diagnostic("Write access confirmed.")
    }
}
