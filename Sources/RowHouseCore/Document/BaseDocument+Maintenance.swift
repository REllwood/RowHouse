import Foundation

// MARK: - Trash

public struct TrashItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case table, field, view, record, automation, comment

        public var displayName: String {
            switch self {
            case .table: "Table"
            case .field: "Field"
            case .view: "View"
            case .record: "Record"
            case .automation: "Automation"
            case .comment: "Comment"
            }
        }

        var entity: EntityKind {
            switch self {
            case .table: .table
            case .field: .field
            case .view: .view
            case .record: .record
            case .automation: .automation
            case .comment: .comment
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Where it lived, e.g. the table name.
    public var location: String
    public var deletedAt: Date
    public var deletedBy: String
    public var tableID: String?
}

extension BaseDocument {
    /// Everything that has been deleted and can be restored. Deletions are tombstones in the merged
    /// state, so nothing is ever really gone until the trash is emptied.
    public func trashItems() -> [TrashItem] {
        _ = dataRevision
        _ = schemaRevision
        var items: [TrashItem] = []
        func stamp(_ e: EntityState) -> (Date, String) {
            let ts = e.props["_deleted"]?.ts ?? .zero
            return (ts.date, deviceName(for: ts.node))
        }
        func tableName(_ id: String?) -> String {
            guard let id else { return "" }
            if let t = table(id) { return t.name }
            if let e = state.entity(.table, id), let t = Self.makeTable(id, e, includeDeleted: true) { return t.name + " (deleted)" }
            return "Deleted table"
        }
        for (id, e) in state.all(.table) where Self.isDeleted(e) {
            guard let t = Self.makeTable(id, e, includeDeleted: true) else { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .table, title: t.name, location: info.name, deletedAt: at, deletedBy: by, tableID: id))
        }
        for (id, e) in state.all(.field) where Self.isDeleted(e) {
            guard let f = Self.makeField(id, e, includeDeleted: true) else { continue }
            // Fields removed together with their table come back with the table.
            if table(f.tableID) == nil { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .field, title: f.name, location: tableName(f.tableID), deletedAt: at, deletedBy: by, tableID: f.tableID))
        }
        for (id, e) in state.all(.view) where Self.isDeleted(e) {
            guard let v = Self.makeView(id, e, includeDeleted: true), table(v.tableID) != nil else { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .view, title: v.name, location: tableName(v.tableID), deletedAt: at, deletedBy: by, tableID: v.tableID))
        }
        for (id, e) in state.all(.record) where Self.isDeleted(e) {
            guard let r = Self.makeRecord(id, e, includeDeleted: true), table(r.tableID) != nil else { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .record, title: title(ofDeleted: r), location: tableName(r.tableID), deletedAt: at, deletedBy: by, tableID: r.tableID))
        }
        for (id, e) in state.all(.automation) where Self.isDeleted(e) {
            guard let a = Self.makeAutomation(id, e, includeDeleted: true) else { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .automation, title: a.name, location: "Automations", deletedAt: at, deletedBy: by, tableID: nil))
        }
        for (id, e) in state.all(.comment) where Self.isDeleted(e) {
            guard let c = makeComment(id, e, includeDeleted: true), record(c.recordID) != nil else { continue }
            let (at, by) = stamp(e)
            items.append(TrashItem(id: id, kind: .comment, title: c.text, location: primaryTitle(recordID: c.recordID), deletedAt: at, deletedBy: by, tableID: nil))
        }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    private func title(ofDeleted record: RecordModel) -> String {
        guard let primary = primaryField(of: record.tableID) else { return "Unnamed record" }
        let text = CellFormatter.string(compute.valueForStored(record[primary.id], field: primary), field: primary)
        return text.isEmpty ? "Unnamed record" : text
    }

    /// Restores a deleted item. Restoring a table also restores the fields and views deleted with it.
    public func restore(_ item: TrashItem) {
        var mutations = [Mutation(item.kind.entity, item.id, ["_deleted": .bool(false)])]
        if item.kind == .table {
            let window: TimeInterval = 5
            for (id, e) in state.all(.field) where Self.isDeleted(e) && e["table"]?.stringValue == item.id {
                if abs((e.props["_deleted"]?.ts.date ?? .distantPast).timeIntervalSince(item.deletedAt)) <= window {
                    mutations.append(Mutation(.field, id, ["_deleted": .bool(false)]))
                }
            }
            for (id, e) in state.all(.view) where Self.isDeleted(e) && e["table"]?.stringValue == item.id {
                if abs((e.props["_deleted"]?.ts.date ?? .distantPast).timeIntervalSince(item.deletedAt)) <= window {
                    mutations.append(Mutation(.view, id, ["_deleted": .bool(false)]))
                }
            }
        }
        commit(mutations, actionName: "Restore \(item.kind.displayName)")
    }

    /// Clears the contents of deleted records so their data no longer lingers in the base. The
    /// tombstones stay (so every Mac agrees they're deleted) but carry no values.
    public func emptyTrash(_ items: [TrashItem]) {
        var mutations: [Mutation] = []
        for item in items where item.kind == .record {
            guard let e = state.entity(.record, item.id) else { continue }
            var set: [String: JSONValue] = [:]
            for key in e.props.keys where !key.hasPrefix("_") { set[key] = .null }
            if !set.isEmpty { mutations.append(Mutation(.record, item.id, set)) }
        }
        for item in items where item.kind == .comment {
            mutations.append(Mutation(.comment, item.id, ["text": .string("")]))
        }
        commit(mutations, actionName: "Empty Trash", undoable: false)
    }
}

