import Foundation

public enum ProfileAccessError: Error, LocalizedError, Sendable {
    case passwordRequired, invalidPassword, passwordFormat, unsupportedLayout, relockFailed
    public var errorDescription: String? {
        switch self {
        case .passwordRequired: "The BMS profile is locked. Enter its password to read the settings."
        case .invalidPassword: "The BMS rejected the password. No automatic password retries were made."
        case .passwordFormat: "Enter the BMS profile password using 1–8 ASCII characters."
        case .unsupportedLayout: "Profile reading currently supports the verified 3.x firmware layout. This firmware's profile layout is not supported."
        case .relockFailed: "The profile session could not be confirmed re-locked. The connection was closed. Check the BMS lock status with the manufacturer utility before continuing."
        }
    }
}
public struct ProfileSetting: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var offset: Int
    public var rawValue: Int64
    public var value: String
}
public struct ProfileSnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var acquiredAt = Date()
    public var device: DeviceInfo
    public var layout = "3.0"
    public var data: Data
    public var settings: [ProfileSetting]
    public var authenticated: Bool
    public var notes: [String]
}

// Profile 3.0 is 3474 bytes. Its checksum is seeded with 0x1234,
// covers all but the final four bytes, and is stored in the final three bytes.
public enum ProfileDecoder {
    public static let byteCount = 3474
    public static func validate(_ bytes: [UInt8]) throws {
        guard bytes.count == byteCount else { throw BMSError.invalid("incomplete profile") }
        let checksum = bytes.dropLast(4).reduce(0x1234) { $0 + Int($1) }
        let stored = bytes.suffix(3).reduce(0) { $0 << 8 | Int($1) }
        guard stored == checksum else { throw BMSError.invalid("profile checksum mismatch; download again") }
    }
    static func block(_ reply: WireReply, offset: UInt16, count: UInt8) throws -> [UInt8] {
        let descriptor = UInt32(count) << 16 | UInt32(offset)
        guard reply.service == 0x7C, reply.profileDescriptor == descriptor,
              reply.payload.count == Int(count) + 2 else { throw BMSError.invalid("profile block address or length mismatch") }
        let data = Array(reply.payload.prefix(Int(count)))
        let checksum = [UInt8(0), count, UInt8(offset >> 8), UInt8(truncatingIfNeeded: offset)].reduce(0) { $0 + Int($1) } + data.reduce(0) { $0 + Int($1) }
        let stored = Int(reply.payload[Int(count)]) << 8 | Int(reply.payload[Int(count)+1])
        guard checksum == stored else { throw BMSError.invalid("profile block checksum mismatch") }
        return data
    }
    static func passwordKey(_ password: String) throws -> [UInt8] {
        let bytes = Array(password.utf8)
        guard (1...8).contains(bytes.count), bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { throw ProfileAccessError.passwordFormat }
        return bytes + [UInt8](repeating: 0, count: 8 - bytes.count)
    }
    public static func settings(_ bytes: [UInt8]) -> [ProfileSetting] {
        guard bytes.count == byteCount else { return [] }
        return fields.map { field in
            let data = Array(bytes[field.offset..<(field.offset + field.width)])
            var value = data.reduce(Int64(0)) { $0 << 8 | Int64($1) }
            if field.signed, value & (1 << (field.width * 8 - 1)) != 0 { value -= 1 << (field.width * 8) }
            let text: String
            if field.unit == "raw" { text = String(value) + " (raw)" }
            else { text = String(format: "%.*f", field.scale < 0.001 ? 4 : field.scale < 1 ? 1 : 0, Double(value) * field.scale) + " " + field.unit }
            return .init(id:field.name,title:field.title,offset:field.offset,rawValue:value,value:text)
        }
    }
    struct Field: Sendable {
        var name: String; var title: String; var offset: Int; var width: Int; var signed: Bool
        var scale: Double = 1; var unit: String = "raw"
    }
    static let fields: [Field] = [
        .init(name: "CanbusFrequency", title: "Canbus Frequency", offset: 0, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "Canbus2Frequency", title: "Canbus2 Frequency", offset: 1, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "Obd2EcuId", title: "Obd2 Ecu Id", offset: 2, width: 4, signed: false, scale: 1, unit: "raw"),
        .init(name: "TotalAmphours", title: "Total Amphours", offset: 7, width: 4, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaximumCellVoltage", title: "Maximum Cell Voltage", offset: 11, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "MinimumCellVoltage", title: "Minimum Cell Voltage", offset: 13, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "WeakcellVariance", title: "Weakcell Variance", offset: 15, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "MaximumPackVoltage", title: "Maximum Pack Voltage", offset: 19, width: 2, signed: false, scale: 0.1, unit: "V"),
        .init(name: "MinimumPackVoltage", title: "Minimum Pack Voltage", offset: 21, width: 2, signed: false, scale: 0.1, unit: "V"),
        .init(name: "DischargeRelayRestore", title: "Discharge Relay Restore", offset: 23, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "ChargeRelayRestore", title: "Charge Relay Restore", offset: 25, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaximumCCL", title: "Maximum CCL", offset: 27, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaximumDCL", title: "Maximum DCL", offset: 29, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "BiasCorrectionDischarge", title: "Bias Correction Discharge", offset: 31, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "BiasCorrectionCharge", title: "Bias Correction Charge", offset: 32, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaxChargeTime", title: "Max Charge Time", offset: 35, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaxChargeAmperage", title: "Max Charge Amperage", offset: 37, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "MaxChargeCellVoltage", title: "Max Charge Cell Voltage", offset: 39, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "MaxChargePackVoltage", title: "Max Charge Pack Voltage", offset: 41, width: 2, signed: false, scale: 0.1, unit: "V"),
        .init(name: "ChargeReenableTime", title: "Charge Reenable Time", offset: 43, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "SimulatedPackAmphours", title: "Simulated Pack Amphours", offset: 45, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "SimulatedPackStartSOC", title: "Simulated Pack Start SOC", offset: 47, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DischargeRelayRestoreSoc", title: "Discharge Relay Restore Soc", offset: 48, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "ChargeRelayRestoreSoc", title: "Charge Relay Restore Soc", offset: 49, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "SimulatedPackZeroSOC", title: "Simulated Pack Zero SOC", offset: 50, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "SimulatedPack100SOC", title: "Simulated Pack100 SOC", offset: 51, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "CurrentSensorType", title: "Current Sensor Type", offset: 52, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "CurrentSensorPolarity", title: "Current Sensor Polarity", offset: 53, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DepletedSOC", title: "Depleted SOC", offset: 54, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "ChargedSOC", title: "Charged SOC", offset: 55, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "MinimumSOH", title: "Minimum SOH", offset: 56, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateLowSOCStart", title: "Derate Low SOCStart", offset: 57, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateLowSOCAmperage", title: "Derate Low SOCAmperage", offset: 58, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateLowTempDCLStart", title: "Derate Low Temp DCLStart", offset: 59, width: 1, signed: true, scale: 1, unit: "raw"),
        .init(name: "DerateLowTempDCLAmperage", title: "Derate Low Temp DCLAmperage", offset: 60, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateLowTempCCLStart", title: "Derate Low Temp CCLStart", offset: 61, width: 1, signed: true, scale: 1, unit: "raw"),
        .init(name: "DerateLowTempCCLAmperage", title: "Derate Low Temp CCLAmperage", offset: 62, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighSOCStart", title: "Derate High SOCStart", offset: 63, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighSOCAmperage", title: "Derate High SOCAmperage", offset: 64, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighTempDCLStart", title: "Derate High Temp DCLStart", offset: 65, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighTempDCLAmperage", title: "Derate High Temp DCLAmperage", offset: 66, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighTempCCLStart", title: "Derate High Temp CCLStart", offset: 67, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "DerateHighTempCCLAmperage", title: "Derate High Temp CCLAmperage", offset: 68, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "LimitFlags", title: "Limit Flags", offset: 69, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "BalanceDeltaVoltage", title: "Balance Delta Voltage", offset: 70, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "BalanceVoltage", title: "Balance Voltage", offset: 72, width: 2, signed: false, scale: 0.0001, unit: "V"),
        .init(name: "BalanceDuration", title: "Balance Duration", offset: 74, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "BalanceDelay", title: "Balance Delay", offset: 76, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "MinimumFanTemperature", title: "Minimum Fan Temperature", offset: 78, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "FanDeltaTemperature", title: "Fan Delta Temperature", offset: 79, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "FanFlags", title: "Fan Flags", offset: 80, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "FanMonitorMaxVoltage", title: "Fan Monitor Max Voltage", offset: 81, width: 2, signed: false, scale: 1, unit: "raw"),
        .init(name: "IntakeThermistorNum", title: "Intake Thermistor Num", offset: 83, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "RelaysPopulated", title: "Relays Populated", offset: 84, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "VoltageDerateDclTime", title: "Voltage Derate Dcl Time", offset: 85, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "VoltageDerateCclTime", title: "Voltage Derate Ccl Time", offset: 86, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "VoltageRestoreDclTime", title: "Voltage Restore Dcl Time", offset: 87, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "VoltageRestoreCclTime", title: "Voltage Restore Ccl Time", offset: 88, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "VoltageDerateFailTime", title: "Voltage Derate Fail Time", offset: 89, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakDclOffset", title: "Peak Dcl Offset", offset: 90, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakCclOffset", title: "Peak Ccl Offset", offset: 91, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakIncDclTime", title: "Peak Inc Dcl Time", offset: 92, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakIncCclTime", title: "Peak Inc Ccl Time", offset: 93, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakDecDclTime", title: "Peak Dec Dcl Time", offset: 94, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PeakDecCclTime", title: "Peak Dec Ccl Time", offset: 95, width: 1, signed: false, scale: 1, unit: "raw"),
        .init(name: "PopulatedRemoteThermistors", title: "Populated Remote Thermistors", offset: 96, width: 4, signed: false, scale: 1, unit: "raw"),
    ]
}

final class ProfileReader {
    let transport: any DiagnosticTransport
    init(transport: any DiagnosticTransport) { self.transport = transport }
    func read(device: DeviceInfo, password: String?, progress: @Sendable (DownloadProgress) -> Void) throws -> ProfileSnapshot {
        guard device.isDemo || device.firmware.flatMap({ FirmwareVersion(code:$0) })?.major == 3 else { throw ProfileAccessError.unsupportedLayout }
        let key = try password.map(ProfileDecoder.passwordKey)
        var needsRelock = false
        var didAuthenticate = false
        let result: Result<ProfileSnapshot, Error>
        do {
            progress(.init(0, "Checking profile access…"))
            var locked = false
            do {
                let status = try transport.exchange(.profileLockStatus)
                guard status.payload.count >= 2, status.payload[1] <= 1 else { throw BMSError.invalid("invalid profile lock status") }
                locked = status.payload[1] == 0
            } catch BMSError.unsupported { /* Older firmware may only report access on the read itself. */ }
            func authenticate() throws {
                guard let key else { throw ProfileAccessError.passwordRequired }
                needsRelock = true
                progress(.init(0, "Authenticating profile access…"))
                do {
                    let challenge = try transport.exchange(.profileChallenge)
                    guard challenge.payload.count == 8 else { throw BMSError.invalid("invalid profile authentication challenge") }
                    if challenge.payload.contains(where: { $0 != 0 }) {
                        let response = zip(challenge.payload,key).map { $0 ^ $1 }
                        let reply = try transport.exchange(.profileAuthenticate(response))
                        guard reply.payload.count == 2, reply.payload.allSatisfy({ $0 == 0 }) else { throw ProfileAccessError.invalidPassword }
                    }
                    didAuthenticate = true
                } catch BMSError.rejected(let code) where code == 0x35 { throw ProfileAccessError.invalidPassword }
            }
            if locked { try authenticate() }
            var data: [UInt8] = []
            while data.count < ProfileDecoder.byteCount {
                try Task.checkCancellation()
                let offset = UInt16(data.count), count = UInt8(min(56, ProfileDecoder.byteCount - data.count))
                let request = ReadRequest.profileBlock(offset:offset,count:count)
                let reply: WireReply
                do { reply = try transport.exchange(request) }
                catch BMSError.rejected(let code) where code == 0x33 && !didAuthenticate {
                    try authenticate()
                    reply = try transport.exchange(request)
                }
                data += try ProfileDecoder.block(reply,offset:offset,count:count)
                progress(.init(Double(data.count) / Double(ProfileDecoder.byteCount), "Reading profile · \(data.count)/\(ProfileDecoder.byteCount) bytes"))
            }
            try Task.checkCancellation()
            try ProfileDecoder.validate(data)
            var notes = ["Complete profile bytes retained. Named settings cover the verified core prefix; other settings and tables remain in the raw backup. Raw values are labelled where display units are not verified."]
            if device.isDemo { notes.append("SYNTHETIC DEMO — no BMS profile was read.") }
            result = .success(.init(device:device,data:Data(data),settings:ProfileDecoder.settings(data),authenticated:didAuthenticate,notes:notes))
        } catch { result = .failure(error) }
        if needsRelock {
            // Cleanup must run even when the downloading Task has been cancelled.
            do { try transport.relockProfileSession() }
            catch { transport.close(); throw ProfileAccessError.relockFailed }
        }
        return try result.get()
    }
}
