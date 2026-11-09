import Foundation

public struct ProfileUploadReceipt: Sendable {
    public var verifiedProfile: ProfileSnapshot
    public var backupURL: URL
}
public struct ProfileUploadFailure: Error, LocalizedError, Sendable {
    public var phase: String
    public var detail: String
    public var commitWasSent: Bool
    public var backupURL: URL
    public var errorDescription: String? {
        "Profile upload stopped during \(phase): \(detail) " +
        (commitWasSent ? "The active configuration may have changed. Reconnect and read the profile before deciding what to do next. " : "No commit was sent; the upload was not completed. ") +
        "The original profile backup is saved as \(backupURL.lastPathComponent). No automatic rollback or commit retry was attempted."
    }
}

struct ProfileUploader {
    let transport: any DiagnosticTransport
    func upload(_ draft: ProfileDraft, device: DeviceInfo, password: String?, backupURL: URL,
                diagnostic: (String) -> Void = { _ in }, progress: @Sendable (DownloadProgress) -> Void) throws -> ProfileUploadReceipt {
        try draft.validateForUpload()
        guard device.isDemo == draft.baseline.device.isDemo, device.signature == draft.baseline.device.signature,
              device.serialNumber == draft.baseline.device.serialNumber, device.port == draft.baseline.device.port,
              device.firmware == draft.baseline.device.firmware,
              device.isDemo || FirmwareVersion(code:device.firmware ?? "")?.major == 3 else {
            throw ProfileEditingError.invalid("The connected device differs from the draft baseline. Read its current profile and prepare a new draft.")
        }
        let key = try password.map(ProfileDecoder.passwordKey)
        diagnostic("Upload preflight: checking device identity and active profile baseline.")
        progress(.init(0,"Checking device identity and current profile…"))
        let signature = try DiagnosticDecoder.signature(transport.exchange(.identify))
        let serial = try transport.exchange(.serialNumber)
        let firmware = try transport.exchange(.firmware)
        guard serial.payload.first == 0, signature == device.signature,
              try DiagnosticDecoder.ascii(serial.payload,range:1..<9) == device.serialNumber,
              try DiagnosticDecoder.ascii(firmware.payload,range:1..<7) == device.firmware else {
            throw ProfileEditingError.invalid("BMS identity or firmware changed. Disconnect and identify the device again before uploading.")
        }
        let before = try ProfileReader(transport:transport).read(device:device,password:password,diagnostic:diagnostic) { _ in }
        guard before.data == draft.baseline.data else { throw ProfileEditingError.invalid("The active profile changed since this draft was prepared. Read it again and review your edits. Nothing was uploaded.") }
        guard !FileManager.default.fileExists(atPath:backupURL.path) else { throw ProfileEditingError.invalid("The backup destination already exists. Use a new backup filename.") }
        try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try ProfileFiles.save(before,to:backupURL)
        // Confirm a usable full backup exists before enabling any configuration writes.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode(ProfileSnapshot.self,from:Data(contentsOf:backupURL)).data == before.data else { throw ProfileEditingError.invalid("The original profile backup could not be verified. Nothing was uploaded.") }
        diagnostic("Original profile backup saved and verified (location omitted).")
        var phase = "authentication"
        var commitSent = false
        var writesStarted = false
        var sessionStarted = false
        var result: Result<ProfileUploadReceipt,Error>
        do {
            try Task.checkCancellation()
            sessionStarted = true
            var locked = true
            do {
                let status = try transport.exchange(.profileLockStatus)
                guard status.payload.count >= 2, status.payload[1] <= 1 else { throw BMSError.invalid("invalid profile lock status") }
                locked = status.payload[1] == 0
            } catch BMSError.unsupported { /* Ask for a challenge if this status request is unavailable. */ }
            if locked { try ProfileAuthentication.unlockProfile(transport:transport,key:key,diagnostic:diagnostic) }
            try ProfileAuthentication.unlockWrites(transport:transport,diagnostic:diagnostic)
            phase = "sending profile blocks"
            let bytes = Array(draft.data)
            for offset in stride(from:0,to:bytes.count,by:56) {
                try Task.checkCancellation()
                let end = min(offset+56,bytes.count)
                let request = ReadRequest.profileWriteBlock(offset:UInt16(offset),data:Array(bytes[offset..<end]))
                writesStarted = true
                for attempt in 0..<3 {
                    let reply = try transport.exchange(request)
                    guard reply.service == 0x7F, reply.pid == 0x3B, let status = reply.payload.first else { throw BMSError.invalid("invalid profile block acknowledgement") }
                    if status == 0x72 { break }
                    // The reference explicitly requests a retransmission for these codes.
                    if [UInt8(0x75),0x77].contains(status), attempt < 2 { diagnostic("BMS requested a block retransmission."); continue }
                    diagnostic(String(format:"Profile block at byte %d rejected with code 0x%02X.",offset,status))
                    throw BMSError.rejected(status)
                }
                progress(.init(0.1+0.65*Double(end)/Double(bytes.count),"Sending profile · \(end)/\(bytes.count) bytes"))
            }
            try Task.checkCancellation()
            phase = "committing profile"
            progress(.init(0.78,"Committing profile to the BMS…"))
            commitSent = true
            let commit = try transport.exchange(.profileCommit)
            guard commit.service == 0x7F, commit.pid == 0x3B, commit.payload.first == 0x72 else {
                if commit.payload.first == 0x40, commit.payload.count >= 2 {
                    diagnostic(String(format:"Commit rejected by BMS profile validation (reason 0x%02X).",commit.payload[1]))
                    throw ProfileEditingError.invalid(String(format:"BMS profile validation failed (reason 0x%02X).",commit.payload[1]))
                }
                throw ProfileEditingError.invalid(String(format:"BMS did not acknowledge the profile commit (status 0x%02X).",commit.payload.first ?? 0))
            }
            diagnostic("Profile commit acknowledged; read-back verification pending.")
            // Match the original utility's commit/re-lock order before verification.
            try transport.relockProfileSession(); sessionStarted = false
            diagnostic("Upload session re-lock confirmed.")
            phase = "read-back verification"
            let verified = try ProfileReader(transport:transport).read(device:device,password:password,diagnostic:diagnostic) { update in
                progress(.init(0.8+0.2*update.fraction,"Verifying saved profile · " + update.message))
            }
            guard verified.data == draft.data else { throw ProfileEditingError.invalid("The saved profile differs from the reviewed upload. Success has not been confirmed.") }
            diagnostic("Full profile read-back matches the reviewed upload.")
            result = .success(.init(verifiedProfile:verified,backupURL:backupURL))
        } catch {
            if case BMSError.timeout = error { diagnostic("Upload reply timed out; request was not automatically repeated.") }
            if error is CancellationError { diagnostic("Upload cancellation received; no further block or commit will be sent.") }
            result = .failure(error)
        }
        if sessionStarted {
            do { try transport.relockProfileSession(); diagnostic("Upload session re-lock confirmed.") }
            catch { transport.close(); diagnostic("Upload session re-lock unconfirmed; transport closed."); result = .failure(ProfileAccessError.relockFailed) }
        }
        if case .failure(let error) = result {
            diagnostic("Upload stopped during \(phase); commit sent: \(commitSent ? "yes" : "no").")
            if writesStarted || (error as? ProfileAccessError).map({ if case .relockFailed = $0 { true } else { false } }) == true {
                throw ProfileUploadFailure(phase:phase,detail:error.localizedDescription,commitWasSent:commitSent,backupURL:backupURL)
            }
            throw error
        }
        return try result.get()
    }
}
