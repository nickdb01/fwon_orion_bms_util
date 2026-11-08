import Foundation

public enum DiagnosticDecoder {
    public static func dtc(_ value: UInt16) -> String {
        let prefix = ["P", "C", "B", "U"][Int(value >> 14)]
        return prefix + String(format: "%04X", value & 0x3FFF)
    }
    public static func faultCodes(_ reply: WireReply) throws -> [UInt16] {
        guard [0x43, 0x47, 0x4A].contains(reply.service) else { throw BMSError.invalid("not a fault reply") }
        let count = Int(reply.pid)
        guard reply.payload.count == count * 2 else { throw BMSError.invalid("fault count and payload size differ") }
        return stride(from: 0, to: reply.payload.count, by: 2).map {
            UInt16(reply.payload[$0]) << 8 | UInt16(reply.payload[$0 + 1])
        }
    }
    public static func event(_ reply: WireReply, expectedSlot: UInt8) throws -> BMSEvent {
        let p = reply.payload
        guard reply.service == 0xF3, reply.pid == 2, p.count == 8, p[0] == expectedSlot else {
            throw BMSError.invalid("event record must contain its slot and exactly eight data bytes")
        }
        let timestamp = UInt32(p[1]) << 24 | UInt32(p[2]) << 16 | UInt32(p[3]) << 8 | UInt32(p[4])
        return BMSEvent(slot: p[0], runtimeSeconds: timestamp, type: p[5], parameter: UInt16(p[6]) << 8 | UInt16(p[7]))
    }
    public static func signature(_ reply: WireReply) throws -> String {
        let name = try ascii(reply.payload, range: 1..<11)
        // Junior-family signatures plus ORIONBMS04, explicitly recognized as type 4
        // by the reference utility and validated on connected hardware.
        guard ["ORIONBMS03", "ORIONBMS04", "ORIONBMS05", "ORIONBMS06", "ORIONBMS07", "ORIONBMS08"].contains(name) else {
            throw BMSError.wrongDevice(name)
        }
        return name
    }
    public static func ascii(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw BMSError.invalid("truncated device metadata") }
        let value = Array(bytes[range])
        guard value.allSatisfy({ (32...126).contains($0) }), let result = String(bytes: value, encoding: .ascii) else {
            throw BMSError.invalid("device metadata is not printable ASCII")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
    public static func faultDescription(_ code: String) -> String {
        let names = [
            "P0A02": "Weak pack", "P0A04": "Open cell wiring", "P0A05": "Input power supply",
            "P0A06": "Charge limit enforcement", "P0A07": "Discharge limit enforcement",
            "P0A08": "Charger safety output", "P0A09": "Internal hardware",
            "P0A0A": "Internal temperature sensor", "P0A0B": "Internal software",
            "P0A0C": "Cell voltage too high", "P0A0D": "Cell voltage above 5 V",
            "P0A0E": "Cell voltage too low", "P0A0F": "Cell measurement circuitry",
            "P0A10": "Pack temperature too high", "P0A11": "Abnormal state of charge behavior", "P0A12": "Cell balancing inactive",
            "P0A1F": "Internal cell communication", "P0A80": "Weak cell", "P0A81": "Fan monitoring",
            "P0A95": "High voltage interlock", "P0A9C": "Battery temperature sensor",
            "P0AA1": "Precharge circuit", "P0AA6": "Isolation", "P0AC0": "Current sensor",
            "P0ACA": "Charge interlock", "P0AFA": "Low cell voltage",
            "P0560": "Redundant power supply", "U0100": "External communication"
        ]
        return names[code] ?? "Unmapped diagnostic code — retain for service review"
    }
    public static func eventDescription(type: UInt8, parameter p: UInt16) -> String {
        switch type {
        case 0: return "Empty or unclassified slot"
        case 1: return "SOC drift to \(p >> 9)% · cell \(p & 0x1FF)"
        case 2:
            let reason: String
            if p & 128 != 0 { reason = "wake from sleep" }
            else if p & 256 != 0 { reason = "user reset" }
            else if p & 512 != 0 { reason = "watchdog reset" }
            else if p & 1024 != 0 { reason = "processor trap reset" }
            else if p & 2048 != 0 { reason = "brownout reset" }
            else { reason = "power-on reset" }
            return "BMS started · \(reason)"
        case 3:
            return [1: "Balancing stopped", 2: "Balancing started", 3: "Balancing paused for cooling", 5: "Balancing paused for chip temperature", 4: "Balancing resumed", 6: "Extended balancing started", 7: "Extended balancing ended"][Int(p & 0xFF)] ?? unknown(type, p)
        case 4:
            if p == 0 { return "Unclassified fault event" }
            if p == 1 { return "Fault codes were cleared" }
            return "Fault recorded · \(dtc(p)) · \(faultDescription(dtc(p)))"
        case 5: return p == 1 ? "Discharge pulse available" : "Discharge pulse exhausted"
        case 6: return p == 1 ? "Charge pulse available" : "Charge pulse exhausted"
        case 7: return "Battery cycle completed · \(p)"
        case 20: return relay("Charge enable", p, charge: true)
        case 21: return relay("Charger safety", p, charge: true)
        case 22: return relay("Discharge enable", p, charge: false)
        case 23: return simpleOutput("Multipurpose enable", p, type)
        case 24...28: return simpleOutput("Multipurpose output \(type - 23)", p, type)
        case 41: return "BMS entered low power sleep"
        default: return unknown(type, p)
        }
    }
    private static func unknown(_ type: UInt8, _ parameter: UInt16) -> String {
        String(format: "Unmapped event 0x%02X · parameter 0x%04X", type, parameter)
    }
    private static func simpleOutput(_ name: String, _ p: UInt16, _ type: UInt8) -> String {
        p == 2 ? "\(name) enabled" : p == 1 ? "\(name) disabled" : unknown(type, p)
    }
    private static func relay(_ name: String, _ p: UInt16, charge: Bool) -> String {
        if p == 2 { return "\(name) enabled" }
        let reasons = charge
            ? [1: "", 3: "high current", 4: "charge limit zero", 5: "high SOC", 6: "high voltage", 7: "temperature", 8: "open cell wiring"]
            : [1: "", 3: "high current", 4: "discharge limit zero", 5: "low SOC", 6: "low voltage", 7: "temperature", 8: "open cell wiring"]
        guard let reason = reasons[Int(p)] else { return "\(name) changed · parameter \(p)" }
        return "\(name) disabled" + (reason.isEmpty ? "" : " · \(reason)")
    }
}
