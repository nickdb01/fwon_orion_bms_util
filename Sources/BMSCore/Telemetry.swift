import Foundation

public enum ParameterPID: UInt16, Codable, CaseIterable, Sendable {
    case maximumCells = 0xF006, packVoltage = 0xF00D, packCurrent = 0xF00C
    case packPower = 0xF082, stateOfHealth = 0xF013
    case soc = 0xF00F, chargeLimit = 0xF00A, dischargeLimit = 0xF00B
    case highTemperature = 0xF028, lowTemperature = 0xF029, averageTemperature = 0xF02A
    case relayState = 0xF004, limitReasons = 0xF019
    case lowCell = 0xF032, highCell = 0xF033, observedCapacity = 0xF044, observedSOC = 0xF045
    public var key: String { String(describing: self) }
    public var title: String {
        switch self {
        case .maximumCells: "Maximum cells"
        case .packPower: "Pack power"
        case .stateOfHealth: "State of health"
        case .packVoltage: "Pack voltage"
        case .packCurrent: "Pack current"
        case .soc: "State of charge"
        case .chargeLimit: "Charge current limit"
        case .dischargeLimit: "Discharge current limit"
        case .highTemperature: "Highest temperature"
        case .lowTemperature: "Lowest temperature"
        case .averageTemperature: "Average temperature"
        case .relayState: "Output state bits"
        case .limitReasons: "Limit reduction bits"
        case .lowCell: "Lowest cell voltage"
        case .highCell: "Highest cell voltage"
        case .observedCapacity: "Observed capacity"
        case .observedSOC: "Observed state of charge"
        }
    }
    public var unit: String {
        switch self {
        case .packVoltage, .lowCell, .highCell: "V"
        case .packCurrent, .chargeLimit, .dischargeLimit: "A"
        case .packPower: "kW"
        case .soc, .observedSOC, .stateOfHealth: "%"
        case .highTemperature, .lowTemperature, .averageTemperature: "°C"
        case .observedCapacity: "Ah"
        default: ""
        }
    }
    var byteCount: Int {
        switch self { case .maximumCells, .stateOfHealth, .soc, .observedSOC, .highTemperature, .lowTemperature, .averageTemperature: 1; default: 2 }
    }
    public func decode(_ bytes: [UInt8]) throws -> Double {
        guard bytes.count == byteCount else { throw BMSError.invalid("\(title) needs \(byteCount) bytes") }
        let n = bytes.reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
        switch self {
        case .packCurrent, .packPower: return Double(Int16(bitPattern: n)) * 0.1
        case .highTemperature, .lowTemperature, .averageTemperature: return Double(Int8(bitPattern: bytes[0]))
        case .soc, .observedSOC: return Double(n) * 0.5
        case .packVoltage, .observedCapacity: return Double(n) * 0.1
        case .lowCell, .highCell: return Double(n) * 0.0001
        default: return Double(n)
        }
    }
}
public enum CellQuantity: UInt16, Codable, CaseIterable, Sendable {
    case voltage = 0xF100, resistance = 0xF200, openVoltage = 0xF300
    public var unit: String { self == .resistance ? "mΩ" : "V" }
    public var title: String { switch self { case .voltage: "Voltage"; case .resistance: "Resistance"; case .openVoltage: "Open-cell voltage" } }
    public func decode(_ bytes: [UInt8], bank: UInt8, maximum: Int) throws -> [Int: Double] {
        guard bank < 2, maximum > 0, maximum <= 16, bytes.count % 2 == 0 else { throw BMSError.invalid("invalid Junior cell bank") }
        let start = Int(bank) * 12
        let required = min(12, max(0, maximum - start))
        guard bytes.count >= required * 2, bytes.count <= 24 else { throw BMSError.invalid("truncated cell bank") }
        var values: [Int: Double] = [:]
        for offset in 0..<required {
            let raw = UInt16(bytes[offset * 2]) << 8 | UInt16(bytes[offset * 2 + 1])
            values[start + offset + 1] = self == .resistance ? Double(raw & 0x7FFF) * 0.01 : Double(raw) * 0.0001
        }
        return values
    }
}
public enum CellFlag: UInt8, Sendable { case populated = 0, balancing = 1, low = 2, open = 3, weak = 4, high = 6 }
public struct LiveReading: Codable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var unit: String
    public var value: Double?
    public var acquiredAt: Date
    public var rawHex: String
    public var note: String?
    public var id: String { key }
    public var formatted: String {
        guard let value else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(unit == "V" ? 3 : 1))) + (unit.isEmpty ? "" : " " + unit)
    }
}
public struct CellReading: Codable, Sendable, Identifiable {
    public var number: Int
    public var voltage: Double?
    public var resistance: Double? = nil
    public var openVoltage: Double? = nil
    public func value(for quantity: CellQuantity) -> Double? { switch quantity { case .voltage: voltage; case .resistance: resistance; case .openVoltage: openVoltage } }
    public var acquiredAt: Date?
    public var populated: Bool?
    public var balancing: Bool?
    public var id: Int { number }
}
public struct LiveSnapshot: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var startedAt = Date()
    public var finishedAt = Date()
    public var device: DeviceInfo
    public var readings: [LiveReading] = []
    public var cells: [CellReading] = []
    public var notes: [String] = []
    public var cellRaw: [String] = []
    public init(device: DeviceInfo) { self.device = device }
    public func reading(_ pid: ParameterPID) -> LiveReading? { readings.first { $0.key == pid.key } }
}
public struct TrendPoint: Identifiable, Sendable {
    public var id: String { "\(key)|\(time.timeIntervalSince1970)|\(segment)" }
    public var time: Date
    public var key: String
    public var value: Double
    public var segment: Int
    public init(time: Date, key: String, value: Double, segment: Int) { self.time = time; self.key = key; self.value = value; self.segment = segment }
}
public enum LiveDecoding {
    public static func flags(_ bytes: [UInt8], maximum: Int) throws -> [Bool] {
        guard maximum > 0, maximum <= 16, bytes.count * 8 >= maximum else { throw BMSError.invalid("truncated cell flags") }
        return (0..<maximum).map { bytes[$0 / 8] & (1 << (7 - $0 % 8)) != 0 }
    }
    public static func limitReasons(_ bits: UInt16) -> [String] {
        let map: [(UInt16, String)] = [(1,"Discharge: SOC"),(2,"Discharge: resistance"),(4,"Discharge: temperature"),(8,"Discharge: cell voltage"),(16,"Discharge: pack voltage"),(64,"Voltage failsafe"),(128,"Multi-unit communication"),(0x200,"Charge: SOC"),(0x400,"Charge: resistance"),(0x800,"Charge: temperature"),(0x1000,"Charge: cell voltage"),(0x2000,"Charge: pack voltage")]
        return map.filter { bits & $0.0 != 0 }.map(\.1)
    }
}
