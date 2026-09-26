import Foundation

// MARK: - List outline

/// One row of a list view: a group header or a record, possibly nested under a parent record.
public struct ListOutlineRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case group(GroupHeader)
        case record(String)
    }

    /// Unique within the outline: a record nested under two parents appears twice with different ids.
    public var id: String
    public var kind: Kind
    /// Nesting below a top-level record (0 for group headers and top-level records).
    public var level: Int
    /// Group levels this row sits inside (a group header's own depth for headers).
    public var groupDepth: Int
    /// Records nested directly under this one (records in a group header).
    public var childCount: Int
    public var isExpanded: Bool
    public var parentRecordID: String?

    public var hasChildren: Bool { childCount > 0 }

    public var recordID: String? {
        if case .record(let id) = kind { return id }
        return nil
    }
}

/// Which outline rows are open. Every row starts open or closed; `toggled` flips individual rows.
public struct ListExpansion: Hashable, Sendable {
    public var expandedByDefault: Bool
    public var toggled: Set<String>

    public init(expandedByDefault: Bool = false, toggled: Set<String> = []) {
        self.expandedByDefault = expandedByDefault
        self.toggled = toggled
    }

    public func isExpanded(_ rowID: String) -> Bool {
        expandedByDefault != toggled.contains(rowID)
    }

    public mutating func toggle(_ rowID: String) {
        if toggled.contains(rowID) { toggled.remove(rowID) } else { toggled.insert(rowID) }
    }

    public mutating func setAll(expanded: Bool) {
        expandedByDefault = expanded
        toggled = []
    }
}

public enum ListOutline {
    /// Levels of records shown (a top-level record plus four levels of nested children).
    public static let maxLevels = 5
}

extension BaseDocument {
    /// The rows of a list view. Records nest their linked records (through the view's child link
    /// field) when expanded. With a self-link, records that another visible record links to appear
    /// only under that record, children are limited to records in the view, and cycles are cut.
    public func listOutline(view: ViewModel, search: String = "", collapsedGroups: Set<String> = [], expansion: ListExpansion = ListExpansion()) -> [ListOutlineRow] {
        let result = evaluate(view: view, search: search)
        let childField = field(view.config.listChildLinkFieldID).flatMap { f in
            f.type == .link && f.tableID == view.tableID && f.options.linkedTableID != nil ? f : nil
        }
        let selfLink = childField?.options.linkedTableID == view.tableID
        let inView = Set(result.recordIDs)
        var childCache: [String: [String]] = [:]

        func children(of id: String) -> [String] {
            if let cached = childCache[id] { return cached }
            guard let childField, let r = record(id), r.tableID == view.tableID else { return [] }
            var seen = Set<String>()
            let ids = compute.linkedRecordIDs(record: r, field: childField).filter { child in
                child != id && (!selfLink || inView.contains(child)) && seen.insert(child).inserted
            }
            childCache[id] = ids
            return ids
        }

        var roots = inView
        if selfLink {
            var referenced = Set<String>()
            for id in result.recordIDs { referenced.formUnion(children(of: id)) }
            var reached = Set<String>()
            func reach(_ start: String) {
                var stack = [start]
                while let next = stack.popLast() {
                    guard reached.insert(next).inserted else { continue }
                    stack.append(contentsOf: children(of: next))
                }
            }
            roots = []
            for id in result.recordIDs where !referenced.contains(id) {
                roots.insert(id)
                reach(id)
            }
            // Records reachable only through a cycle: the first one (in view order) becomes a root.
            for id in result.recordIDs where !reached.contains(id) {
                roots.insert(id)
                reach(id)
            }
        }

        // Group counts only include top-level records; groups left empty are dropped.
        let rows = result.rows
        var counts = [Int](repeating: 0, count: rows.count)
        var open: [(index: Int, depth: Int)] = []
        for (i, row) in rows.enumerated() {
            switch row {
            case .group(let g):
                while let last = open.last, last.depth >= g.depth { open.removeLast() }
                open.append((i, g.depth))
            case .record(let id):
                if roots.contains(id) { for h in open { counts[h.index] += 1 } }
            }
        }

        var out: [ListOutlineRow] = []
        func emit(_ id: String, level: Int, groupDepth: Int, parentRowID: String?, parentRecordID: String?, ancestors: Set<String>) {
            let rowID = parentRowID.map { $0 + "/" + id } ?? id
            let kids = level + 1 < ListOutline.maxLevels ? children(of: id).filter { !ancestors.contains($0) } : []
            let expanded = !kids.isEmpty && expansion.isExpanded(rowID)
            out.append(ListOutlineRow(id: rowID, kind: .record(id), level: level, groupDepth: groupDepth, childCount: kids.count, isExpanded: expanded, parentRecordID: parentRecordID))
            guard expanded else { return }
            for kid in kids {
                emit(kid, level: level + 1, groupDepth: groupDepth, parentRowID: rowID, parentRecordID: id, ancestors: ancestors.union([kid]))
            }
        }

        var skipBelowDepth: Int?
        var currentGroupDepth = 0
        for (i, row) in rows.enumerated() {
            switch row {
            case .group(var g):
                if let skip = skipBelowDepth {
                    if g.depth > skip { continue }
                    skipBelowDepth = nil
                }
                g.count = counts[i]
                guard g.count > 0 else {
                    skipBelowDepth = g.depth
                    continue
                }
                currentGroupDepth = g.depth + 1
                let collapsed = collapsedGroups.contains(g.id)
                out.append(ListOutlineRow(id: "g:" + g.id, kind: .group(g), level: 0, groupDepth: g.depth, childCount: g.count, isExpanded: !collapsed, parentRecordID: nil))
                if collapsed { skipBelowDepth = g.depth }
            case .record(let id):
                guard skipBelowDepth == nil, roots.contains(id) else { continue }
                emit(id, level: 0, groupDepth: currentGroupDepth, parentRowID: nil, parentRecordID: nil, ancestors: [id])
            }
        }
        return out
    }

