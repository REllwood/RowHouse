import Foundation

/// The universal value stored in every register of a base. Mirrors JSON exactly so the on-disk
/// format stays human-readable and portable.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Strings contained in an array value (non-strings are skipped).
    public var stringArray: [String] {
        arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// True for null, empty strings, and empty arrays — the values a cell treats as "empty".
    public var isEmptyCell: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Fast (de)serialization via JSONSerialization

public enum JSONValueError: Error, Sendable {
    case invalidJSON
}

extension JSONValue {
    public init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = JSONValue(any: v) }
            self = .object(out)
        default:
            self = .null
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.isFinite ? n : NSNull()
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o):
            var out: [String: Any] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = v.anyValue }
            return out
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return JSONValue(any: any)
        } catch {
            throw JSONValueError.invalidJSON
        }
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Compact single-line JSON (safe for JSON Lines files: newlines inside strings are escaped).
    public func serialized(pretty: Bool = false, sortedKeys: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        if sortedKeys { options.insert(.sortedKeys) }
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: options)) ?? Data("null".utf8)
    }

    public var jsonString: String {
        String(decoding: serialized(), as: UTF8.self)
    }
}

// MARK: - Codable bridge

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n.isFinite ? n : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Converts any Codable value into a JSONValue (used for schema objects such as field options).
    public init<T: Encodable>(encoding value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let parsed = try? JSONValue.parse(data) else {
            self = .null
            return
        }
        self = parsed
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: serialized())
    }
}
