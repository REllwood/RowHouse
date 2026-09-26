import Foundation

public struct GroupHeader: Hashable, Sendable, Identifiable {
    /// Stable path key (e.g. "fldA=Done|fldB=High") used to remember collapsed groups.
    public var id: String
    public var depth: Int
    public var fieldID: String
    public var value: CellValue
    public var title: String
    public var count: Int
}

public enum ViewRow: Hashable, Sendable, Identifiable {
    case group(GroupHeader)
    case record(String)

    public var id: String {
        switch self {
        case .group(let g): "g:" + g.id
        case .record(let r): r
        }
    }

    public var recordID: String? {
        if case .record(let id) = self { return id }
        return nil
    }
}

public struct ViewResult: Sendable {
    /// Every visible record id, in display order (ignores collapsed groups).
    public var recordIDs: [String]
    /// Rows including group headers, with collapsed groups' records omitted.
    public var rows: [ViewRow]
}

extension BaseDocument {
    /// Visible fields of a view in display order (primary field always first and never hidden).
    public func visibleFields(for view: ViewModel) -> [FieldModel] {
        let all = orderedFields(for: view)
        let hidden = view.config.hidden
        let primary = primaryField(of: view.tableID)?.id
        return all.filter { $0.id == primary || !hidden.contains($0.id) }
    }

    /// All fields of a view in its column order.
    public func orderedFields(for view: ViewModel) -> [FieldModel] {
        let all = fields(in: view.tableID)
        guard let order = view.config.fieldOrder, !order.isEmpty else { return all }
        let primary = primaryField(of: view.tableID)?.id
        var position: [String: Int] = [:]
        for (i, id) in order.enumerated() { position[id] = i }
        return all.sorted { a, b in
            if a.id == primary { return b.id != primary }
            if b.id == primary { return false }
            let pa = position[a.id] ?? Int.max
            let pb = position[b.id] ?? Int.max
            if pa != pb { return pa < pb }
            return a.order < b.order
        }
    }

    /// Filters, searches, sorts and groups a view's records.
    public func evaluate(view: ViewModel, search: String = "", collapsedGroups: Set<String> = [], extraFilter: FilterGroup? = nil) -> ViewResult {
        var hasher = Hasher()
        hasher.combine(dataRevision)
        hasher.combine(schemaRevision)
        hasher.combine(view.type)
        hasher.combine(view.config)
        hasher.combine(search)
        hasher.combine(collapsedGroups)
        hasher.combine(extraFilter)
        let key = hasher.finalize()
        if let cached = evaluationCache[view.id], cached.key == key { return cached.result }
        let result = computeEvaluation(view: view, search: search, collapsedGroups: collapsedGroups, extraFilter: extraFilter)
        evaluationCache[view.id] = (key, result)
        return result
    }

    private func computeEvaluation(view: ViewModel, search: String, collapsedGroups: Set<String>, extraFilter: FilterGroup?) -> ViewResult {
        let tableFields = fields(in: view.tableID)
        var recs = records(in: view.tableID)

        if let filter = view.config.filter, !filter.isEmpty {
            recs = recs.filter { matches($0, filter: filter) }
        }
        if let extraFilter, !extraFilter.isEmpty {
            recs = recs.filter { matches($0, filter: extraFilter) }
        }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let searchFields = view.type == .grid ? visibleFields(for: view) : tableFields
            recs = recs.filter { r in
                searchFields.contains { f in displayString(r, f).localizedCaseInsensitiveContains(needle) }
            }
        }