    /// Creates a record linked from `parentID` through `linkFieldID` (in the link's target table)
    /// and returns its id.
    @discardableResult
    public func createChildRecord(parentID: String, linkFieldID: String, values: [String: JSONValue] = [:]) -> String? {
        guard let parent = record(parentID), let link = field(linkFieldID), link.type == .link,
              link.tableID == parent.tableID, let target = link.options.linkedTableID, table(target) != nil else { return nil }
        let singleOwner: Bool = {
            if link.isInverseLink { return false }
            return link.options.singleRecordLink == true
        }()
        var childID: String?
        batch("Add Child Record") {
            let existing = compute.linkedRecordIDs(record: parent, field: link)
            let id = createRecord(in: target, values: values)
            let ids = singleOwner ? [id] : existing + [id]
            updateRecord(parentID, values: [linkFieldID: .array(ids.map(JSONValue.string))], actionName: "Add Child Record")
            childID = id
        }
        return childID
    }
}

// MARK: - Timeline and Gantt

/// A record's bar on a timeline, at day granularity.
public struct TimelineSpan: Hashable, Sendable {
    /// Start of the first day.
    public var start: Date
    /// Start of the last day (inclusive).
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Days covered, counting both ends.
    public func dayCount(calendar: Calendar = .current) -> Int {
        (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}

/// An arrow from the end of a prerequisite's bar to the start of the record that depends on it.
public struct GanttDependency: Hashable, Sendable {
    public var prerequisiteID: String
    public var dependentID: String
    /// The dependent record starts before its prerequisite has finished.
    public var isViolated: Bool

    public init(prerequisiteID: String, dependentID: String, isViolated: Bool) {
        self.prerequisiteID = prerequisiteID
        self.dependentID = dependentID
        self.isViolated = isViolated
    }
}

public enum GanttLayout {
    /// Dependencies between scheduled records, in `recordIDs` order. Only records with a span get
    /// arrows; self-references and duplicates are ignored.
    public static func dependencies(recordIDs: [String], prerequisites: (String) -> [String], spans: [String: TimelineSpan]) -> [GanttDependency] {
        var out: [GanttDependency] = []
        var seen = Set<String>()
        for id in recordIDs {
            guard let span = spans[id] else { continue }
            for pre in prerequisites(id) where pre != id {
                guard let preSpan = spans[pre], seen.insert(pre + ">" + id).inserted else { continue }
                // Bars cover whole days, so starting on the prerequisite's last day already overlaps it.
                out.append(GanttDependency(prerequisiteID: pre, dependentID: id, isViolated: span.start <= preSpan.end))
            }
        }
        return out
    }
}

extension BaseDocument {
    /// Day spans for records with a start date. A missing end, or one before the start, makes a
    /// one-day bar.
    public func timelineSpans(recordIDs: [String], startField: FieldModel, endField: FieldModel?, calendar: Calendar = .current) -> [String: TimelineSpan] {
        var spans: [String: TimelineSpan] = [:]
        spans.reserveCapacity(recordIDs.count)
        for id in recordIDs {
            guard let r = record(id), let s = value(r, startField).dateValue else { continue }
            let start = calendar.startOfDay(for: s)
            var end = endField.flatMap { value(r, $0).dateValue }.map { calendar.startOfDay(for: $0) } ?? start
            if end < start { end = start }
            spans[id] = TimelineSpan(start: start, end: end)
        }
        return spans
    }

    /// Dependency arrows for a Gantt view whose `dependencyField` lists each record's prerequisites.
    public func ganttDependencies(recordIDs: [String], dependencyField: FieldModel, spans: [String: TimelineSpan]) -> [GanttDependency] {
        guard dependencyField.type == .link else { return [] }
        return GanttLayout.dependencies(recordIDs: recordIDs, prerequisites: { id in
            guard let r = record(id) else { return [] }
            return compute.linkedRecordIDs(record: r, field: dependencyField)
        }, spans: spans)
    }

    /// The cell writes that move a record's dates by `moveDays` and stretch its end by
    /// `resizeDays`, in whole days. Date-time values keep their time of day (even across daylight
    /// saving changes). The end never moves before the start. Empty when nothing would change.
    public func scheduleUpdate(recordID: String, startField: FieldModel, endField: FieldModel?, moveDays: Int, resizeDays: Int = 0, calendar: Calendar = .current) -> [String: JSONValue] {
        guard let r = record(recordID), startField.type == .date, let start = value(r, startField).dateValue else { return [:] }
        let editableEnd = endField.flatMap { $0.type == .date && $0.id != startField.id ? $0 : nil }
        let end = editableEnd.flatMap { value(r, $0).dateValue }
        var updates: [String: JSONValue] = [:]
        func encode(_ date: Date, _ field: FieldModel) -> JSONValue {
            .string(DateCoding.encode(date, includeTime: field.includesTime, timeZone: calendar.timeZone))
        }
        func shift(_ date: Date, _ days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: date) ?? date
        }
        if moveDays != 0 {
            updates[startField.id] = encode(shift(start, moveDays), startField)
            if let editableEnd, let end { updates[editableEnd.id] = encode(shift(end, moveDays), editableEnd) }
        }
        if resizeDays != 0, let editableEnd {
            let base = end ?? start
            let length = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: base)).day ?? 0
            let days = max(resizeDays, -max(0, length))
            if days != 0 {
                updates[editableEnd.id] = encode(shift(base, days + moveDays), editableEnd)
            }
        }
        return updates
    }
}