// MARK: - Find and replace

public struct FindReplaceOptions: Sendable, Equatable {
    public var find: String
    public var replacement: String
    public var matchCase: Bool
    public var wholeCell: Bool

    public init(find: String, replacement: String, matchCase: Bool = false, wholeCell: Bool = false) {
        self.find = find
        self.replacement = replacement
        self.matchCase = matchCase
        self.wholeCell = wholeCell
    }
}

extension BaseDocument {
    public static let findReplaceTypes: Set<FieldType> = [.singleLineText, .multilineText, .email, .url, .phoneNumber, .aiText]

    /// Counts matching cells without changing anything.
    public func countMatches(_ options: FindReplaceOptions, recordIDs: [String], fieldIDs: [String]) -> Int {
        replacements(options, recordIDs: recordIDs, fieldIDs: fieldIDs).reduce(0) { $0 + $1.value.count }
    }

    /// Replaces text in the given text fields of the given records; returns how many cells changed.
    @discardableResult
    public func replaceAll(_ options: FindReplaceOptions, recordIDs: [String], fieldIDs: [String]) -> Int {
        let updates = replacements(options, recordIDs: recordIDs, fieldIDs: fieldIDs)
        guard !updates.isEmpty else { return 0 }
        updateRecords(updates, actionName: "Replace All")
        return updates.reduce(0) { $0 + $1.value.count }
    }

    private func replacements(_ options: FindReplaceOptions, recordIDs: [String], fieldIDs: [String]) -> [String: [String: JSONValue]] {
        guard !options.find.isEmpty else { return [:] }
        let fields = fieldIDs.compactMap { field($0) }.filter { Self.findReplaceTypes.contains($0.type) }
        let compareOptions: String.CompareOptions = options.matchCase ? [] : [.caseInsensitive]
        var updates: [String: [String: JSONValue]] = [:]
        for id in recordIDs {
            guard let r = record(id) else { continue }
            for f in fields {
                guard let text = r[f.id].stringValue, !text.isEmpty else { continue }
                let replaced: String
                if options.wholeCell {
                    guard text.compare(options.find, options: compareOptions) == .orderedSame else { continue }
                    replaced = options.replacement
                } else {
                    guard text.range(of: options.find, options: compareOptions) != nil else { continue }
                    replaced = text.replacingOccurrences(of: options.find, with: options.replacement, options: compareOptions)
                }
                if replaced != text { updates[id, default: [:]][f.id] = replaced.isEmpty ? .null : .string(replaced) }
            }
        }
        return updates
    }
}