        let groups = (view.type == .grid ? (view.config.groups ?? []) : []).filter { field($0.fieldID) != nil }
        let sorts = (view.config.sorts ?? []).filter { field($0.fieldID) != nil }
        let keys = groups + sorts
        if !keys.isEmpty {
            let resolvedFields = keys.map { field($0.fieldID)! }
            // Decorate-sort-undecorate: each value is resolved and turned into a cheap key once.
            let decorated = recs.map { r in (r, resolvedFields.map { CellComparison.sortKey(value(r, $0), field: $0) }) }
            let sorted = decorated.enumerated().sorted { lhs, rhs in
                for (i, key) in keys.enumerated() {
                    let a = lhs.element.1[i], b = rhs.element.1[i]
                    // Empty values sort last whichever direction is chosen.
                    if a.isEmpty != b.isEmpty { return b.isEmpty }
                    let c = a.compare(b)
                    if c != .orderedSame {
                        return key.ascending ? c == .orderedAscending : c == .orderedDescending
                    }
                }
                return lhs.offset < rhs.offset
            }
            recs = sorted.map(\.element.0)
        }

        let ids = recs.map(\.id)
        guard !groups.isEmpty else {
            return ViewResult(recordIDs: ids, rows: ids.map { .record($0) })
        }
        var rows: [ViewRow] = []
        buildGroups(recs[...], groups: groups[...], depth: 0, pathPrefix: "", collapsed: collapsedGroups, into: &rows)
        return ViewResult(recordIDs: ids, rows: rows)
    }

    private func buildGroups(_ recs: ArraySlice<RecordModel>, groups: ArraySlice<SortSpec>, depth: Int, pathPrefix: String, collapsed: Set<String>, into rows: inout [ViewRow]) {
        guard let spec = groups.first, let field = field(spec.fieldID) else {
            rows.append(contentsOf: recs.map { .record($0.id) })
            return
        }
        // Bucket by key in order of first appearance, so equal values always share one header even
        // when the sort placed them apart (e.g. "Apple" and "apple").
        var buckets: [String: [RecordModel]] = [:]
        var firstValue: [String: CellValue] = [:]
        var order: [String] = []
        for r in recs {
            let v = value(r, field)
            let key = CellComparison.groupKey(v)
            if buckets[key] == nil {
                order.append(key)
                firstValue[key] = v
            }
            buckets[key, default: []].append(r)
        }
        for key in order {
            let members = buckets[key] ?? []
            let v = firstValue[key] ?? .empty
            let path = pathPrefix + field.id + "=" + key + "|"
            rows.append(.group(GroupHeader(id: path, depth: depth, fieldID: field.id, value: v, title: groupTitle(v, field: field), count: members.count)))
            if !collapsed.contains(path) {
                buildGroups(members[...], groups: groups.dropFirst(), depth: depth + 1, pathPrefix: path, collapsed: collapsed, into: &rows)
            }
        }
    }

    private func groupTitle(_ v: CellValue, field: FieldModel) -> String {
        if v.isEmpty {
            return field.type == .checkbox ? "Unchecked" : "Empty"
        }
        if field.type == .checkbox { return "Checked" }
        if case .date(let d, _) = v {
            return CellFormatter.date(d, includeTime: false, format: .friendly, use24Hour: false)
        }
        return CellFormatter.string(v, field: field)
    }

    // MARK: - Filters

    /// Whether a record matches a filter. In the default lenient mode, conditions that are still
    /// being written (no value yet, or a deleted field) are ignored, like Airtable's incomplete
    /// filters. `strict` mode (used by automations) compares empty values literally instead, so an
    /// empty template can't make "Find records" match everything.
    public func matches(_ record: RecordModel, filter: FilterGroup, strict: Bool = false) -> Bool {
        evaluate(record, filter: filter, strict: strict) ?? true
    }

    private func evaluate(_ record: RecordModel, filter: FilterGroup, strict: Bool) -> Bool? {
        var results: [Bool] = []
        for c in filter.conditions {
            if let r = evaluate(record, condition: c, strict: strict) { results.append(r) }
        }
        for g in filter.groups {
            if let r = evaluate(record, filter: g, strict: strict) { results.append(r) }
        }
        guard !results.isEmpty else { return nil }
        switch filter.conjunction {
        case .and: return results.allSatisfy { $0 }
        case .or: return results.contains(true)
        }
    }

    /// The colour a view gives a record: the first matching colour rule, otherwise the colour of
    /// its single select value when the view colours by a field. Rules with no complete condition never match.
    public func recordColor(_ record: RecordModel, view: ViewModel) -> ChoiceColor? {
        if let rules = view.config.colorRules, !rules.isEmpty {
            return rules.first { evaluate(record, filter: $0.filter, strict: false) == true }?.color
        }
        guard let f = field(view.config.colorFieldID), f.tableID == record.tableID, case .choice(let c) = value(record, f) else { return nil }
        return c.color
    }

    public func matches(_ record: RecordModel, condition: FilterCondition) -> Bool {
        evaluate(record, condition: condition, strict: false) ?? true
    }

    private func evaluate(_ record: RecordModel, condition: FilterCondition, strict: Bool) -> Bool? {
        guard let field = field(condition.fieldID) else { return strict ? false : nil }
        var condition = condition
        if condition.op.needsValue && field.type != .checkbox, condition.value?.isEmptyCell ?? true {
            guard strict else { return nil }
            condition.value = .string("")
            // "is" an empty value means the cell is empty; other comparisons against nothing fail.
            switch condition.op {
            case .is: return value(record, field).isEmpty
            case .isNot: return !value(record, field).isEmpty
            default: return false
            }
        }
        return FilterEvaluator.evaluate(condition, value: value(record, field), field: field, document: self)
    }

    // MARK: - Summaries

    public func summary(_ function: SummaryFunction, field: FieldModel, recordIDs: [String]) -> String {
        guard function != .none else { return "" }
        let values = recordIDs.compactMap { record($0) }.map { value($0, field) }
        let total = values.count
        let filled = values.filter { !$0.isEmpty }
        func pct(_ n: Int) -> String {
            total == 0 ? "0%" : CellFormatter.number(Double(n) / Double(total) * 100, precision: 0) + "%"
        }
        let numbers = values.compactMap { v -> Double? in
            if case .list(let items) = v { return items.compactMap(\.numberValue).reduce(0, +) }
            return v.numberValue
        }
        func fmt(_ n: Double) -> String {
            CellFormatter.string(.number(n), field: field)
        }
        let dates = values.compactMap(\.dateValue)
        switch function {
        case .none: return ""
        case .filled: return "\(filled.count) filled"
        case .empty: return "\(total - filled.count) empty"
        case .percentFilled: return pct(filled.count) + " filled"
        case .percentEmpty: return pct(total - filled.count) + " empty"
        case .unique: return "\(Set(filled.map { CellFormatter.string($0, field: field) }).count) unique"
        case .sum: return "Sum " + fmt(numbers.reduce(0, +))
        case .average: return numbers.isEmpty ? "Avg –" : "Avg " + fmt(numbers.reduce(0, +) / Double(numbers.count))
        case .median:
            guard !numbers.isEmpty else { return "Median –" }
            let s = numbers.sorted()
            let mid = s.count / 2
            return "Median " + fmt(s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid])
        case .min: return numbers.min().map { "Min " + fmt($0) } ?? "Min –"
        case .max: return numbers.max().map { "Max " + fmt($0) } ?? "Max –"
        case .range:
            if !dates.isEmpty, let lo = dates.min(), let hi = dates.max() {
                let days = Int((hi.timeIntervalSince(lo) / 86400).rounded())
                return "Range \(days) days"
            }
            guard let lo = numbers.min(), let hi = numbers.max() else { return "Range –" }
            return "Range " + fmt(hi - lo)
        case .checked: return "\(values.filter { if case .bool(true) = $0 { return true } else { return false } }.count) checked"
        case .unchecked: return "\(values.filter { if case .bool(true) = $0 { return false } else { return true } }.count) unchecked"
        case .earliest: return dates.min().map { "Earliest " + CellFormatter.date($0, includeTime: false, format: .friendly, use24Hour: false) } ?? "Earliest –"
        case .latest: return dates.max().map { "Latest " + CellFormatter.date($0, includeTime: false, format: .friendly, use24Hour: false) } ?? "Latest –"
        }
    }
}

