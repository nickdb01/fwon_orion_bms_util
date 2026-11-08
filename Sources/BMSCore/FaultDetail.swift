import Foundation

public struct FaultDetail: Codable, Sendable {
    public var rawCode: UInt16
    public var device: DeviceInfo
    public var acquiredAt = Date()
    public var state: SectionState = .complete
    public var subcodes: [UInt16] = []
    public var frameIndex: UInt8?
    public var readings: [LiveReading] = []
    public var notes: [String] = []
    public var rawReplies: [String] = []
    public var summary: String { DiagnosticDecoder.faultDescription(DiagnosticDecoder.dtc(rawCode)) }
    public var subcodeDescription: String {
        if rawCode == 0x0A11 && subcodes.contains(where: { $0 & 0xFF00 == 0x0100 }) { return "A large learned-capacity adjustment was reported." }
        return subcodes.isEmpty ? "No subcodes downloaded" : "Raw subcodes retained for service review"
    }
    public static func frameCode(_ reply: WireReply, index: UInt8) throws -> UInt16 {
        guard reply.service == 0x42, reply.pid == UInt16(index), reply.payload.count >= 4,
              reply.payload.suffix(2) == [1,2] else { throw BMSError.invalid("invalid freeze-frame directory reply") }
        return UInt16(reply.payload[0]) << 8 | UInt16(reply.payload[1])
    }
    public static func decodeSubcodes(_ reply: WireReply, code: UInt16) throws -> [UInt16] {
        guard reply.service == 0x57, reply.pid == code, reply.payload.count == 7 else { throw BMSError.invalid("invalid diagnostic subcode reply") }
        return [1,3,5].map { UInt16(reply.payload[$0]) << 8 | UInt16(reply.payload[$0 + 1]) }
    }
    public static func decodeReading(_ reply: WireReply, parameter: ParameterPID, frame: UInt8) throws -> LiveReading {
        let trailer = [UInt8(0x22), UInt8(parameter.rawValue >> 8), UInt8(truncatingIfNeeded:parameter.rawValue)]
        guard reply.service == 0x42, reply.pid == UInt16(frame), Array(reply.payload.suffix(3)) == trailer,
              reply.payload.count == parameter.byteCount + 3 else { throw BMSError.invalid("freeze-frame parameter identification or length mismatch") }
        return LiveReading(key:parameter.key,title:parameter.title,unit:parameter.unit,value:try parameter.decode(Array(reply.payload.dropLast(3))),acquiredAt:Date(),rawHex:reply.bytes.hex,note:"Stored fault snapshot; acquisition time is not the original event date")
    }
}

extension DiagnosticReader {
    func faultDetail(code: UInt16, progress: @Sendable (DownloadProgress) -> Void) throws -> FaultDetail {
        guard let device else { throw BMSError.disconnected }
        var detail = FaultDetail(rawCode:code,device:device)
        do {
        do {
            let response = try transport.exchange(.subcodes(code))
            detail.rawReplies.append(response.bytes.hex)
            detail.subcodes = try FaultDetail.decodeSubcodes(response,code:code)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            if (error as? BMSError) == .disconnected { throw error }
            detail.notes.append("Subcodes: " + error.localizedDescription)
        }
        for index in UInt8(0)..<30 {
            try Task.checkCancellation()
            progress(.init(Double(index) / 60,"Checking stored snapshot \(index + 1) of 30…"))
            do {
                let response = try transport.exchange(.freezeDirectory(index))
                detail.rawReplies.append(response.bytes.hex)
                if try FaultDetail.frameCode(response,index:index) == code { detail.frameIndex = index; break }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                detail.notes.append("Snapshot search stopped at selector \(index): " + error.localizedDescription)
                break
            }
        }
        guard let frame = detail.frameIndex else {
            detail.state = .partial
            detail.notes.append("No matching frame was downloaded. A failed or unsupported search does not establish that no snapshot exists.")
            return detail
        }
        let parameters: [ParameterPID] = [.packVoltage,.packCurrent,.soc,.highTemperature,.lowTemperature,.chargeLimit,.dischargeLimit,.highCell,.lowCell,.observedCapacity,.observedSOC]
        for (index,pid) in parameters.enumerated() {
            try Task.checkCancellation()
            progress(.init(0.5 + Double(index) / Double(parameters.count) * 0.5,"Reading frozen \(pid.title.lowercased())…"))
            do {
                let response = try transport.exchange(.freezeParameter(frame,pid))
                detail.rawReplies.append(response.bytes.hex)
                detail.readings.append(try FaultDetail.decodeReading(response,parameter:pid,frame:frame))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                if (error as? BMSError) == .disconnected { throw error }
                detail.readings.append(.init(key:pid.key,title:pid.title,unit:pid.unit,value:nil,acquiredAt:Date(),rawHex:"",note:error.localizedDescription))
            }
        }
        detail.state = detail.notes.isEmpty && detail.readings.allSatisfy { $0.value != nil } ? .complete : .partial
        return detail
        } catch is CancellationError {
            detail.state = .cancelled; detail.notes.append("Cancelled; downloaded detail was retained.")
            return detail
        } catch {
            if (error as? BMSError) == .disconnected {
                close(); detail.state = .partial; detail.notes.append("BMS disconnected; downloaded detail was retained.")
                return detail
            }
            throw error
        }
    }
}
