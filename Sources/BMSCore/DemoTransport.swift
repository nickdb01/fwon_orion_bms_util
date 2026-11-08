import Foundation

// Synthetic replies go through the production framing and diagnostic decoders.
final class DemoTransport: DiagnosticTransport {
    private(set) var trace: [TraceEntry] = []
    private var closed = false
    private let signature: String
    init(signature: String = "ORIONBMS08") { self.signature = signature }
    func close() { closed = true }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        guard !closed else { throw BMSError.disconnected }
        try Task.checkCancellation()
        let body: [UInt8]
        switch request {
        case .identify: body = [0x49, 0x0B, 1] + Array(signature.utf8)
        case .serialNumber: body = [0x49, 0x0A, 0] + Array("DEMO0001".utf8)
        case .firmware: body = [0x49, 4, 1] + Array("DEMO01".utf8)
        case .faults(.active): body = [0x43, 1, 0x0A, 0x9C]
        case .faults(.stored): body = [0x47, 2, 0x0A, 0x9C, 0x0A, 0x0C]
        case .faults(.history): body = [0x4A, 1, 0x0A, 0x0C]
        case .subcodes(let code): body = [0x57, UInt8(code >> 8), UInt8(truncatingIfNeeded:code),0,1,0,0,0,0,0]
        case .freezeDirectory(let frame):
            body = [0x42,frame] + (frame == 0 ? [0x0A,0x9C] : frame == 1 ? [0x0A,0x0C] : [0,0]) + [1,2]
        case .freezeParameter(let frame, let parameter):
            let previousTrace = trace
            let live = try exchange(.parameter(parameter))
            trace = previousTrace // Internal fixture generation is not another wire request.
            body = [0x42,frame] + live.payload + [0x22,UInt8(parameter.rawValue >> 8),UInt8(truncatingIfNeeded:parameter.rawValue)]
        case .history:
            var data = [UInt8](repeating: 0, count: 64)
            let runtime: UInt32 = 432300
            for i in 0..<4 { data[i] = UInt8(truncatingIfNeeded: runtime >> (i * 8)) }
            data[8] = 32; data[10] = 2; data[12] = 95; data[40] = 3; data[41] = 1
            body = [0xF3,1] + data
        case .eventHeader: body = [0xF3, 2, 6, 0]
        case .parameter(let parameter):
            let wave = sin(Date().timeIntervalSince1970 / 14)
            let value: Int
            switch parameter {
            case .maximumCells: value = 16
            case .packVoltage: value = Int(528 + wave * 3)
            case .packPower: value = Int(wave * 8)
            case .stateOfHealth: value = 98
            case .packCurrent: value = Int(wave * 150)
            case .soc: value = Int(170 + wave * 2)
            case .chargeLimit: value = 50
            case .dischargeLimit: value = 120
            case .highTemperature: value = Int(31 + wave * 2)
            case .lowTemperature: value = 25
            case .averageTemperature: value = 28
            case .relayState: value = 3
            case .limitReasons: value = 0
            case .lowCell: value = 32900
            case .highCell: value = 33200
            case .observedCapacity: value = 1000
            case .observedSOC: value = 168
            }
            let encoded = UInt16(truncatingIfNeeded: value)
            body = [0x62, UInt8(parameter.rawValue >> 8), UInt8(truncatingIfNeeded: parameter.rawValue)] + (parameter.byteCount == 1 ? [UInt8(truncatingIfNeeded: encoded)] : [UInt8(encoded >> 8), UInt8(truncatingIfNeeded: encoded)])
        case .cellFlag(let flag):
            body = [0xF0, flag.rawValue] + (flag == .populated ? [0xFF, 0xFF] : [0x00, 0x04])
        case .cells(let quantity, let bank):
            guard bank < 2 else { throw BMSError.invalid("invalid demo cell bank") }
            let pid = quantity.rawValue + UInt16(bank)
            var payload: [UInt8] = []
            for index in 0..<12 {
                let cell = Int(bank) * 12 + index
                let value = quantity == .resistance ? 120 + cell : 33000 + cell * 9 + Int(sin(Date().timeIntervalSince1970 / 12 + Double(cell)) * 25)
                payload += [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
            }
            body = [0x62, UInt8(pid >> 8), UInt8(truncatingIfNeeded: pid)] + payload
        case .event(let slot):
            let events: [(UInt32, UInt8, UInt16)] = [
                (431900, 2, 1), (432000, 3, 2), (432090, 4, 0x0A0C),
                (432091, 20, 6), (432200, 4, 0x0A9C), (432201, 20, 7)
            ]
            guard Int(slot) < events.count else { throw BMSError.invalid("demo slot out of bounds") }
            let (t, type, p) = events[Int(slot)]
            body = [0xF3, 2, slot, UInt8(truncatingIfNeeded: t >> 24), UInt8(truncatingIfNeeded: t >> 16), UInt8(truncatingIfNeeded: t >> 8), UInt8(truncatingIfNeeded: t), type, UInt8(p >> 8), UInt8(truncatingIfNeeded: p)]
        }
        let raw = [UInt8(body.count)] + body
        if trace.count > 8000 { trace.removeFirst(1000) }
        trace.append(.init(direction: "TX", text: ":" + request.body.hex))
        trace.append(.init(direction: "RX-DEMO", text: ":" + raw.hex))
        var parser = FrameParser()
        return try parser.feed(Data((":" + raw.hex + "\r\n").utf8))[0].get()
    }
}
