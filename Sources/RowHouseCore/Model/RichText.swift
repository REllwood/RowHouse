import Foundation

/// Rich text in long text fields is stored as Markdown. This reads it line by line (the way people
/// type it into a cell), turns it into plain text for the grid and exports, and applies the
/// formatting toolbar's edits.
public enum RichText {
    public enum Block: Hashable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `checked` is nil for an ordinary bullet and set for a task-list item.
        case bullet(indent: Int, text: String, checked: Bool?)
        case numbered(indent: Int, number: Int, text: String)
        case quote(String)
        case code(String)
        case rule
        case blank
    }

    public static func blocks(from markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fenceMarker(trimmed) {
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                index += 1
                continue
            }
            blocks.append(block(for: line, trimmed: trimmed))
            index += 1
        }
        return blocks
    }

    /// Plain text for grid cells, CSV export, search and copying: Markdown markup removed, list items
    /// kept on their own lines.
    public static func plainText(from markdown: String) -> String {
        guard markdown.contains(where: { markupCharacters.contains($0) }) else { return markdown }
        let lines = blocks(from: markdown).map { block -> String in
            switch block {
            case .paragraph(let text): return stripInline(text)
            case .heading(_, let text): return stripInline(text)
            case .bullet(let indent, let text, let checked):
                let marker = checked.map { $0 ? "☑ " : "☐ " } ?? "• "
                return String(repeating: "  ", count: indent) + marker + stripInline(text)
            case .numbered(let indent, let number, let text):
                return String(repeating: "  ", count: indent) + "\(number). " + stripInline(text)
            case .quote(let text): return stripInline(text)
            case .code(let text): return text
            case .rule, .blank: return ""
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let markupCharacters = Set("*_~`#[!<>-+\\|0123456789")

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func block(for line: String, trimmed: String) -> Block {
        if trimmed.isEmpty { return .blank }
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let width = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.dropFirst(leading.count)

        if width < 4, let heading = heading(in: body) { return heading }
        if isRule(trimmed) { return .rule }
        if body.hasPrefix(">") {
            var rest = Substring(trimmed)
            while rest.hasPrefix(">") {
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            }
            return .quote(String(rest))
        }
        let indent = width / 2
        if let first = body.first, first == "-" || first == "*" || first == "+" {
            let afterMarker = body.dropFirst()
            if afterMarker.isEmpty { return .bullet(indent: indent, text: "", checked: nil) }
            if afterMarker.first == " " || afterMarker.first == "\t" {
                var text = afterMarker.drop { $0 == " " || $0 == "\t" }
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text == "[ ]" {
                    checked = false
                    text = text.dropFirst(3).drop { $0 == " " }
                } else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" {
                    checked = true
                    text = text.dropFirst(3).drop { $0 == " " }
                }
                return .bullet(indent: indent, text: String(text), checked: checked)
            }
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, let number = Int(digits) {
            let afterDigits = body.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let afterDelimiter = afterDigits.dropFirst()
                if afterDelimiter.isEmpty || afterDelimiter.first == " " || afterDelimiter.first == "\t" {
                    return .numbered(indent: indent, number: number, text: String(afterDelimiter.drop { $0 == " " || $0 == "\t" }))
                }
            }
        }
        return .paragraph(line)
    }

    private static func heading(in body: Substring) -> Block? {
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence of #s, separated from the text by a space.
        if let range = text.range(of: #"(^|[ \t])#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: hashes.count, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    // MARK: - Inline markup

    /// Removes inline markup — emphasis, strikethrough, code spans, links, images and escapes —
    /// leaving the text a reader sees.
    public static func stripInline(_ text: String) -> String {
        var out = ""
        var pending = ""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex,
               text[next].isASCII, text[next].isPunctuation || text[next].isSymbol {
                pending.append(escapePlaceholder(text[next]))
                index = text.index(after: next)
                continue
            }
            if c == "`" {
                let run = text[index...].prefix { $0 == "`" }
                let contentStart = text.index(index, offsetBy: run.count)
                if let close = text[contentStart...].range(of: String(run)), text[close.upperBound...].first != "`" {
                    out += stripSpans(pending)
                    pending = ""
                    var code = String(text[contentStart..<close.lowerBound])
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" ") { code = String(code.dropFirst().dropLast()) }
                    out += code
                    index = close.upperBound
                    continue
                }
                pending += run
                index = contentStart
                continue
            }
            pending.append(c)
            index = text.index(after: index)
        }
        out += stripSpans(pending)
        return restoreEscapes(out)
    }

    private static let inlinePatterns: [(NSRegularExpression, String)] = [
        (#"!\[([^\]]*)\]\([^)\s]*(?:\s+"[^"]*")?\)"#, "$1"),
        (#"\[([^\]]+)\]\([^)\s]*(?:\s+"[^"]*")?\)"#, "$1"),
        (#"<((?:https?|mailto):[^>\s]+)>"#, "$1"),
        (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "$1"),
        (#"(?<![\p{L}\p{N}])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}])"#, "$1"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),
        (#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#, "$1"),
        (#"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func stripSpans(_ text: String) -> String {
        guard text.contains(where: { "*_~[!<".contains($0) }) else { return text }
        var current = text
        // Nested markup (***bold italic***, **_both_**) unwraps one layer per pass.
        for _ in 0..<3 {
            var next = current
            for (regex, template) in inlinePatterns {
                let range = NSRange(next.startIndex..., in: next)
                next = regex.stringByReplacingMatches(in: next, range: range, withTemplate: template)
            }
            if next == current { break }
            current = next
        }
        return current
    }

    private static func escapePlaceholder(_ c: Character) -> Character {
        let value = c.unicodeScalars.first!.value
        return Character(Unicode.Scalar(0xF0000 + value)!)
    }

    private static func restoreEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0xF0000 && $0.value < 0xF0080 }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0xF0000 && scalar.value < 0xF0080, let original = Unicode.Scalar(scalar.value - 0xF0000) {
                scalars.append(original)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

// MARK: - Formatting toolbar

public enum MarkdownFormat: String, CaseIterable, Sendable {
    case bold, italic, strikethrough, heading, bulletList, numberedList, link, code
}

/// One edit to a text: replace `range` (UTF-16, in the original text) with `replacement`, then
/// select `selection` (UTF-16, in the new text).
public struct MarkdownEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

extension RichText {
    /// The edit a formatting button makes: inline styles wrap (or unwrap) the selection, block styles
    /// toggle a prefix on every selected line.
    public static func edit(_ format: MarkdownFormat, text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let location = min(max(0, selection.location), ns.length)
        let sel = NSRange(location: location, length: min(max(0, selection.length), ns.length - location))
        switch format {
        case .bold: return wrap(ns, sel, marker: "**")
        case .italic: return wrap(ns, sel, marker: "*")
        case .strikethrough: return wrap(ns, sel, marker: "~~")
        case .code:
            if ns.substring(with: sel).contains("\n") { return fence(ns, sel) }
            return wrap(ns, sel, marker: "`")
        case .link: return link(ns, sel)
        case .heading, .bulletList, .numberedList: return prefixLines(ns, sel, format: format)
        }
    }

    private static func wrap(_ ns: NSString, _ sel: NSRange, marker: String) -> MarkdownEdit {
        let m = (marker as NSString).length
        let selected = ns.substring(with: sel)
        let single = marker == "*"
        func isMarker(at location: Int) -> Bool {
            guard location >= 0, location + m <= ns.length, ns.substring(with: NSRange(location: location, length: m)) == marker else { return false }
            guard single else { return true }
            // A lone * next to another * belongs to bold markup, not italics.
            let before = location > 0 ? ns.substring(with: NSRange(location: location - 1, length: 1)) : ""
            let after = location + 1 < ns.length ? ns.substring(with: NSRange(location: location + 1, length: 1)) : ""
            return before != "*" && after != "*"
        }
        // Already wrapped inside the selection: unwrap.
        if sel.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker),
           !single || (!selected.hasPrefix("**") && !selected.hasSuffix("**")) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return MarkdownEdit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        // Wrapped just outside the selection: unwrap.
        if isMarker(at: sel.location - m), isMarker(at: sel.location + sel.length) {
            let range = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return MarkdownEdit(range: range, replacement: selected, selection: NSRange(location: sel.location - m, length: sel.length))
        }
        if sel.length == 0 {
            return MarkdownEdit(range: sel, replacement: marker + marker, selection: NSRange(location: sel.location + m, length: 0))
        }
        // Markdown emphasis can't start or end with a space or span lines, so wrap each line's text.
        let lines = selected.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let trail = String(line.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            return lead + marker + trimmed + marker + trail
        }
        let replacement = lines.joined(separator: "\n")
        return MarkdownEdit(range: sel, replacement: replacement, selection: NSRange(location: sel.location, length: (replacement as NSString).length))
    }

    private static func fence(_ ns: NSString, _ sel: NSRange) -> MarkdownEdit {
        let lines = ns.lineRange(for: sel)
        var body = ns.substring(with: lines)
        let hadNewline = body.hasSuffix("\n")
        if hadNewline { body.removeLast() }
        let replacement = "```\n" + body + "\n```" + (hadNewline ? "\n" : "")
        let bodyLength = (body as NSString).length
        return MarkdownEdit(range: lines, replacement: replacement, selection: NSRange(location: lines.location + 4, length: bodyLength))
    }

    private static func link(_ ns: NSString, _ sel: NSRange) -> MarkdownEdit {
        let selected = ns.substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeURL = selected.range(of: #"^(https?://|mailto:|www\.)\S+$"#, options: .regularExpression) != nil
        if looksLikeURL {
            let url = selected.hasPrefix("www.") ? "https://" + selected : selected
            return MarkdownEdit(range: sel, replacement: "[](\(url))", selection: NSRange(location: sel.location + 1, length: 0))
        }
        let label = selected.isEmpty ? "link text" : selected
        let replacement = "[\(label)](https://)"
        if selected.isEmpty {
            return MarkdownEdit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + 1, length: (label as NSString).length))
        }
        let urlStart = sel.location + 1 + (label as NSString).length + 2
        return MarkdownEdit(range: sel, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
    }

    private static func prefixLines(_ ns: NSString, _ sel: NSRange, format: MarkdownFormat) -> MarkdownEdit {
        let range = ns.lineRange(for: sel)
        var content = ns.substring(with: range)
        let endsWithNewline = content.hasSuffix("\n")
        if endsWithNewline { content.removeLast() }
        let lines = content.components(separatedBy: "\n")
        let parsed = lines.map { line -> (indent: String, marker: LineMarker, text: String) in
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let (marker, text) = lineMarker(String(line.dropFirst(indent.count)))
            return (indent, marker, text)
        }
        let targets = parsed.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let consider = targets.isEmpty ? Array(parsed.indices) : targets
        let wanted: LineMarker.Kind = format == .heading ? .heading : (format == .bulletList ? .bullet : .numbered)
        let removing = consider.allSatisfy { parsed[$0].marker.kind == wanted }
        var number = 0
        var newLines = lines
        for i in consider {
            let (indent, _, text) = parsed[i]
            if removing {
                newLines[i] = indent + text
            } else {
                number += 1
                let prefix: String
                switch wanted {
                case .heading: prefix = "# "
                case .bullet: prefix = "- "
                case .numbered: prefix = "\(number). "
                case .none: prefix = ""
                }
                newLines[i] = (wanted == .heading ? "" : indent) + prefix + text
            }
        }
        let replacement = newLines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let newLength = (replacement as NSString).length - (endsWithNewline ? 1 : 0)
        if sel.length == 0, lines.count == 1 {
            let delta = (newLines[0] as NSString).length - (lines[0] as NSString).length
            let caret = max(range.location, min(range.location + newLength, sel.location + delta))
            return MarkdownEdit(range: range, replacement: replacement, selection: NSRange(location: caret, length: 0))
        }
        return MarkdownEdit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: newLength))
    }

    private struct LineMarker {
        enum Kind { case none, heading, bullet, numbered }
        var kind: Kind
    }

    private static func lineMarker(_ body: String) -> (LineMarker, String) {
        let hashes = body.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), body.dropFirst(hashes.count).first == " " {
            return (LineMarker(kind: .heading), String(body.dropFirst(hashes.count + 1)))
        }
        if let first = body.first, first == "-" || first == "*" || first == "+", body.dropFirst().first == " " {
            return (LineMarker(kind: .bullet), String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = body.dropFirst(digits.count)
            if let d = rest.first, d == "." || d == ")", rest.dropFirst().first == " " {
                return (LineMarker(kind: .numbered), String(rest.dropFirst(2)))
            }
        }
        return (LineMarker(kind: .none), body)
    }
}
