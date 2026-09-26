import Foundation

/// Renders `{{path.to.value}}` placeholders against a JSON scope. Supports pipes:
/// `| json` (JSON-encode, for request bodies) and `| url` (percent-encode, for query strings).
public enum TemplateRenderer {
    public static func render(_ template: String, scope: JSONValue) -> String {
        guard template.contains("{{") else { return template }
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let expression = rest[open.upperBound..<close.lowerBound]
            out += evaluate(String(expression), scope: scope)
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    static func evaluate(_ expression: String, scope: JSONValue) -> String {
        let parts = expression.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = parts.first else { return "" }
        let value = lookup(path, in: scope)
        var text = string(value)
        for filter in parts.dropFirst() {
            switch filter.lowercased() {
            case "json":
                text = value.map { v in
                    if case .string = v { return JSONValue.string(text).jsonString }
                    return v.jsonString
                } ?? "null"
            case "url":
                text = text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
            case "upper":
                text = text.uppercased()
            case "lower":
                text = text.lowercased()
            case "trim":
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        return text
    }

    public static func lookup(_ path: String, in scope: JSONValue) -> JSONValue? {
        var current: JSONValue? = scope
        var remaining = Substring(path)
        while !remaining.isEmpty, let node = current {
            // Try the longest key that matches, so field names containing dots still resolve.
            var matched = false
            if case .object(let obj) = node {
                var candidate = remaining
                while true {
                    if let next = obj[String(candidate)] {
                        current = next
                        remaining = remaining.dropFirst(candidate.count)
                        if remaining.first == "." { remaining = remaining.dropFirst() }
                        matched = true
                        break
                    }
                    guard let dot = candidate.lastIndex(of: ".") else { break }
                    candidate = candidate[..<dot]
                }
            } else if case .array(let arr) = node {
                let key = remaining.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
                if let i = Int(key) {
                    guard i >= 0, i < arr.count else { return nil }
                    current = arr[i]
                    remaining = remaining.dropFirst(key.count)
                    if remaining.first == "." { remaining = remaining.dropFirst() }
                    matched = true
                } else if key == "count" || key == "length" {
                    current = .number(Double(arr.count))
                    remaining = remaining.dropFirst(key.count)
                    matched = true
                } else {
                    // Anything else applies to every element: `steps.1.records.Name` lists each name.
                    let rest = String(remaining)
                    return .array(arr.compactMap { lookup(rest, in: $0) })
                }
            }
            if !matched { return nil }
        }
        return current
    }

    public static func string(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return ValueParsing.editableNumber(n)
        case .string(let s): return s
        case .array(let a): return a.map { string($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .object: return value.jsonString
        }
    }

    /// Placeholder paths available to a step, for the editor's "Insert value" menu.
    public struct Token: Hashable, Sendable {
        public var label: String
        public var path: String
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+#")
        return set
    }()
}
