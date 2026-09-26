import Foundation

extension FormulaFunctionRegistry {
    static let textFunctions: [FormulaFunction] = [
        FormulaFunction(
            "CONCATENATE(text1, [text2, …])", .text, .atLeast(1),
            summary: "Joins all arguments into one text value; arrays are expanded."
        ) { call in
            .text(call.expandedValues().map { $0.textValue(in: call.timeZone) }.joined())
        },

        FormulaFunction("LEN(text)", .text, .exactly(1), summary: "Returns the number of characters in the text.") { call in
            .number(Double(call.text(0).count))
        },

        FormulaFunction("LOWER(text)", .text, .exactly(1), summary: "Converts the text to lowercase.") { call in
            .text(call.text(0).lowercased())
        },

        FormulaFunction("UPPER(text)", .text, .exactly(1), summary: "Converts the text to uppercase.") { call in
            .text(call.text(0).uppercased())
        },

        FormulaFunction(
            "TRIM(text)", .text, .exactly(1),
            summary: "Removes leading and trailing whitespace and collapses runs of spaces into one."
        ) { call in
            .text(FormulaText.trim(call.text(0)))
        },

        FormulaFunction(
            "LEFT(text, count)", .text, .exactly(2),
            summary: "Returns the first count characters of the text."
        ) { call in
            let count = try call.integer(1)
            guard count >= 0 else { throw FormulaError("LEFT count must be 0 or greater") }
            return .text(String(call.text(0).prefix(count)))
        },

        FormulaFunction(
            "RIGHT(text, count)", .text, .exactly(2),
            summary: "Returns the last count characters of the text."
        ) { call in
            let count = try call.integer(1)
            guard count >= 0 else { throw FormulaError("RIGHT count must be 0 or greater") }
            return .text(String(call.text(0).suffix(count)))
        },

        FormulaFunction(
            "MID(text, start, count)", .text, .exactly(3),
            summary: "Returns count characters starting at the 1-based position start."
        ) { call in
            let start = try call.integer(1)
            let count = try call.integer(2)
            guard start >= 1 else { throw FormulaError("MID start must be 1 or greater") }
            guard count >= 0 else { throw FormulaError("MID count must be 0 or greater") }
            return .text(String(call.text(0).dropFirst(start - 1).prefix(count)))
        },

        FormulaFunction(
            "FIND(needle, haystack, [start])", .text, .range(2, 3),
            summary: "Returns the 1-based position of needle in haystack (case-sensitive), or 0 if not found."
        ) { call in
            let start = try max(call.integer(2, default: 1), 1)
            let position = FormulaText.position(of: Array(call.text(0)), in: Array(call.text(1)), from: start)
            return .number(Double(position ?? 0))
        },

        FormulaFunction(
            "SEARCH(needle, haystack, [start])", .text, .range(2, 3),
            summary: "Returns the 1-based position of needle in haystack (case-insensitive), or blank if not found."
        ) { call in
            let start = try max(call.integer(2, default: 1), 1)
            let needle = FormulaText.caseFolded(call.text(0))
            let haystack = FormulaText.caseFolded(call.text(1))
            guard let position = FormulaText.position(of: needle, in: haystack, from: start) else { return .blank }
            return .number(Double(position))
        },

        FormulaFunction(
            "SUBSTITUTE(text, old, new, [index])", .text, .range(3, 4),
            summary: "Replaces occurrences of old with new; with index, replaces only that occurrence."
        ) { call in
            var occurrence: Int?
            if call.hasValue(3) {
                let index = try call.integer(3)
                guard index >= 1 else { throw FormulaError("SUBSTITUTE index must be 1 or greater") }
                occurrence = index
            }
            return .text(FormulaText.substitute(call.text(0), call.text(1), with: call.text(2), occurrence: occurrence))
        },

        FormulaFunction(
            "REPLACE(text, start, count, replacement)", .text, .exactly(4),
            summary: "Replaces count characters starting at the 1-based position start with replacement."
        ) { call in
            let start = try call.integer(1)
            let count = try call.integer(2)
            guard start >= 1 else { throw FormulaError("REPLACE start must be 1 or greater") }
            guard count >= 0 else { throw FormulaError("REPLACE count must be 0 or greater") }
            let characters = Array(call.text(0))
            let lower = min(start - 1, characters.count)
            let upper = min(lower + count, characters.count)
            return .text(String(characters[..<lower]) + call.text(3) + String(characters[upper...]))
        },

        FormulaFunction(
            "REPT(text, count)", .text, .exactly(2),
            summary: "Repeats the text count times."
        ) { call in
            let count = try call.integer(1)
            guard count >= 0 else { throw FormulaError("REPT count must be 0 or greater") }
            let text = call.text(0)
            let (length, overflow) = text.count.multipliedReportingOverflow(by: count)
            guard !overflow, length <= FormulaText.maximumGeneratedLength else {
                throw FormulaError("REPT result is too long")
            }
            return .text(String(repeating: text, count: count))
        },

        FormulaFunction(
            "T(value)", .text, .exactly(1),
            summary: "Returns the value if it is text, otherwise blank."
        ) { call in
            if case .text(let text) = FormulaCoercion.singleValue(call.value(0)) {
                return .text(text)
            }
            return .blank
        },

        FormulaFunction(
            "ENCODE_URL_COMPONENT(text)", .text, .exactly(1),
            summary: "Percent-encodes the text for use in a URL, like JavaScript's encodeURIComponent."
        ) { call in
            let text = call.text(0)
            return .text(text.addingPercentEncoding(withAllowedCharacters: FormulaText.urlComponentAllowed) ?? text)
        },
    ]

