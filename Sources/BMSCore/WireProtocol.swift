import Foundation

// The only requests the app can send. There is no arbitrary-command interface.
public enum ReadRequest: Equatable, Sendable {
    case identify, serialNumber, firmware, faults(FaultStatus), eventHeader, event(UInt8)
    case history
    case subcodes(UInt16), freezeDirectory(UInt8), freezeParameter(UInt8, ParameterPID)
    case parameter(ParameterPID), cells(CellQuantity, UInt8), cellFlag(CellFlag)
    public var service: UInt8 {
        switch self { case .identify, .serialNumber, .firmware: 9; case .faults(let s): s.service; case .eventHeader, .event, .history: 0xB3; case .parameter, .cells: 0x22; case .cellFlag: 0xB0; case .subcodes: 0x17; case .freezeDirectory, .freezeParameter: 2 }
    }
    public var pid: UInt16? {
        switch self { case .identify: 0x0B; case .serialNumber: 0x0A; case .firmware: 4; case .faults: nil; case .history: 1; case .eventHeader, .event: 2; case .parameter(let p): p.rawValue; case .cells(let q, let b): q.rawValue + UInt16(b); case .cellFlag(let f): UInt16(f.rawValue); case .subcodes(let code): code; case .freezeDirectory(let frame), .freezeParameter(let frame,_): UInt16(frame) }
    }
    public var body: [UInt8] {
        var bytes = [service]
        if let pid {
            if service == 0x22 || service == 0x17 { bytes.append(UInt8(pid >> 8)) }
            bytes.append(UInt8(truncatingIfNeeded: pid))
        }
        if case .event(let index) = self { bytes.append(index) }
        if case .subcodes = self { bytes.append(0) }
        if case .freezeDirectory = self { bytes += [1,2] }
        if case .freezeParameter(_,let parameter) = self { bytes += [0x22,UInt8(parameter.rawValue >> 8),UInt8(truncatingIfNeeded:parameter.rawValue)] }
        return [UInt8(bytes.count)] + bytes
    }
    public var frame: Data { Data(("\r:" + body.hex + "\n\r").utf8) }
    public func matches(_ reply: WireReply) -> Bool {
        guard reply.service == service &+ 0x40 else { return false }
        guard let pid else { return true } // The response PID is the DTC count for these services.
        guard reply.pid == pid else { return false }
        switch self {
        case .freezeDirectory: return reply.payload.count >= 4 && Array(reply.payload.suffix(2)) == [1,2]
        case .freezeParameter(_,let p): return Array(reply.payload.suffix(3)) == [0x22,UInt8(p.rawValue >> 8),UInt8(truncatingIfNeeded:p.rawValue)]
        case .eventHeader: return reply.payload.count == 2
        case .event(let index): return reply.payload.first == index && reply.payload.count != 2
        default: return true
        }
    }
}
public extension Collection where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}
public struct WireReply: Equatable, Sendable {
    public let bytes: [UInt8]
    public let service: UInt8
    public let pid: UInt16
    public let payload: [UInt8]
    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 3, Int(bytes[0]) == bytes.count - 1 else {
            throw BMSError.invalid("frame length does not match its content")
        }
        guard [UInt8(0x43), 0x47, 0x4A, 0x49, 0xF3, 0x7F, 0x62, 0xF0, 0x42, 0x57].contains(bytes[1]) else {
            throw BMSError.invalid("unexpected response service")
        }
        let width = (bytes[1] == 0x62 || bytes[1] == 0x57) ? 2 : 1
        guard bytes.count >= 2 + width else { throw BMSError.invalid("missing response PID") }
        self.bytes = bytes; service = bytes[1]
        pid = width == 2 ? UInt16(bytes[2]) << 8 | UInt16(bytes[3]) : UInt16(bytes[2])
        payload = Array(bytes.dropFirst(2 + width))
        if service == 0x7F && payload.isEmpty { throw BMSError.invalid("missing rejection reason") }
    }
}

// Incremental, bounded ASCII parser: accepts split frames, coalesced frames and CR/LF.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    private var collecting = false
    public init() {}
    public mutating func feed(_ data: Data) -> [Result<WireReply, BMSError>] {
        var results: [Result<WireReply, BMSError>] = []
        for byte in data {
            if byte == 58 {
                if collecting && !buffer.isEmpty { results.append(.failure(.invalid("unfinished frame before next delimiter"))) }
                collecting = true; buffer.removeAll(keepingCapacity: true)
            } else if byte == 10 || byte == 13 {
                guard collecting else { continue }
                collecting = false
                if !buffer.isEmpty { results.append(decode()) }
                buffer.removeAll(keepingCapacity: true)
            } else if collecting {
                guard buffer.count < 512 else {
                    results.append(.failure(.invalid("frame exceeds maximum size")))
                    collecting = false; buffer.removeAll(keepingCapacity: true); continue
                }
                buffer.append(byte)
            }
        }
        return results
    }
    private func decode() -> Result<WireReply, BMSError> {
        guard buffer.count % 2 == 0 else { return .failure(.invalid("odd number of hexadecimal digits")) }
        var bytes: [UInt8] = []
        var i = 0
        while i < buffer.count {
            guard let hi = Self.nibble(buffer[i]), let lo = Self.nibble(buffer[i + 1]) else {
                return .failure(.invalid("non-hexadecimal character"))
            }
            bytes.append(hi << 4 | lo); i += 2
        }
        do { return .success(try WireReply(bytes: bytes)) }
        catch let error as BMSError { return .failure(error) }
        catch { return .failure(.invalid(error.localizedDescription)) }
    }
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte { case 48...57: byte - 48; case 65...70: byte - 55; case 97...102: byte - 87; default: nil }
    }
}