/// A precomputed, cheaply comparable form of a cell value.
public enum SortKey: Sendable {
    case empty
    case number(Double)
    case text(String)

    var isEmpty: Bool { if case .empty = self { return true } else { return false } }

    func compare(_ other: SortKey) -> ComparisonResult {
        switch (self, other) {
        case (.number(let x), .number(let y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.text(let x), .text(let y)):
            return x.compare(y, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
        case (.number, .text): return .orderedAscending
        case (.text, .number): return .orderedDescending
        default: return .orderedSame
        }
    }
}

public enum CellComparison {
    public static func sortKey(_ v: CellValue, field: FieldModel) -> SortKey {
        if v.isEmpty && field.type != .checkbox { return .empty }
        switch v {
        case .number(let n): return .number(n)
        case .bool(let b): return .number(b ? 1 : 0)
        case .date(let d, _): return .number(d.timeIntervalSinceReferenceDate)
        case .choice(let c):
            return .number(Double(field.choices.firstIndex { $0.id == c.id } ?? Int.max))
        case .list(let items) where items.count == 1 && items[0].isNumericLike:
            return .number(items[0].numberValue ?? 0)
        case .empty:
            return .number(0)
        default:
            return .text(CellFormatter.string(v, field: field))
        }
    }

    /// Type-aware comparison; empty values always sort last.
    public static func compare(_ a: CellValue, _ b: CellValue, field: FieldModel) -> ComparisonResult {
        let ae = a.isEmpty && !(field.type == .checkbox)
        let be = b.isEmpty && !(field.type == .checkbox)
        if ae && be { return .orderedSame }
        if ae { return .orderedDescending }
        if be { return .orderedAscending }
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.bool(let x), .bool(let y)):
            return x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
        case (.date(let x, _), .date(let y, _)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.choice(let x), .choice(let y)):
            let order = field.choices.map(\.id)
            let ix = order.firstIndex(of: x.id) ?? Int.max
            let iy = order.firstIndex(of: y.id) ?? Int.max
            return ix < iy ? .orderedAscending : (ix > iy ? .orderedDescending : .orderedSame)
        default:
            if let x = a.numberValue, let y = b.numberValue, a.isNumericLike, b.isNumericLike {
                return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            }
            let sa = CellFormatter.string(a, field: field)
            let sb = CellFormatter.string(b, field: field)
            return sa.localizedStandardCompare(sb)
        }
    }