// MARK: - Manual record order

public enum ManualOrder {
    /// The record that dragged records land before when dropped at `dropIndex` (0…count) of the
    /// visible order, skipping the dragged records themselves; nil means the end.
    public static func anchor(visible: [String], moving: Set<String>, dropIndex: Int) -> String? {
        var i = max(0, min(dropIndex, visible.count))
        while i < visible.count, moving.contains(visible[i]) { i += 1 }
        return i < visible.count ? visible[i] : nil
    }
}

extension BaseDocument {
    /// Moves records (keeping their relative order) right before `anchorID`, or to the end.
    public func moveRecords(_ ids: [String], before anchorID: String?) {
        guard let tableID = ids.lazy.compactMap({ self.record($0)?.tableID }).first else { return }
        var seen = Set<String>()
        let moving = ids.filter { record($0)?.tableID == tableID && seen.insert($0).inserted }
        if let anchorID, seen.contains(anchorID) { return }
        let all = records(in: tableID)
        let others = all.filter { !seen.contains($0.id) }
        let insertAt = anchorID.flatMap { a in others.firstIndex { $0.id == a } } ?? others.count
        var newOrder = others.map(\.id)
        newOrder.insert(contentsOf: moving, at: insertAt)
        guard newOrder != all.map(\.id) else { return }

        let lower = insertAt > 0 ? others[insertAt - 1].order : nil
        let upper = insertAt < others.count ? others[insertAt].order : nil
        let n = Double(moving.count)
        let orders: [Double] = (1...moving.count).map { i in
            let k = Double(i)
            switch (lower, upper) {
            case let (l?, u?): return l + (u - l) * k / (n + 1)
            case let (l?, nil): return l + k
            case let (nil, u?): return u - (n + 1 - k)
            case (nil, nil): return k
            }
        }
        let precise = zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 }
            && (lower.map { orders[0] > $0 } ?? true)
            && (upper.map { orders[orders.count - 1] < $0 } ?? true)
        let mutations: [Mutation]
        if precise {
            mutations = zip(moving, orders).map { Mutation(.record, $0, ["_order": .number($1)]) }
        } else {
            // The gap is too small to split: renumber the whole table.
            mutations = newOrder.enumerated().map { Mutation(.record, $1, ["_order": .number(Double($0 + 1))]) }
        }
        commit(mutations, actionName: moving.count == 1 ? "Move Record" : "Move Records")
    }
}

