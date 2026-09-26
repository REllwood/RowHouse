import Foundation
import RowHouseCore

/// A JSON-RPC 2.0 error returned instead of a result.
struct RPCError: Error {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    var code: Int
    var message: String

    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
}

enum JSONRPC {
    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue, _ error: RPCError) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(error.code)), "message": .string(error.message)])])
    }
}

/// A tool failure the model can act on. It's reported as a tool result with `isError: true`, not as a
/// protocol error, so the model sees the message and can correct its call.
struct ToolError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Validated access to a tool call's `arguments`.
struct ToolArguments {
    let values: [String: JSONValue]

    init(_ json: JSONValue?, allowed: Set<String>) throws(ToolError) {
        switch json {
        case nil, .null?:
            values = [:]
        case .object(let object)?:
            values = object
        default:
            throw ToolError("Tool arguments must be a JSON object")
        }
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            let accepted = allowed.isEmpty ? "This tool takes no arguments." : "Accepted arguments: \(allowed.sorted().joined(separator: ", "))."
            throw ToolError("Unknown argument\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", ")). \(accepted)")
        }
    }

    private func present(_ key: String) -> JSONValue? {
        guard let value = values[key], !value.isNull else { return nil }
        return value
    }

    /// A required, non-empty string.
    func string(_ key: String) throws(ToolError) -> String {
        guard let value = try optionalString(key) else { throw ToolError("Missing required argument \(key)") }
        return value
    }

    func optionalString(_ key: String) throws(ToolError) -> String? {
        guard let value = present(key) else { return nil }
        let text: String
        switch value {
        case .string(let s): text = s
        case .number(let n): text = JSONText.number(n)
        default: throw ToolError("\(key) must be a string")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ToolError("\(key) can't be empty") }
        return trimmed
    }

    /// A string that may be empty (descriptions, comment text before validation).
    func optionalText(_ key: String) throws(ToolError) -> String? {
        guard let value = present(key) else { return nil }
        guard let s = value.stringValue else { throw ToolError("\(key) must be a string") }
        return s
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws(ToolError) -> Int {
        guard let value = present(key) else { return fallback }
        let number: Double?
        switch value {
        case .number(let n): number = n
        case .string(let s): number = Double(s.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        guard let n = number, n.isFinite, n == n.rounded() else { throw ToolError("\(key) must be a whole number") }
        guard n >= Double(range.lowerBound) && n <= Double(range.upperBound) else {
            throw ToolError("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return Int(n)
    }

    func bool(_ key: String, default fallback: Bool) throws(ToolError) -> Bool {
        guard let value = present(key) else { return fallback }
        switch value {
        case .bool(let b): return b
        case .string(let s) where s.lowercased() == "true": return true
        case .string(let s) where s.lowercased() == "false": return false
        default: throw ToolError("\(key) must be true or false")
        }
    }

    /// Some clients send arrays and objects as JSON text; both forms are accepted.
    private func structured(_ key: String) -> JSONValue? {
        guard let value = present(key) else { return nil }
        if let s = value.stringValue, let first = s.trimmingCharacters(in: .whitespaces).first, first == "[" || first == "{",
           let parsed = try? JSONValue.parse(s) {
            return parsed
        }
        return value
    }

    func array(_ key: String) throws(ToolError) -> [JSONValue]? {
        guard let value = structured(key) else { return nil }
        guard let array = value.arrayValue else { throw ToolError("\(key) must be an array") }
        return array
    }

    func object(_ key: String) throws(ToolError) -> [String: JSONValue]? {
        guard let value = structured(key) else { return nil }
        guard let object = value.objectValue else { throw ToolError("\(key) must be an object") }
        return object
    }

    func stringArray(_ key: String) throws(ToolError) -> [String]? {
        guard let items = try array(key) else { return nil }
        var out: [String] = []
        for item in items {
            switch item {
            case .string(let s): out.append(s)
            case .number(let n): out.append(JSONText.number(n))
            default: throw ToolError("\(key) must be an array of strings")
            }
        }
        return out
    }
}

/// Small builders for tool input schemas (JSON Schema).
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    static func string(_ description: String, enumerated values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int? = nil, default fallback: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description), "minimum": .number(Double(minimum))]
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        if let fallback { schema["default"] = .number(Double(fallback)) }
        return .object(schema)
    }

    static func boolean(_ description: String, default fallback: Bool? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "boolean", "description": .string(description)]
        if let fallback { schema["default"] = .bool(fallback) }
        return .object(schema)
    }

    static func array(_ items: JSONValue, _ description: String, minItems: Int? = nil, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": items, "description": .string(description)]
        if let minItems { schema["minItems"] = .number(Double(minItems)) }
        if let maxItems { schema["maxItems"] = .number(Double(maxItems)) }
        return .object(schema)
    }

    static func freeObject(_ description: String) -> JSONValue {
        .object(["type": "object", "description": .string(description), "additionalProperties": true])
    }
}