    /// Grouping key: equal values produce equal keys.
    public static func groupKey(_ v: CellValue) -> String {
        switch v {
        case .empty: return ""
        case .text(let s): return "t:" + s
        case .number(let n): return "n:\(n)"
        case .bool(let b): return b ? "b:1" : ""
        case .date(let d, _):
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return "d:\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        case .choice(let c): return "c:" + c.id
        case .choices(let cs): return cs.isEmpty ? "" : "cs:" + cs.map(\.id).joined(separator: ",")
        case .attachments(let a): return a.isEmpty ? "" : "a:" + a.map(\.id).joined(separator: ",")
        case .links(let l): return l.isEmpty ? "" : "l:" + l.map(\.id).joined(separator: ",")
        case .collaborators(let p): return p.isEmpty ? "" : "p:" + p.map(\.id).joined(separator: ",")
        case .list(let items): return items.isEmpty ? "" : "L:" + items.map(groupKey).joined(separator: ",")
        case .error(let m): return "e:" + m
        }
    }
}

extension CellValue {
    var isNumericLike: Bool {
        switch self {
        case .number: return true
        case .list(let items): return items.count == 1 && items[0].isNumericLike
        default: return false
        }
    }
}

enum FilterEvaluator {
    @MainActor
    static func evaluate(_ c: FilterCondition, value: CellValue, field: FieldModel, document: BaseDocument) -> Bool {
        switch c.op {
        case .isEmpty: return value.isEmpty
        case .isNotEmpty: return !value.isEmpty
        default: break
        }
        if field.type == .checkbox {
            let want = c.value?.boolValue ?? true
            let has: Bool = { if case .bool(true) = value { return true } else { return false } }()
            return has == want
        }
        switch field.type {
        case .singleSelect:
            let wanted = Set(c.value?.stringArray ?? (c.value?.stringValue.map { [$0] } ?? []))
            let current: String? = { if case .choice(let ch) = value { return ch.id } else { return nil } }()
            switch c.op {
            case .is, .isAnyOf: return current.map { wanted.contains($0) } ?? false
            case .isNot, .isNoneOf: return current.map { !wanted.contains($0) } ?? true
            default: return textCompare(c, value: value, field: field)
            }
        case .multipleSelects:
            let wanted = Set(c.value?.stringArray ?? (c.value?.stringValue.map { [$0] } ?? []))
            let current: Set<String> = { if case .choices(let cs) = value { return Set(cs.map(\.id)) } else { return [] } }()
            switch c.op {
            case .hasAnyOf: return !current.isDisjoint(with: wanted)
            case .hasAllOf: return wanted.isSubset(of: current)
            case .hasNoneOf: return current.isDisjoint(with: wanted)
            case .isExactly: return current == wanted
            default: return textCompare(c, value: value, field: field)
            }
        case .collaborator:
            return peopleCompare(c, value: value, field: field, document: document)
        case .date, .createdTime, .lastModifiedTime:
            return dateCompare(c, value: value)
        case .number, .currency, .percent, .duration, .rating, .count, .autoNumber:
            return numberCompare(c, value: value, field: field)
        case .formula, .rollup:
            if value.dateValue != nil, c.value?["mode"] != nil { return dateCompare(c, value: value) }
            if value.isNumericLike, [.is, .isNot, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual].contains(c.op),
               c.value?.numberValue != nil || c.value?.stringValue.flatMap(Double.init) != nil {
                return numberCompare(c, value: value, field: field)
            }
            return textCompare(c, value: value, field: field)
        default:
            return textCompare(c, value: value, field: field)
        }
    }