// MARK: - Unsaved values (forms)

extension BaseDocument {
    /// Whether values that aren't a record yet (e.g. a form being filled in) meet a filter.
    /// Only stored fields are considered; conditions on other fields are ignored.
    public func matches(draft values: [String: JSONValue], tableID: String, filter: FilterGroup) -> Bool {
        evaluateDraft(values, tableID: tableID, filter: filter) ?? true
    }

    private func evaluateDraft(_ values: [String: JSONValue], tableID: String, filter: FilterGroup) -> Bool? {
        var results: [Bool] = []
        for c in filter.conditions {
            guard let f = field(c.fieldID), f.tableID == tableID, f.isEditable else { continue }
            if c.op.needsValue && f.type != .checkbox && (c.value?.isEmptyCell ?? true) { continue }
            let v = compute.valueForStored(values[f.id] ?? .null, field: f)
            results.append(FilterEvaluator.evaluate(c, value: v, field: f, document: self))
        }
        for g in filter.groups {
            if let r = evaluateDraft(values, tableID: tableID, filter: g) { results.append(r) }
        }
        guard !results.isEmpty else { return nil }
        return filter.conjunction == .and ? results.allSatisfy { $0 } : results.contains(true)
    }
}

// MARK: - Revision history

public struct RecordHistoryEntry: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case created, updated, deleted, restored }

    public struct Change: Sendable, Hashable {
        public var fieldName: String
        public var old: String
        public var new: String
    }

    public var id: String
    public var kind: Kind
    public var date: Date
    public var author: String
    public var changes: [Change]
}

extension BaseDocument {
    /// Builds a record's history from its operations (oldest first in, newest first out).
    public func history(of recordID: String, operations: [ChangeOperation]) -> [RecordHistoryEntry] {
        let ops = operations.filter { $0.kind == .record && $0.id == recordID }.sorted { $0.ts < $1.ts }
        var current: [String: JSONValue] = [:]
        var deleted = false
        var entries: [RecordHistoryEntry] = []
        for op in ops {
            var kind: RecordHistoryEntry.Kind = .updated
            if op.set["_created"] != nil { kind = .created }
            if let d = op.set["_deleted"]?.boolValue {
                if d && !deleted { kind = .deleted }
                if !d && deleted && op.set["_created"] == nil { kind = .restored }
                deleted = d
            }
            var changes: [RecordHistoryEntry.Change] = []
            for (key, value) in op.set where !key.hasPrefix("_") {
                let old = current[key] ?? .null
                current[key] = value
                guard old != value, let f = field(key), !f.type.isComputed else { continue }
                changes.append(.init(fieldName: f.name, old: historyText(old, field: f), new: historyText(value, field: f)))
            }
            if kind == .updated && changes.isEmpty { continue }
            changes.sort { $0.fieldName.localizedStandardCompare($1.fieldName) == .orderedAscending }
            entries.append(RecordHistoryEntry(id: op.ts.description, kind: kind, date: op.ts.date, author: deviceName(for: op.ts.node), changes: changes))
        }
        return entries.reversed()
    }

    private func historyText(_ value: JSONValue, field: FieldModel) -> String {
        CellFormatter.string(compute.valueForStored(value, field: field), field: field)
    }
}

// MARK: - Base-wide search

public struct BaseSearchHit: Identifiable, Hashable, Sendable {
    public var id: String { recordID }
    public var recordID: String
    public var tableID: String
    public var title: String
    /// The field where the text was found and a short excerpt around it.
    public var fieldName: String
    public var excerpt: String
}