// MARK: - Charts and dashboards

/// One bar, point or slice of a chart.
public struct ChartDatum: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var value: Double
    public var color: ChoiceColor
    /// The bucket for records without a value (drawn muted).
    public var isEmptyBucket: Bool
    public var order: Int
}

public enum DashboardWidgetValue: Equatable, Sendable {
    case number(Double?, text: String)
    case chart([ChartDatum])
    case list([String])
    case progress(matching: Int, total: Int)
}

extension BaseDocument {
    /// Groups records by the chart's category field and aggregates each group.
    public func chartData(_ config: ChartConfig, recordIDs: [String]) -> [ChartDatum] {
        guard let category = field(config.categoryFieldID) else { return [] }
        let aggregate = config.aggregate ?? .count
        let valueField = field(config.valueFieldID)
        struct Bucket {
            var label: String
            var color: ChoiceColor
            var isEmpty: Bool
            var order: Int
            var values: [Double] = []
            var count = 0
        }
        var buckets: [String: Bucket] = [:]
        var firstSeen: [String] = []
        for id in recordIDs {
            guard let r = record(id) else { continue }
            let v = value(r, category)
            var keys: [(String, Bucket)] = []
            if category.type == .checkbox {
                let on: Bool = { if case .bool(true) = v { return true } else { return false } }()
                keys = [(on ? "1" : "0", Bucket(label: on ? "Checked" : "Unchecked", color: on ? .green : .gray, isEmpty: false, order: on ? 0 : 1))]
            } else if v.isEmpty {
                keys = [("", Bucket(label: "Empty", color: .gray, isEmpty: true, order: Int.max))]
            } else {
                switch v {
                case .choice(let c):
                    keys = [(c.id, Bucket(label: c.name, color: c.color, isEmpty: false, order: category.choices.firstIndex { $0.id == c.id } ?? 0))]
                case .choices(let cs):
                    keys = cs.map { c in (c.id, Bucket(label: c.name, color: c.color, isEmpty: false, order: category.choices.firstIndex { $0.id == c.id } ?? 0)) }
                case .links(let refs):
                    keys = refs.map { ($0.id, Bucket(label: $0.title, color: .blue, isEmpty: false, order: 0)) }
                default:
                    let label = displayString(r, category)
                    keys = [("v:" + label, Bucket(label: label, color: .blue, isEmpty: false, order: 0))]
                }
            }
            let number = valueField.flatMap { numericValue(r, $0) }
            for (key, fresh) in keys {
                var bucket = buckets[key] ?? fresh
                if buckets[key] == nil { firstSeen.append(key) }
                bucket.count += 1
                if let number { bucket.values.append(number) }
                buckets[key] = bucket
            }
        }
        var data: [ChartDatum] = firstSeen.compactMap { key in
            guard let b = buckets[key] else { return nil }
            let value: Double
            switch aggregate {
            case .count: value = Double(b.count)
            case .sum: value = b.values.reduce(0, +)
            case .average: value = b.values.isEmpty ? 0 : b.values.reduce(0, +) / Double(b.values.count)
            case .min: value = b.values.min() ?? 0
            case .max: value = b.values.max() ?? 0
            }
            return ChartDatum(id: key, label: b.label, value: value, color: b.color, isEmptyBucket: b.isEmpty, order: b.order)
        }
        if category.type != .singleSelect && category.type != .multipleSelects && category.type != .checkbox {
            // Free-form categories: alphabetical, with colours from a fixed palette.
            let palette: [ChoiceColor] = [.blue, .purple, .teal, .orange, .pink, .green, .yellow, .red, .cyan, .gray]
            let ranked = data.indices.filter { !data[$0].isEmptyBucket }
                .sorted { data[$0].label.localizedStandardCompare(data[$1].label) == .orderedAscending }
            for (rank, index) in ranked.enumerated() {
                data[index].order = rank
                data[index].color = palette[rank % palette.count]
            }
        }
        if config.sortByValue == true {
            data.sort { $0.value != $1.value ? $0.value > $1.value : ($0.order, $0.label) < ($1.order, $1.label) }
        } else {
            data.sort { ($0.order, $0.label) < ($1.order, $1.label) }
        }
        return data
    }

