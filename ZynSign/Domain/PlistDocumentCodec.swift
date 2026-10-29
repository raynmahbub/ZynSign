import Foundation

/// Typed, Sendable representation of an arbitrary Property List value, used by
/// both pre-signing `Info.plist` overrides and the in-app File Manager Plist Editor.
indirect enum PlistCustomValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    case date(Date)
    case data(Data)
    case array([PlistCustomValue])
    case dictionary([String: PlistCustomValue])

    enum ValueKind: String, CaseIterable, Sendable {
        case string = "String"
        case boolean = "Boolean"
        case integer = "Integer"
        case real = "Number"
        case array = "Array"
        case dictionary = "Dictionary"
    }

    var kindLabel: String {
        switch self {
        case .string: return "String"
        case .boolean: return "Boolean"
        case .integer: return "Integer"
        case .real: return "Real"
        case .date: return "Date"
        case .data: return "Data"
        case .array(let items): return "Array (\(items.count))"
        case .dictionary(let map): return "Dictionary (\(map.count))"
        }
    }

    var summaryText: String {
        switch self {
        case .string(let value): return value
        case .boolean(let flag): return flag ? "YES" : "NO"
        case .integer(let num): return String(num)
        case .real(let num): return String(num)
        case .date(let date): return ISO8601DateFormatter().string(from: date)
        case .data(let bytes): return "\(bytes.count) bytes"
        case .array(let items): return "[\(items.count) item(s)]"
        case .dictionary(let map): return "{\(map.count) key(s)}"
        }
    }

    func toFoundationObject() -> Any {
        switch self {
        case .string(let text): return text
        case .boolean(let flag): return flag
        case .integer(let num): return num
        case .real(let num): return num
        case .date(let date): return date
        case .data(let bytes): return bytes
        case .array(let list): return list.map { $0.toFoundationObject() }
        case .dictionary(let map): return map.mapValues { $0.toFoundationObject() }
        }
    }

    static func fromFoundationObject(_ any: Any) -> PlistCustomValue? {
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            let objCType = String(cString: number.objCType)
            if objCType == "f" || objCType == "d" {
                return .real(number.doubleValue)
            }
            return .integer(number.intValue)
        }
        if let text = any as? String { return .string(text) }
        if let date = any as? Date { return .date(date) }
        if let data = any as? Data { return .data(data) }
        if let list = any as? [Any] {
            return .array(list.compactMap(fromFoundationObject))
        }
        if let dict = any as? [String: Any] {
            var converted: [String: PlistCustomValue] = [:]
            for (key, val) in dict {
                if let mapped = fromFoundationObject(val) {
                    converted[key] = mapped
                }
            }
            return .dictionary(converted)
        }
        return nil
    }
}

/// Codec for decoding, validating, diffing, and re-serializing XML and Binary
/// Property Lists in both `FilesView` and pre-signing `Info.plist` / `Entitlements` editors.
enum PlistDocumentCodec {

    enum Format: String, CaseIterable, Sendable {
        case xml = "XML"
        case binary = "Binary"

        var serializationFormat: PropertyListSerialization.PropertyListFormat {
            switch self {
            case .xml: return .xml
            case .binary: return .binary
            }
        }
    }

    struct DecodedPlist: Equatable, Sendable {
        var root: [String: PlistCustomValue]
        var detectedFormat: Format
        var rawXML: String
    }

    enum CodecError: Error, Equatable, Sendable {
        case invalidUTF8
        case notADictionaryRoot
        case parseFailed(String)

        var message: String {
            switch self {
            case .invalidUTF8:
                return "The XML text is not valid UTF-8."
            case .notADictionaryRoot:
                return "The property list root must be a Dictionary (<dict>)."
            case .parseFailed(let detail):
                return "Invalid property list: \(detail)"
            }
        }
    }

    static func decode(_ data: Data) throws -> DecodedPlist {
        var rawFormat = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &rawFormat
            )
        } catch {
            throw CodecError.parseFailed(error.localizedDescription)
        }
        guard let dict = object as? [String: Any],
              case .dictionary(let typed)? = PlistCustomValue.fromFoundationObject(dict) else {
            throw CodecError.notADictionaryRoot
        }
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        let xmlString = String(data: xmlData, encoding: .utf8) ?? ""
        let format: Format = (rawFormat == .binary) ? .binary : .xml
        return DecodedPlist(root: typed, detectedFormat: format, rawXML: xmlString)
    }

    static func parseXML(_ xml: String) throws -> [String: PlistCustomValue] {
        guard let data = xml.data(using: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return try decode(data).root
    }

    static func encode(_ root: [String: PlistCustomValue], format: Format) throws -> Data {
        let foundation = root.mapValues { $0.toFoundationObject() }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: foundation,
                format: format.serializationFormat,
                options: 0
            )
        } catch {
            throw CodecError.parseFailed(error.localizedDescription)
        }
    }

    static func renderXML(_ root: [String: PlistCustomValue]) throws -> String {
        let data = try encode(root, format: .xml)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return text
    }

    /// Computes a human-readable key-level diff between two plist dictionaries.
    static func diffSummary(
        before: [String: PlistCustomValue],
        after: [String: PlistCustomValue]
    ) -> [String] {
        var changes: [String] = []
        let allKeys = Set(before.keys).union(after.keys).sorted()
        for key in allKeys {
            switch (before[key], after[key]) {
            case (nil, let added?):
                changes.append("+ \(key) = \(added.summaryText)")
            case (let removed?, nil):
                changes.append("- \(key) (was \(removed.summaryText))")
            case (let old?, let new?) where old != new:
                changes.append("~ \(key): \(old.summaryText) → \(new.summaryText)")
            default:
                break
            }
        }
        return changes
    }
}
