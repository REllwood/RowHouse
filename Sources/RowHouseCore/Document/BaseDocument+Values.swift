import Foundation
import RowHouseFormula

public enum ValueParsing {
    public static let truthyStrings: Set<String> = ["true", "yes", "y", "1", "x", "checked", "✓", "✔", "✔︎", "on", "done"]

    /// Parses numbers typed or pasted by people: "1,234.5", "1.234,5" (either convention), "(12)",
    /// "$1,200", "12 500". A lone separator is read using the locale when it's ambiguous.
    public static func number(from text: String, locale: Locale = .current) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("-") || s.hasPrefix("−") {
            negative.toggle()
            s = String(s.dropFirst())
        }
        let allowed = Set("0123456789.,eE+-")
        var cleaned = String(s.filter { allowed.contains($0) })
        guard cleaned.contains(where: \.isNumber) else { return nil }
        let dots = cleaned.filter { $0 == "." }.count
        let commas = cleaned.filter { $0 == "," }.count
        let localeDecimal = locale.decimalSeparator ?? "."
        func digitsAfterLast(_ c: Character) -> Int {
            guard let i = cleaned.lastIndex(of: c) else { return 0 }
            return cleaned[cleaned.index(after: i)...].prefix { $0.isNumber }.count
        }
        let decimal: Character?
        if dots > 0 && commas > 0 {
            decimal = cleaned.lastIndex(of: ".")! > cleaned.lastIndex(of: ",")! ? "." : ","
        } else if commas > 0 {
            decimal = commas == 1 && (localeDecimal == "," || digitsAfterLast(",") != 3) ? "," : nil
        } else if dots > 0 {
            decimal = dots == 1 && (localeDecimal != "," || digitsAfterLast(".") != 3) ? "." : nil
        } else {
            decimal = nil
        }
        cleaned = String(cleaned.compactMap { ch -> Character? in
            if ch == "." || ch == "," { return ch == decimal ? "." : nil }
            return ch
        })
        guard var n = Double(cleaned), n.isFinite else { return nil }
        if negative { n = -n }
        return n
    }

    /// Locale-independent text for editing or templating a number: no grouping, "." decimals.
    public static func editableNumber(_ n: Double) -> String {
        guard n.isFinite else { return "" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.8f", n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Parses "1:30", "1:30:15", "90" (minutes), "1.5h", "45m" into seconds.
    public static func duration(from text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Double($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let p = parts.map { $0! }
            switch p.count {
            case 2: return p[0] * 3600 + p[1] * 60
            case 3: return p[0] * 3600 + p[1] * 60 + p[2]
            default: return nil
            }
        }
        if s.hasSuffix("h"), let n = Double(s.dropLast()) { return n * 3600 }
        if s.hasSuffix("m"), let n = Double(s.dropLast()) { return n * 60 }
        if s.hasSuffix("s"), let n = Double(s.dropLast()) { return n }
        if let n = Double(s) { return n * 60 }
        return nil
    }
}

extension BaseDocument {
    /// Converts text (typed, pasted, imported or produced by an automation template) into the stored
    /// representation for a field. Returns `.null` for empty input.
    public func parseValue(_ text: String, for field: FieldModel, createMissingChoices: Bool) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.type {
        case .singleLineText:
            let single = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            return single.isEmpty ? .null : .string(single)
        case .multilineText:
            return text.isEmpty ? .null : .string(text)
        case .email, .url, .phoneNumber:
            return trimmed.isEmpty ? .null : .string(trimmed)
        case .number, .currency:
            return ValueParsing.number(from: trimmed).map(JSONValue.number) ?? .null
        case .percent:
            guard let n = ValueParsing.number(from: trimmed) else { return .null }
            return .number(n / 100)
        case .duration:
            return ValueParsing.duration(from: trimmed).map(JSONValue.number) ?? .null
        case .rating:
            let stars = trimmed.filter { $0 == "★" || $0 == "⭐" }.count
            let n = stars > 0 ? Double(stars) : (ValueParsing.number(from: trimmed) ?? 0)
            let clamped = min(max(0, n.rounded()), Double(field.options.ratingMax ?? 5))
            return clamped == 0 ? .null : .number(clamped)
        case .checkbox:
            return .bool(ValueParsing.truthyStrings.contains(trimmed.lowercased()))
        case .singleSelect:
            guard !trimmed.isEmpty else { return .null }
            if let c = field.choice(named: trimmed) { return .string(c.id) }
            if createMissingChoices, let c = addChoice(named: trimmed, to: field.id) { return .string(c.id) }
            return .null
        case .multipleSelects:
            // An option whose name contains a comma still matches when it's the whole value.
            if let whole = field.choice(named: trimmed) { return .array([.string(whole.id)]) }
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var ids: [String] = []
            for name in names {
                let current = self.field(field.id) ?? field
                if let c = current.choice(named: name) {
                    ids.append(c.id)
                } else if createMissingChoices, let c = addChoice(named: name, to: field.id) {
                    ids.append(c.id)
                }
            }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case .date:
            guard let d = DateCoding.parseUserInput(trimmed) else { return .null }
            return .string(DateCoding.encode(d, includeTime: field.includesTime))
        case .link:
            // Text only ever links existing records (by id or primary value); it never creates them,
            // so pasted text or automation templates can't flood a table with stray records.
            guard let tableID = field.options.linkedTableID, !trimmed.isEmpty else { return .null }
            var ids: [String] = []
            if let whole = findRecord(titled: trimmed, in: tableID) {
                ids = [whole]
            } else {
                for token in trimmed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                    if let r = record(token), r.tableID == tableID {
                        ids.append(token)
                    } else if let existing = findRecord(titled: token, in: tableID) {
                        ids.append(existing)
                    }
                }
            }
            if field.options.singleRecordLink == true, let first = ids.first { ids = [first] }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case .attachment, .lookup, .rollup, .count, .formula, .createdTime, .lastModifiedTime, .autoNumber, .button:
            return .null
        }
    }

    public func findRecord(titled title: String, in tableID: String) -> String? {
        compute.recordID(titled: title, in: tableID)
    }

    /// Stored JSON for a resolved value when writing it into `field` (used by type conversion and automations).
    func storedValue(for value: CellValue, text: String, in field: FieldModel, options: FieldOptions) -> JSONValue {
        switch field.type {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber:
            return text.isEmpty ? .null : .string(text)
        case .number, .currency, .duration:
            if let n = value.numberValue { return .number(n) }
            return field.type == .duration
                ? (ValueParsing.duration(from: text).map(JSONValue.number) ?? .null)
                : (ValueParsing.number(from: text).map(JSONValue.number) ?? .null)
        case .percent:
            if case .number(let n) = value { return .number(n) }
            return ValueParsing.number(from: text).map { .number($0 / 100) } ?? .null
        case .rating:
            guard let n = value.numberValue ?? ValueParsing.number(from: text) else { return .null }
            let clamped = min(max(0, n.rounded()), Double(options.ratingMax ?? 5))
            return clamped == 0 ? .null : .number(clamped)
        case .checkbox:
            if case .bool(let b) = value { return .bool(b) }
            if let n = value.numberValue { return .bool(n != 0) }
            return .bool(ValueParsing.truthyStrings.contains(text.lowercased()))
        case .date:
            if let d = value.dateValue { return .string(DateCoding.encode(d, includeTime: options.includeTime ?? false)) }
            guard let d = DateCoding.parseUserInput(text) else { return .null }
            return .string(DateCoding.encode(d, includeTime: options.includeTime ?? false))
        case .singleSelect:
            let name: String
            switch value {
            case .choice(let c): name = c.name
            case .choices(let cs): name = cs.first?.name ?? ""
            default: name = text.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            }
            guard let c = options.choices?.first(where: { $0.name == name }) ?? options.choices?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return .null }
            return .string(c.id)
        case .multipleSelects:
            let names: [String]
            switch value {
            case .choice(let c): names = [c.name]
            case .choices(let cs): names = cs.map(\.name)
            default: names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            let ids = names.compactMap { n in options.choices?.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.id }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case .link:
            guard let tableID = options.linkedTableID else { return .null }
            if case .links(let refs) = value {
                let ids = refs.map(\.id).filter { record($0)?.tableID == tableID }
                return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
            }
            let titles = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let ids = titles.compactMap { findRecord(titled: $0, in: tableID) }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case .attachment:
            if case .attachments(let atts) = value { return JSONValue(encoding: atts) }
            return .null
        case .lookup, .rollup, .count, .formula, .createdTime, .lastModifiedTime, .autoNumber, .button:
            return .null
        }
    }

    /// Builds record mutations that convert every cell of `field` into `newType`. New select options
    /// needed by the converted values are added to `options`.
    func convertValues(of field: FieldModel, to newType: FieldType, options: inout FieldOptions) -> [Mutation] {
        guard !newType.isComputed else { return [] }
        let recs = records(in: field.tableID)
        var resolved: [(RecordModel, CellValue, String)] = []
        resolved.reserveCapacity(recs.count)
        for r in recs {
            let v = value(r, field)
            resolved.append((r, v, displayString(r, field)))
        }
        if newType == .singleSelect || newType == .multipleSelects {
            var choices = options.choices ?? []
            var seen = Set(choices.map { $0.name.lowercased() })
            for (_, v, text) in resolved {
                let names: [String]
                switch v {
                case .choice(let c): names = [c.name]
                case .choices(let cs): names = cs.map(\.name)
                case .empty: names = []
                default:
                    names = newType == .multipleSelects
                        ? text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        : [text.trimmingCharacters(in: .whitespacesAndNewlines)]
                }
                for n in names where !n.isEmpty && !seen.contains(n.lowercased()) {
                    seen.insert(n.lowercased())
                    let existing = field.choices.first { $0.name == n }
                    choices.append(existing ?? SelectChoice(name: n, color: .cycling(choices.count)))
                }
            }
            options.choices = choices
        }
        var target = field
        target.type = newType
        target.options = options
        var mutations: [Mutation] = []
        for (r, v, text) in resolved {
            let stored = storedValue(for: v, text: text, in: target, options: options)
            if stored != r[field.id] {
                mutations.append(Mutation(.record, r.id, [field.id: stored]))
            }
        }
        return mutations
    }

    // MARK: - Formula source conversion

    /// Rewrites `{Field Name}` references to `{fldID}` so formulas survive field renames.
    public func formulaWithFieldIDs(_ source: String, tableID: String, variables: Set<String> = []) -> String {
        FormulaSource.rewriteFieldReferences(in: source, variables: variables) { ref in
            if let f = self.field(ref), f.tableID == tableID { return f.id }
            return self.field(named: ref, in: tableID)?.id
        }
    }

    /// Rewrites `{fldID}` references to `{Field Name}` for display in the formula editor.
    public func formulaWithFieldNames(_ source: String, tableID: String, variables: Set<String> = []) -> String {
        FormulaSource.rewriteFieldReferences(in: source, variables: variables) { ref in
            if let f = self.field(ref), f.tableID == tableID { return f.name }
            return nil
        }
    }
}
