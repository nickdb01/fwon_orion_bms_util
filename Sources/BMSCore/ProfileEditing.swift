import Foundation

public enum ProfileEditingError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ProfileChange: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var before: String
    public var after: String
}
public struct ProfileByteChange: Identifiable, Sendable {
    public var id: Int
    public var before: String
    public var after: String
}

public struct ProfileDraft: Sendable {
    public let baseline: ProfileSnapshot
    public private(set) var data: Data
    public private(set) var source: String
    public init(baseline: ProfileSnapshot) throws {
        guard baseline.schemaVersion == 1, baseline.layout == "3.0" else { throw ProfileEditingError.invalid("Unsupported profile backup format.") }
        try ProfileDecoder.validate(Array(baseline.data))
        self.baseline = baseline; data = baseline.data; source = "Current BMS profile"
    }
    public var settings: [ProfileSetting] { ProfileDecoder.settings(Array(data)) }
    public func editorValue(for id: String) -> String {
        guard let field = ProfileDecoder.fields.first(where:{ $0.name == id }), let setting = settings.first(where:{ $0.id == id }) else { return "" }
        return (Decimal(setting.rawValue)*Decimal(string:String(field.scale))!).description
    }
    public func editorUnit(for id: String) -> String { ProfileDecoder.fields.first(where:{ $0.name == id })?.unit ?? "raw" }
    public mutating func setDisplayValue(_ text: String, for id: String) throws {
        guard let field = ProfileDecoder.fields.first(where:{ $0.name == id }),
              text.range(of:"^-?[0-9]+(?:[.][0-9]+)?$",options:.regularExpression) != nil,
              let decimal = Decimal(string:text,locale:Locale(identifier:"en_US_POSIX")) else {
            throw ProfileEditingError.invalid("Enter a number using a decimal point; raw configured values must be whole numbers.")
        }
        var raw = decimal / Decimal(string:String(field.scale))!
        var rounded = Decimal(); NSDecimalRound(&rounded,&raw,0,.plain)
        guard raw == rounded else { throw ProfileEditingError.invalid("This setting changes in steps of \(field.scale) \(field.unit).") }
        try setRawValue(rounded.description,for:id)
    }
    public var changes: [ProfileChange] {
        let before = ProfileDecoder.settings(Array(baseline.data))
        return zip(before,settings).compactMap { old,new in
            old.rawValue == new.rawValue ? nil : .init(id:new.id,title:new.title,before:old.value,after:new.value)
        }
    }
    public var changedByteCount: Int { zip(baseline.data.prefix(ProfileDecoder.byteCount-4),data.prefix(ProfileDecoder.byteCount-4)).filter { $0 != $1 }.count }
    public var byteChanges: [ProfileByteChange] {
        (0..<(ProfileDecoder.byteCount-4)).compactMap { index in
            baseline.data[index] == data[index] ? nil : .init(id:index,before:String(format:"%02X",baseline.data[index]),after:String(format:"%02X",data[index]))
        }
    }
    public var otherChangedByteCount: Int {
        let known = Set(ProfileDecoder.fields.flatMap { Array($0.offset..<($0.offset+$0.width)) })
        return (0..<(ProfileDecoder.byteCount-4)).filter { !known.contains($0) && baseline.data[$0] != data[$0] }.count
    }
    public mutating func setRawValue(_ text: String, for id: String) throws {
        guard let field = ProfileDecoder.fields.first(where: { $0.name == id }), let value = Int64(text.trimmingCharacters(in:.whitespacesAndNewlines)) else {
            throw ProfileEditingError.invalid("Enter a whole-number raw configured value for this setting.")
        }
        let bits = field.width*8
        let minimum: Int64 = field.signed ? -(1 << (bits-1)) : 0
        let maximum: Int64 = field.signed ? (1 << (bits-1))-1 : (1 << bits)-1
        guard (minimum...maximum).contains(value) else { throw ProfileEditingError.invalid("\(field.title) must be between \(minimum) and \(maximum) in raw units.") }
        var bytes = Array(data)
        for i in 0..<field.width { bytes[field.offset+i] = UInt8(truncatingIfNeeded:value >> ((field.width-i-1)*8)) }
        data = ProfileDecoder.checksummed(bytes)
    }
    public mutating func replace(with bytes: Data, source: String) throws {
        try ProfileDecoder.validate(Array(bytes))
        // Unit type is a serialized byte verified against the reference parser.
        guard bytes[149] == baseline.data[149] else { throw ProfileEditingError.invalid("The imported profile's unit type differs from the connected BMS profile.") }
        guard bytes[3470] == baseline.data[3470] else { throw ProfileEditingError.invalid("The imported profile changes a reserved layout byte.") }
        data = bytes; self.source = source
    }
    public func validateForUpload() throws {
        try ProfileDecoder.validate(Array(data))
        guard changedByteCount > 0 else { throw ProfileEditingError.invalid("There are no profile changes to upload.") }
        func value(_ id: String) -> Int64 { settings.first { $0.id == id }!.rawValue }
        for (low,high) in [("MinimumCellVoltage","MaximumCellVoltage"),("MinimumPackVoltage","MaximumPackVoltage"),("DepletedSOC","ChargedSOC")] {
            guard value(low) == 0 || value(high) == 0 || value(low) < value(high) else { throw ProfileEditingError.invalid("\(low) must be lower than \(high).") }
        }
        guard data[149] == baseline.data[149] else { throw ProfileEditingError.invalid("Profile unit type cannot be changed by this uploader.") }
    }
    public var warnings: [String] {
        var result = ["Uploading changes the BMS configuration. Review the complete profile for your battery and equipment before continuing.","Validation checks file integrity and core relationships; it does not certify every vendor setting or table."]
        for id in ["MaximumCCL","MaximumDCL"] where settings.first(where: { $0.id == id })?.rawValue == 0 { result.append("\(id) is zero; this can prevent charging or discharging.") }
        if source != "Current BMS profile" { result.append("An imported profile must be prepared for the connected firmware. Matching the file layout alone does not establish firmware compatibility.") }
        if otherChangedByteCount > 0 { result.append("\(otherChangedByteCount) changed bytes are outside the 66 named settings. The complete imported profile, including tables, will be uploaded.") }
        return result
    }
    public var snapshot: ProfileSnapshot {
        var copy = baseline; copy.data = data; copy.settings = settings; copy.authenticated = false
        copy.notes = ["Staged profile; not a measurement of the active BMS configuration."]
        return copy
    }
}

