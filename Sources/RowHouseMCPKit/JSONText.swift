import Foundation
import RowHouseCore

/// JSON text with stable key order and the shortest round-tripping form of every number (3.3 rather
/// than JSONSerialization's 3.2999999999999998). Compact output never contains a raw newline, so it's
/// safe for newline-delimited JSON-RPC.
enum JSONText {
    static func compact(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out, indent: nil, level: 0)
        return out
    }

    static func pretty(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out, indent: "  ", level: 0)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String, indent: String?, level: Int) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let n):
            out += number(n)
        case .string(let s):
            string(s, into: &out)
        case .array(let items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                newline(&out, indent: indent, level: level + 1)
                write(item, into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent: indent, level: level)
            out += "]"
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{"
            for (i, key) in members.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                newline(&out, indent: indent, level: level + 1)
                string(key, into: &out)
                out += indent == nil ? ":" : ": "
                write(members[key]!, into: &out, indent: indent, level: level + 1)
            }
            newline(&out, indent: indent, level: level)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, indent: String?, level: Int) {
        guard let indent else { return }
        out += "\n"
        for _ in 0..<level { out += indent }
    }

    static func number(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
        return "\(n)"
    }

    private static func string(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