    /// Aggregates a field over records; nil when there are no numbers to average, min or max.
    public func aggregateValue(_ aggregate: ChartAggregate, field: FieldModel?, recordIDs: [String]) -> Double? {
        if aggregate == .count { return Double(recordIDs.count) }
        guard let field else { return nil }
        let numbers = recordIDs.compactMap { id in record(id).flatMap { numericValue($0, field) } }
        switch aggregate {
        case .count: return Double(recordIDs.count)
        case .sum: return numbers.reduce(0, +)
        case .average: return numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        case .min: return numbers.min()
        case .max: return numbers.max()
        }
    }

    /// An aggregate formatted like the field it summarises (currency, percent, duration…).
    public func formatAggregate(_ value: Double?, aggregate: ChartAggregate, field: FieldModel?) -> String {
        guard let value else { return "–" }
        if aggregate == .count { return CellFormatter.number(value, precision: 0) }
        guard let field else { return CellFormatter.number(value, precision: 2) }
        switch field.type {
        case .rating, .count, .autoNumber:
            return CellFormatter.number(value, precision: aggregate == .average ? 1 : 0)
        default:
            let text = CellFormatter.string(.number(value), field: field)
            return text.isEmpty ? CellFormatter.number(value, precision: 2) : text
        }
    }

    /// Records a widget looks at: `recordIDs` narrowed by the widget's own filter.
    public func widgetRecordIDs(_ widget: DashboardWidget, recordIDs: [String]) -> [String] {
        guard let filter = widget.filter, !filter.isEmpty else { return recordIDs }
        return recordIDs.filter { id in record(id).map { matches($0, filter: filter) } ?? false }
    }

    public func dashboardValue(_ widget: DashboardWidget, recordIDs: [String]) -> DashboardWidgetValue {
        switch widget.kind {
        case .number:
            let ids = widgetRecordIDs(widget, recordIDs: recordIDs)
            let aggregate = widget.aggregate ?? .count
            let f = field(widget.fieldID)
            let value = aggregateValue(aggregate, field: f, recordIDs: ids)
            return .number(value, text: formatAggregate(value, aggregate: aggregate, field: f))
        case .chart:
            return .chart(chartData(widget.chart ?? ChartConfig(), recordIDs: widgetRecordIDs(widget, recordIDs: recordIDs)))
        case .list:
            var ids = widgetRecordIDs(widget, recordIDs: recordIDs)
            if let sort = widget.sort, let f = field(sort.fieldID) {
                let keyed = ids.enumerated().map { offset, id -> (offset: Int, id: String, key: SortKey) in
                    let key = record(id).map { r in CellComparison.sortKey(value(r, f), field: f) } ?? .empty
                    return (offset, id, key)
                }
                ids = keyed.sorted { a, b in
                    if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
                    let c = a.key.compare(b.key)
                    if c != .orderedSame { return sort.ascending ? c == .orderedAscending : c == .orderedDescending }
                    return a.offset < b.offset
                }.map(\.id)
            }
            return .list(Array(ids.prefix(widget.recordLimit)))
        case .progress:
            return .progress(matching: widgetRecordIDs(widget, recordIDs: recordIDs).count, total: recordIDs.count)
        }
    }