extension BaseDocument {
    /// Finds records in every table whose values contain `query` (case- and diacritic-insensitive).
    public func search(_ query: String, limit: Int = 200) -> [BaseSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [BaseSearchHit] = []
        for table in tables {
            let fields = fields(in: table.id).filter { $0.type != .button && $0.type != .attachment }
            for r in records(in: table.id) {
                for f in fields {
                    let text = displayString(r, f)
                    guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                    let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
                    let excerpt = (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
                    hits.append(BaseSearchHit(recordID: r.id, tableID: table.id, title: primaryTitle(r), fieldName: f.name, excerpt: excerpt))
                    break
                }
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    // MARK: - Duplicates

    /// Records whose values in `fieldIDs` match after trimming and collapsing whitespace
    /// (and ignoring case unless `matchCase`). Records with all of those values empty are skipped.
    public func findDuplicates(in tableID: String, fieldIDs: [String], matchCase: Bool = false) -> [DuplicateGroup] {
        let fields = fieldIDs.compactMap { field($0) }.filter { $0.tableID == tableID }
        guard !fields.isEmpty else { return [] }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for r in records(in: tableID) {
            let parts = fields.map { f -> String in
                let text = displayString(r, f).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return matchCase ? text : text.lowercased()
            }
            guard parts.contains(where: { !$0.isEmpty }) else { continue }
            let key = parts.joined(separator: "\u{1F}")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r.id)
        }
        return order.compactMap { key in
            guard let ids = groups[key], ids.count > 1 else { return nil }
            return DuplicateGroup(key: key.replacingOccurrences(of: "\u{1F}", with: " · "), recordIDs: ids)
        }
    }

    /// Folds `others` into `keeperID` and moves them to the trash. Empty cells on the keeper take the
    /// first non-empty value from the others; links, multiple selects and attachments are combined;
    /// comments move to the keeper.
    public func mergeRecords(keeping keeperID: String, merging others: [String]) {
        guard let keeper = record(keeperID) else { return }
        let merged = others.filter { $0 != keeperID }.compactMap { record($0) }.filter { $0.tableID == keeper.tableID }
        guard !merged.isEmpty else { return }
        let mergedIDs = Set(merged.map(\.id))
        var values: [String: JSONValue] = [:]
        for f in fields(in: keeper.tableID) where f.isEditable || f.isInverseLink {
            switch f.type {
            case .link:
                var ids = compute.linkedRecordIDs(record: keeper, field: f)
                for r in merged {
                    for id in compute.linkedRecordIDs(record: r, field: f) where !ids.contains(id) { ids.append(id) }
                }
                ids.removeAll { mergedIDs.contains($0) }
                if ids != compute.linkedRecordIDs(record: keeper, field: f) {
                    values[f.id] = ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
                }
            case .collaborator where f.options.allowMultipleCollaborators == true:
                var ids = keeper[f.id].collaboratorIDs
                for r in merged {
                    for id in r[f.id].collaboratorIDs where !ids.contains(id) { ids.append(id) }
                }
                if ids != keeper[f.id].collaboratorIDs { values[f.id] = .array(ids.map(JSONValue.string)) }
            case .multipleSelects, .attachment:
                var items = keeper[f.id].arrayValue ?? []
                for r in merged {
                    for item in r[f.id].arrayValue ?? [] where !items.contains(item) { items.append(item) }
                }
                if items != (keeper[f.id].arrayValue ?? []) { values[f.id] = .array(items) }
            default:
                guard keeper[f.id].isEmptyCell else { continue }
                if let v = merged.lazy.map({ $0[f.id] }).first(where: { !$0.isEmptyCell }) { values[f.id] = v }
            }
        }
        batch("Merge Records") {
            if !values.isEmpty { updateRecord(keeperID, values: values, actionName: "Merge Records") }
            let moved = merged.flatMap { comments(for: $0.id) }.map { Mutation(.comment, $0.id, ["record": .string(keeperID)]) }
            if !moved.isEmpty { commit(moved, actionName: "Merge Records") }
            deleteRecords(merged.map(\.id))
        }
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var id: String { recordIDs.joined(separator: ",") }
    /// The matching values, for display.
    public var key: String
    /// In table order; the first is the suggested record to keep.
    public var recordIDs: [String]
}
