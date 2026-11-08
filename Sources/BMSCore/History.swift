import Foundation

public struct HistoricalStatistic: Codable, Identifiable, Sendable {
    public var name: String
    public var value: UInt32?
    public var unit: String
    public var id: String { name }
    public var formatted: String {
        guard let value else { return "Unavailable on this response" }
        return unit == "seconds" ? BMSEvent.formatRuntime(value) : String(value)
    }
}
public struct HistoricalSnapshot: Codable, Sendable {
    public var device: DeviceInfo
    public var acquiredAt = Date()
    public var rawHex: String
    public var statistics: [HistoricalStatistic]
    public var runtimeSeconds: UInt32? { statistics.first?.value }
    public static func decode(_ reply: WireReply, device: DeviceInfo) throws -> HistoricalSnapshot {
        guard reply.service == 0xF3, reply.pid == 1, reply.payload.count >= 14 else { throw BMSError.invalid("truncated historical data") }
        // The vendor MRAM table uses little-endian fields; event records use big-endian.
        let definitions: [(String,Int,Int,String)] = [
            ("Lifetime runtime",0,4,"seconds"),("Power-ups",8,2,"count"),("Profile updates",10,2,"count"),("Pack cycles",12,2,"count"),
            ("Time above 45°C",24,4,"seconds"),("Time above 60°C",28,4,"seconds"),("Time below −20°C",32,4,"seconds"),
            ("Time above cell voltage limit",36,2,"seconds"),("Time below cell voltage limit",38,2,"seconds"),
            ("Over-voltage events",40,1,"count"),("Under-voltage events",41,1,"count"),("Charge enforcement events",42,1,"count"),("Discharge enforcement events",43,1,"count"),
            ("Time cell voltage above 5 V",44,4,"seconds"),("Time pack voltage above 61 V",48,4,"seconds"),
            ("Discharge pulse events",56,2,"count"),("Charge pulse events",58,2,"count")
        ]
        let values = definitions.map { name, offset, length, unit in
            let value: UInt32? = offset + length <= reply.payload.count ? (0..<length).reduce(UInt32(0)) { $0 | UInt32(reply.payload[offset + $1]) << ($1 * 8) } : nil
            return HistoricalStatistic(name:name,value:value,unit:unit)
        }
        return HistoricalSnapshot(device:device,rawHex:reply.bytes.hex,statistics:values)
    }
}
public struct FirmwareVersion: Comparable, Sendable {
    public let major: Int, minor: Int, patch: Int
    public init?(code: String) {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let digits = Array(code)
        guard let a = Int(String(digits[0...1])), let b = Int(String(digits[2...3])), let c = Int(String(digits[4...5])) else { return nil }
        major = a; minor = b; patch = c
    }
    public static func < (a: Self, b: Self) -> Bool { (a.major,a.minor,a.patch) < (b.major,b.minor,b.patch) }
    public var description: String { "\(major).\(minor).\(patch)" }
}