    /// A widget's title, or a description of what it shows when it has none.
    public func widgetTitle(_ widget: DashboardWidget) -> String {
        if let t = widget.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        switch widget.kind {
        case .number:
            let aggregate = widget.aggregate ?? .count
            guard aggregate != .count, let f = field(widget.fieldID) else { return "Records" }
            switch aggregate {
            case .sum: return "Total \(f.name)"
            case .average: return "Average \(f.name)"
            case .min: return "Lowest \(f.name)"
            case .max: return "Highest \(f.name)"
            case .count: return "Records"
            }
        case .chart:
            let category = field(widget.chart?.categoryFieldID)?.name ?? "category"
            let aggregate = widget.chart?.aggregate ?? .count
            if aggregate == .count { return "Records by \(category)" }
            return "\(aggregate.displayName) of \(field(widget.chart?.valueFieldID)?.name ?? "value") by \(category)"
        case .list:
            return "Records"
        case .progress:
            return "Progress"
        }
    }

    private func numericValue(_ record: RecordModel, _ field: FieldModel) -> Double? {
        let cell = value(record, field)
        if case .list(let items) = cell {
            let numbers = items.compactMap(\.numberValue)
            return numbers.isEmpty ? nil : numbers.reduce(0, +)
        }
        return cell.numberValue
    }
}

extension DashboardConfig {
    /// A starting dashboard for a table: a record count, then a total, a completion gauge or a
    /// checkbox gauge, then a breakdown chart or a list of records.
    public static func starter(tableName: String, fields: [FieldModel], primaryFieldID: String?) -> DashboardConfig {
        var count = DashboardWidget(kind: .number, title: tableName)
        count.aggregate = .count
        var widgets = [count]

        let select = fields.first { $0.type == .singleSelect && !$0.choices.isEmpty }
        let numeric = fields.first { [.currency, .number, .duration].contains($0.type) }
        let finishedNames = ["done", "complete", "completed", "won", "published", "closed", "shipped", "finished"]
        let finished = select.flatMap { s in s.choices.first { finishedNames.contains($0.name.lowercased()) }.map { (field: s, choice: $0) } }
        let checkbox = fields.first { $0.type == .checkbox }

        if let numeric {
            var w = DashboardWidget(kind: .number)
            w.aggregate = .sum
            w.fieldID = numeric.id
            widgets.append(w)
        } else if let finished {
            var w = DashboardWidget(kind: .progress, title: finished.choice.name)
            w.filter = FilterGroup(conditions: [FilterCondition(fieldID: finished.field.id, op: .is, value: .array([.string(finished.choice.id)]))])
            widgets.append(w)
        } else if let checkbox {
            var w = DashboardWidget(kind: .progress, title: checkbox.name)
            w.filter = FilterGroup(conditions: [FilterCondition(fieldID: checkbox.id, op: .is, value: .bool(true))])
            widgets.append(w)
        } else if let primaryFieldID, let primary = fields.first(where: { $0.id == primaryFieldID }) {
            var w = DashboardWidget(kind: .progress, title: "\(primary.name) filled in")
            w.filter = FilterGroup(conditions: [FilterCondition(fieldID: primary.id, op: .isNotEmpty)])
            widgets.append(w)
        }

        if let select {
            var w = DashboardWidget(kind: .chart, span: 2)
            var chart = ChartConfig()
            chart.kind = .bar
            chart.categoryFieldID = select.id
            chart.aggregate = .count
            w.chart = chart
            widgets.append(w)
        } else {
            var w = DashboardWidget(kind: .list, title: "Latest records", span: 2)
            if let date = fields.first(where: { $0.type.isDateLike }) {
                w.sort = SortSpec(fieldID: date.id, ascending: false)
            }
            w.fieldIDs = Array(fields.filter { $0.id != primaryFieldID && $0.type != .attachment && $0.type != .button }.prefix(3).map(\.id))
            w.limit = 5
            widgets.append(w)
        }
        return DashboardConfig(widgets: widgets)
    }
}