    static let regexFunctions: [FormulaFunction] = [
        FormulaFunction(
            "REGEX_MATCH(text, pattern)", .regex, .exactly(2),
            summary: "Returns true if the text matches the regular expression."
        ) { call in
            let text = call.text(0)
            let regex = try FormulaRegexCache.regex(for: call.text(1))
            return .bool(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
        },

        FormulaFunction(
            "REGEX_EXTRACT(text, pattern)", .regex, .exactly(2),
            summary: "Returns the first substring that matches the regular expression, or blank."
        ) { call in
            let text = call.text(0)
            let regex = try FormulaRegexCache.regex(for: call.text(1))
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text),
                  !range.isEmpty
            else { return .blank }
            return .text(String(text[range]))
        },

        FormulaFunction(
            "REGEX_REPLACE(text, pattern, replacement)", .regex, .exactly(3),
            summary: "Replaces every match of the regular expression; $1, $2… insert captured groups."
        ) { call in
            let text = call.text(0)
            let regex = try FormulaRegexCache.regex(for: call.text(1))
            let result = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: call.text(2)
            )
            return .text(result)
        },
    ]
}

enum FormulaText {
    static let maximumGeneratedLength = 1_000_000

    /// encodeURIComponent leaves A–Z a–z 0–9 - _ . ! ~ * ' ( ) unescaped.
    static let urlComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    static func trim(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        result.reserveCapacity(trimmed.utf8.count)
        var previousWasSpace = false
        for character in trimmed {
            let isSpace = character == " "
            if isSpace && previousWasSpace { continue }
            previousWasSpace = isSpace
            result.append(character)
        }
        return result
    }

    /// Case folding per character keeps positions aligned with the original text.
    static func caseFolded(_ text: String) -> [String] {
        text.map { $0.lowercased() }
    }

    /// 1-based position of `needle` in `haystack` at or after the 1-based `start`.
    static func position<Element: Equatable>(of needle: [Element], in haystack: [Element], from start: Int) -> Int? {
        firstIndex(of: needle, in: haystack, from: start - 1).map { $0 + 1 }
    }

    static func firstIndex<Element: Equatable>(of needle: [Element], in haystack: [Element], from start: Int) -> Int? {
        guard start <= haystack.count else { return nil }
        guard !needle.isEmpty else { return start }
        guard needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        var index = max(start, 0)
        while index <= last {
            if haystack[index] == needle[0] {
                var offset = 1
                while offset < needle.count, haystack[index + offset] == needle[offset] {
                    offset += 1
                }
                if offset == needle.count {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    static func substitute(_ text: String, _ old: String, with replacement: String, occurrence: Int?) -> String {
        guard !old.isEmpty else { return text }
        let characters = Array(text)
        let target = Array(old)
        var result = ""
        var searchFrom = 0
        var copiedUpTo = 0
        var seen = 0
        while let found = firstIndex(of: target, in: characters, from: searchFrom) {
            seen += 1
            if occurrence == nil || occurrence == seen {
                result += String(characters[copiedUpTo..<found])
                result += replacement
                copiedUpTo = found + target.count
                if occurrence != nil { break }
            }
            searchFrom = found + target.count
        }
        result += String(characters[copiedUpTo...])
        return result
    }
}