extension ProfileDecoder {
    static func checksummed(_ bytes: [UInt8]) -> Data {
        var copy = bytes
        let sum = copy.dropLast(4).reduce(0x1234) { $0+Int($1) }
        for i in 0..<3 { copy[copy.count-3+i] = UInt8(truncatingIfNeeded:sum >> ((2-i)*8)) }
        return Data(copy)
    }
}

public enum ProfileFiles {
    public static func read(_ url: URL, for baseline: ProfileSnapshot) throws -> Data {
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw ProfileEditingError.invalid("Profile file exceeds 2 MB.") }
        let content = try Data(contentsOf:url)
        if url.pathExtension.lowercased() == "json" {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(ProfileSnapshot.self,from:content)
            guard profile.schemaVersion == 1, profile.layout == "3.0", profile.device.isDemo == baseline.device.isDemo else { throw ProfileEditingError.invalid("Unsupported profile backup or demo/hardware mismatch.") }
            if !baseline.device.isDemo, profile.device.firmware != baseline.device.firmware { throw ProfileEditingError.invalid("This JSON backup was made for different firmware. Use a profile prepared for the connected firmware.") }
            try ProfileDecoder.validate(Array(profile.data)); return profile.data
        }
        guard let text = String(data:content,encoding:.utf8) else { throw ProfileEditingError.invalid("Expected an XML .j2bms file, raw .j2ps profile or Orion profile JSON backup.") }
        let hex: String
        if text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<?xml") || text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<java") {
            guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw ProfileEditingError.invalid("XML entities and document type declarations are not supported.") }
            let delegate = ProfileXMLReader()
            let parser = XMLParser(data:content); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), !delegate.invalid, delegate.values.count == 1 else { throw ProfileEditingError.invalid("This vendor XML file has no unambiguous complete profileStr. Encrypted and older profile formats are not supported.") }
            hex = delegate.values[0]
        } else {
            let lines = text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count == 1 || (url.pathExtension.lowercased() == "j2ps" && lines.count == 2) else { throw ProfileEditingError.invalid("Expected one complete hexadecimal profile (or a two-line .j2ps file).") }
            hex = lines.last ?? ""
        }
        guard hex.count == ProfileDecoder.byteCount*2, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ProfileEditingError.invalid("Profile must contain exactly 3,474 bytes in the supported 3.0 layout.") }
        let chars = Array(hex.utf8)
        let bytes = stride(from:0,to:chars.count,by:2).map { UInt8(String(decoding:chars[$0..<$0+2],as:UTF8.self),radix:16)! }
        try ProfileDecoder.validate(bytes); return Data(bytes)
    }
    public static func save(_ profile: ProfileSnapshot, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(profile).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

/// Reads a data string only; never instantiates or executes Java XML objects.
private final class ProfileXMLReader: NSObject, XMLParserDelegate {
    var values: [String] = []
    var invalid = false
    private var stack: [String] = []
    private var propertyDepth: Int?
    private var stringDepth: Int?
    private var buffer = ""
    func parser(_ parser: XMLParser,didStartElement name: String,namespaceURI: String?,qualifiedName: String?,attributes: [String:String]) {
        stack.append(name)
        if attributes["property"] == "profileStr" {
            guard propertyDepth == nil, stack.count == 3, name == "void" else { invalid = true; return }
            propertyDepth = stack.count
        }
        if let depth = propertyDepth, stack.count == depth+1, name == "string" { stringDepth = stack.count; buffer = "" }
        if let depth = stringDepth, stack.count > depth { invalid = true }
    }
    func parser(_ parser: XMLParser,foundCharacters string: String) { if stringDepth != nil { buffer += string } }
    func parser(_ parser: XMLParser,didEndElement name: String,namespaceURI: String?,qualifiedName: String?) {
        if stringDepth == stack.count { values.append(buffer.trimmingCharacters(in:.whitespacesAndNewlines)); stringDepth = nil }
        if propertyDepth == stack.count { propertyDepth = nil }
        _ = stack.popLast()
    }
}