    /// Compares the people in a cell with the people named by the condition (ids, or names and
    /// emails written by automations and scripts).
    @MainActor
    private static func peopleCompare(_ c: FilterCondition, value: CellValue, field: FieldModel, document: BaseDocument) -> Bool {
        let wanted = Set((c.value?.collaboratorIDs ?? []).compactMap { key -> String? in
            if key == Person.meToken { return document.currentPersonID ?? key }
            return document.person(matching: key)?.id ?? key
        })
        let current: Set<String> = { if case .collaborators(let people) = value { return Set(people.map(\.id)) } else { return [] } }()
        switch c.op {
        case .is, .isExactly: return current == wanted
        case .isNot: return current != wanted
        case .isAnyOf, .hasAnyOf: return !current.isDisjoint(with: wanted)
        case .isNoneOf, .hasNoneOf: return current.isDisjoint(with: wanted)
        case .hasAllOf: return wanted.isSubset(of: current)
        default: return textCompare(c, value: value, field: field)
        }
    }

    private static func textCompare(_ c: FilterCondition, value: CellValue, field: FieldModel) -> Bool {
        let hay = CellFormatter.string(value, field: field)
        let needle = c.value?.stringValue ?? c.value?.numberValue.map { CellFormatter.number($0, precision: nil) } ?? ""
        switch c.op {
        case .contains: return hay.localizedCaseInsensitiveContains(needle)
        case .doesNotContain: return !hay.localizedCaseInsensitiveContains(needle)
        case .is: return hay.caseInsensitiveCompare(needle) == .orderedSame
        case .isNot: return hay.caseInsensitiveCompare(needle) != .orderedSame
        case .startsWith: return hay.lowercased().hasPrefix(needle.lowercased())
        case .endsWith: return hay.lowercased().hasSuffix(needle.lowercased())
        case .lessThan: return hay.localizedStandardCompare(needle) == .orderedAscending
        case .greaterThan: return hay.localizedStandardCompare(needle) == .orderedDescending
        case .lessThanOrEqual: return hay.localizedStandardCompare(needle) != .orderedDescending
        case .greaterThanOrEqual: return hay.localizedStandardCompare(needle) != .orderedAscending
        default: return true
        }
    }

    private static func numberCompare(_ c: FilterCondition, value: CellValue, field: FieldModel) -> Bool {
        guard var target = c.value?.numberValue ?? c.value?.stringValue.flatMap({ ValueParsing.number(from: $0) }) else { return true }
        if field.type == .percent { target /= 100 }
        let n: Double
        if case .list(let items) = value {
            n = items.compactMap(\.numberValue).reduce(0, +)
        } else {
            guard let v = value.numberValue else { return c.op == .isNot }
            n = v
        }
        let eps = 1e-9
        switch c.op {
        case .is: return abs(n - target) < eps
        case .isNot: return abs(n - target) >= eps
        case .lessThan: return n < target
        case .lessThanOrEqual: return n <= target + eps
        case .greaterThan: return n > target
        case .greaterThanOrEqual: return n >= target - eps
        default: return true
        }
    }

    static func dateCompare(_ c: FilterCondition, value: CellValue, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date = value.dateValue else { return c.op == .isNot }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if c.op == .isWithin {
            let mode = c.value?["mode"]?.stringValue.flatMap(WithinMode.init(rawValue:)) ?? .pastWeek
            let rawDays = c.value?["days"]?.numberValue ?? 7
            let days = rawDays.isFinite ? Int(min(max(rawDays, 0), 36_500)) : 7
            let range: ClosedRange<Date>
            func add(_ comp: Calendar.Component, _ n: Int) -> Date { calendar.date(byAdding: comp, value: n, to: today) ?? today }
            func span(_ a: Date, _ b: Date) -> ClosedRange<Date> { min(a, b)...max(a, b) }
            switch mode {
            case .pastWeek: range = add(.day, -7)...today
            case .pastMonth: range = add(.month, -1)...today
            case .pastYear: range = add(.year, -1)...today
            case .nextWeek: range = today...add(.day, 7)
            case .nextMonth: range = today...add(.month, 1)
            case .nextYear: range = today...add(.year, 1)
            case .pastNumberOfDays: range = span(add(.day, -days), today)
            case .nextNumberOfDays: range = span(today, add(.day, days))
            }
            return range.contains(day)
        }
        guard let target = resolveRelativeDate(c.value, now: now, calendar: calendar) else { return true }
        switch c.op {
        case .is: return day == target
        case .isNot: return day != target
        case .isBefore: return day < target
        case .isAfter: return day > target
        case .isOnOrBefore: return day <= target
        case .isOnOrAfter: return day >= target
        default: return true
        }
    }

    static func resolveRelativeDate(_ value: JSONValue?, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let value else { return nil }
        if let s = value.stringValue { return DateCoding.decode(s).map { calendar.startOfDay(for: $0) } }
        let mode = value["mode"]?.stringValue.flatMap(RelativeDateMode.init(rawValue:)) ?? .exactDate
        let rawDays = value["days"]?.numberValue ?? 0
        let days = rawDays.isFinite ? Int(min(max(rawDays, -36_500), 36_500)) : 0
        func add(_ comp: Calendar.Component, _ n: Int) -> Date { calendar.date(byAdding: comp, value: n, to: today) ?? today }
        switch mode {
        case .today: return today
        case .tomorrow: return add(.day, 1)
        case .yesterday: return add(.day, -1)
        case .oneWeekAgo: return add(.day, -7)
        case .oneWeekFromNow: return add(.day, 7)
        case .oneMonthAgo: return add(.month, -1)
        case .oneMonthFromNow: return add(.month, 1)
        case .daysAgo: return add(.day, -days)
        case .daysFromNow: return add(.day, days)
        case .exactDate:
            guard let s = value["date"]?.stringValue, let d = DateCoding.decode(s) else { return nil }
            return calendar.startOfDay(for: d)
        }
    }
}
