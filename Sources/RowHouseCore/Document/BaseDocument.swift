import Foundation
import Observation

/// The in-memory model of one base. Holds the mergeable `BaseState`, keeps typed caches of tables,
/// fields, views, records and automations in sync with it, and turns every edit into operations that
/// the session persists to this device's log.
@MainActor
@Observable
public final class BaseDocument {
    public let baseID: String
    public let deviceID: String
    public var deviceName: String

    /// Bumped whenever tables, fields, views or base info change.
    public private(set) var schemaRevision = 0
    /// Bumped whenever records or comments change.
    public private(set) var dataRevision = 0
    public private(set) var automationRevision = 0

    @ObservationIgnored public let clock: HybridClock
    @ObservationIgnored public private(set) var state = BaseState()
    @ObservationIgnored public weak var undoManager: UndoManager?
    /// Receives every locally generated operation, in order, for persistence.
    @ObservationIgnored public var outbox: (([ChangeOperation]) -> Void)?

    @ObservationIgnored private var _info = BaseInfo()
    @ObservationIgnored private var tablesByID: [String: TableModel] = [:]
    @ObservationIgnored private var fieldsByID: [String: FieldModel] = [:]
    @ObservationIgnored private var viewsByID: [String: ViewModel] = [:]
    @ObservationIgnored private var recordsByID: [String: RecordModel] = [:]
    @ObservationIgnored private var recordIDsByTable: [String: Set<String>] = [:]
    @ObservationIgnored private var automationsByID: [String: AutomationModel] = [:]
    @ObservationIgnored private var commentsByID: [String: CommentModel] = [:]
    @ObservationIgnored private var devicesByID: [String: DeviceInfo] = [:]

    @ObservationIgnored private var sortedTablesCache: [TableModel]?
    @ObservationIgnored private var fieldsByTableCache: [String: [FieldModel]] = [:]
    @ObservationIgnored private var viewsByTableCache: [String: [ViewModel]] = [:]
    @ObservationIgnored private var recordsByTableCache: [String: [RecordModel]] = [:]
    @ObservationIgnored private var observers: [UUID: (ChangeSet) -> Void] = [:]
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var batchInverse: [[Mutation]] = []
    @ObservationIgnored private var batchChanges: ChangeSet?
    @ObservationIgnored private var batchName: String?

    @ObservationIgnored public private(set) lazy var compute = ComputeEngine(document: self)
    @ObservationIgnored var evaluationCache: [String: (key: Int, result: ViewResult)] = [:]

    public init(baseID: String, deviceID: String, deviceName: String, state: BaseState = BaseState()) {
        self.baseID = baseID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.clock = HybridClock(node: deviceID)
        self.state = state
        clock.observe(state.latest)
        rebuildAllCaches()
    }

    // MARK: - Observation of changes

    @discardableResult
    public func addObserver(_ handler: @escaping (ChangeSet) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    // MARK: - Read access

    public var info: BaseInfo {
        _ = schemaRevision
        return _info
    }

    public var tables: [TableModel] {
        _ = schemaRevision
        if let cached = sortedTablesCache { return cached }
        let sorted = tablesByID.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        sortedTablesCache = sorted
        return sorted
    }

    public func table(_ id: String?) -> TableModel? {
        _ = schemaRevision
        guard let id else { return nil }
        return tablesByID[id]
    }

    public func table(named name: String) -> TableModel? {
        tables.first { $0.name == name } ?? tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Fields of a table: primary field first, then by order.
    public func fields(in tableID: String) -> [FieldModel] {
        _ = schemaRevision
        if let cached = fieldsByTableCache[tableID] { return cached }
        let primary = tablesByID[tableID]?.primaryFieldID
        let sorted = fieldsByID.values
            .filter { $0.tableID == tableID }
            .sorted { a, b in
                if a.id == primary { return b.id != primary }
                if b.id == primary { return false }
                return (a.order, a.id) < (b.order, b.id)
            }
        fieldsByTableCache[tableID] = sorted
        return sorted
    }

    public func field(_ id: String?) -> FieldModel? {
        _ = schemaRevision
        guard let id else { return nil }
        return fieldsByID[id]
    }

    public func field(named name: String, in tableID: String) -> FieldModel? {
        let all = fields(in: tableID)
        return all.first { $0.name == name } ?? all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func primaryField(of tableID: String) -> FieldModel? {
        _ = schemaRevision
        if let pid = tablesByID[tableID]?.primaryFieldID, let f = fieldsByID[pid] { return f }
        return fields(in: tableID).first
    }

    public func views(in tableID: String) -> [ViewModel] {
        _ = schemaRevision
        if let cached = viewsByTableCache[tableID] { return cached }
        let sorted = viewsByID.values.filter { $0.tableID == tableID }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        viewsByTableCache[tableID] = sorted
        return sorted
    }

    public func view(_ id: String?) -> ViewModel? {
        _ = schemaRevision
        guard let id else { return nil }
        return viewsByID[id]
    }

    /// Records of a table in their manual order.
    public func records(in tableID: String) -> [RecordModel] {
        _ = dataRevision
        if let cached = recordsByTableCache[tableID] { return cached }
        let ids = recordIDsByTable[tableID] ?? []
        let sorted = ids.compactMap { recordsByID[$0] }.sorted { ($0.order, $0.createdStamp) < ($1.order, $1.createdStamp) }
        recordsByTableCache[tableID] = sorted
        return sorted
    }

    public func recordCount(in tableID: String) -> Int {
        _ = dataRevision
        return recordIDsByTable[tableID]?.count ?? 0
    }

    public func record(_ id: String?) -> RecordModel? {
        _ = dataRevision
        guard let id else { return nil }
        return recordsByID[id]
    }

    public var automations: [AutomationModel] {
        _ = automationRevision
        return automationsByID.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public func automation(_ id: String?) -> AutomationModel? {
        _ = automationRevision
        guard let id else { return nil }
        return automationsByID[id]
    }

    public func comments(for recordID: String) -> [CommentModel] {
        _ = dataRevision
        return commentsByID.values.filter { $0.recordID == recordID }.sorted { $0.createdTime < $1.createdTime }
    }

    public func commentCount(for recordID: String) -> Int {
        _ = dataRevision
        return commentsByID.values.reduce(0) { $0 + ($1.recordID == recordID ? 1 : 0) }
    }

    public var devices: [DeviceInfo] {
        _ = schemaRevision
        return devicesByID.values.sorted { $0.name < $1.name }
    }

    public func deviceName(for id: String) -> String {
        if id == deviceID { return deviceName }
        return devicesByID[id]?.name ?? "Another Mac"
    }

    // MARK: - Resolved values

    public func value(_ record: RecordModel, _ field: FieldModel) -> CellValue {
        compute.value(record: record, field: field)
    }

    public func value(recordID: String, fieldID: String) -> CellValue {
        guard let r = record(recordID), let f = field(fieldID) else { return .empty }
        return value(r, f)
    }

    public func displayString(_ record: RecordModel, _ field: FieldModel) -> String {
        let v = value(record, field)
        if field.type == .lookup, let target = self.field(field.options.targetFieldID), case .list(let items) = v {
            return items.map { CellFormatter.string($0, field: target) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return CellFormatter.string(v, field: field)
    }

    public func primaryTitle(_ record: RecordModel) -> String {
        compute.title(of: record)
    }

    public func primaryTitle(recordID: String) -> String {
        guard let r = record(recordID) else { return "Deleted record" }
        return primaryTitle(r)
    }

    // MARK: - Commit pipeline

    /// Groups every commit made inside `body` into a single undo step and a single change
    /// notification. Writes are applied immediately, so later reads inside `body` see them.
    public func batch(_ actionName: String? = nil, origin: ChangeOrigin = .local, _ body: () -> Void) {
        batchDepth += 1
        if batchDepth == 1 {
            batchInverse = []
            batchChanges = ChangeSet(origin: origin)
            batchName = actionName
        }
        body()
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        let inverse = batchInverse.reversed().flatMap { $0 }
        let changes = batchChanges
        batchInverse = []
        batchChanges = nil
        registerUndo(inverse, actionName: batchName)
        batchName = nil
        if let changes { notify(changes) }
    }

    public func commit(_ mutations: [Mutation], actionName: String? = nil, origin: ChangeOrigin = .local, undoable: Bool = true) {
        guard !mutations.isEmpty else { return }
        // Coalesce writes to the same entity so each entity gets one op with one timestamp.
        var merged: [(EntityKind, String, [String: JSONValue])] = []
        var index: [String: Int] = [:]
        for m in mutations {
            let key = "\(m.kind.rawValue):\(m.id)"
            if let i = index[key] {
                merged[i].2.merge(m.set) { _, new in new }
            } else {
                index[key] = merged.count
                merged.append((m.kind, m.id, m.set))
            }
        }

        var inverse: [Mutation] = []
        if undoable, undoManager != nil {
            for (kind, id, set) in merged {
                let entity = state.entity(kind, id)
                var prev: [String: JSONValue] = [:]
                for key in set.keys {
                    if let reg = entity?.props[key] {
                        prev[key] = reg.value
                    } else if key == "_deleted" {
                        // Absent means "never deleted" for an existing entity and "didn't exist" for a new one.
                        prev[key] = .bool(entity == nil)
                    } else {
                        prev[key] = .null
                    }
                }
                inverse.append(Mutation(kind, id, prev))
            }
        }

        var ops: [ChangeOperation] = []
        ops.reserveCapacity(merged.count)
        for (kind, id, set) in merged {
            ops.append(ChangeOperation(ts: clock.tick(), kind: kind, id: id, set: set))
        }
        let changes = apply(ops, origin: batchChanges?.origin ?? origin)
        outbox?(ops)

        if batchDepth > 0 {
            if !inverse.isEmpty { batchInverse.append(inverse) }
            batchChanges?.formUnion(changes)
            if batchName == nil { batchName = actionName }
        } else {
            registerUndo(inverse, actionName: actionName)
            notify(changes)
        }
    }

    private func registerUndo(_ inverse: [Mutation], actionName: String?) {
        guard let undoManager, !inverse.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.commit(inverse, actionName: actionName, origin: .local, undoable: true)
            }
        }
        if let actionName { undoManager.setActionName(actionName) }
    }

    /// Applies operations from another device's log.
    public func mergeRemote(_ ops: [ChangeOperation]) {
        guard !ops.isEmpty else { return }
        if let maxTS = ops.map(\.ts).max() { clock.observe(maxTS) }
        let changes = apply(ops, origin: .remote)
        notify(changes)
    }

    /// Merges a snapshot written by another device.
    public func mergeRemote(_ other: BaseState) {
        clock.observe(other.latest)
        let wasLive = Set(recordsByID.keys)
        let tableOf = recordsByID.mapValues(\.tableID)
        let changed = state.merge(other)
        guard !changed.isEmpty else { return }
        var changes = ChangeSet(origin: .remote)
        for (kind, id, keys) in changed {
            rematerialize(kind: kind, id: id, changedKeys: keys, wasLive: wasLive.contains(id), previousTable: tableOf[id], into: &changes)
        }
        finalize(&changes)
        notify(changes)
    }

    /// Replaces the whole state (used once after loading from disk).
    public func load(_ newState: BaseState) {
        state = newState
        clock.observe(newState.latest)
        rebuildAllCaches()
    }

    private func apply(_ ops: [ChangeOperation], origin: ChangeOrigin) -> ChangeSet {
        var changes = ChangeSet(origin: origin)
        for op in ops {
            let wasLive = op.kind == .record && recordsByID[op.id] != nil
            let previousTable = op.kind == .record ? recordsByID[op.id]?.tableID : nil
            let changedKeys = state.apply(op)
            if changedKeys.isEmpty { continue }
            rematerialize(kind: op.kind, id: op.id, changedKeys: changedKeys, wasLive: wasLive, previousTable: previousTable, into: &changes)
        }
        finalize(&changes)
        return changes
    }

    private func finalize(_ changes: inout ChangeSet) {
        if changes.schemaChanged || changes.baseInfoChanged {
            sortedTablesCache = nil
            fieldsByTableCache.removeAll()
            viewsByTableCache.removeAll()
            schemaRevision &+= 1
        }
        if changes.hasRecordChanges || changes.commentsChanged {
            for t in changes.affectedTables { recordsByTableCache[t] = nil }
            dataRevision &+= 1
        }
        if changes.automationsChanged { automationRevision &+= 1 }
        if !changes.isEmpty { compute.invalidate(schema: changes.schemaChanged) }
    }

    private func notify(_ changes: ChangeSet) {
        guard !changes.isEmpty else { return }
        for handler in observers.values { handler(changes) }
    }

    // MARK: - Materialization

    private func rebuildAllCaches() {
        _info = Self.makeInfo(state.entity(.base, "base"))
        tablesByID = [:]
        fieldsByID = [:]
        viewsByID = [:]
        recordsByID = [:]
        recordIDsByTable = [:]
        automationsByID = [:]
        commentsByID = [:]
        devicesByID = [:]
        for (id, e) in state.all(.table) { if let t = Self.makeTable(id, e) { tablesByID[id] = t } }
        for (id, e) in state.all(.field) { if let f = Self.makeField(id, e) { fieldsByID[id] = f } }
        for (id, e) in state.all(.view) { if let v = Self.makeView(id, e) { viewsByID[id] = v } }
        for (id, e) in state.all(.record) {
            if let r = Self.makeRecord(id, e) {
                recordsByID[id] = r
                recordIDsByTable[r.tableID, default: []].insert(id)
            }
        }
        for (id, e) in state.all(.automation) { if let a = Self.makeAutomation(id, e) { automationsByID[id] = a } }
        for (id, e) in state.all(.comment) { if let c = makeComment(id, e) { commentsByID[id] = c } }
        for (id, e) in state.all(.device) { if let d = Self.makeDevice(id, e) { devicesByID[id] = d } }
        sortedTablesCache = nil
        fieldsByTableCache.removeAll()
        viewsByTableCache.removeAll()
        recordsByTableCache.removeAll()
        schemaRevision &+= 1
        dataRevision &+= 1
        automationRevision &+= 1
        compute.invalidate(schema: true)
    }

    private func rematerialize(kind: EntityKind, id: String, changedKeys: [String], wasLive: Bool, previousTable: String?, into changes: inout ChangeSet) {
        let entity = state.entity(kind, id)
        switch kind {
        case .base:
            _info = Self.makeInfo(entity)
            changes.baseInfoChanged = true
        case .table:
            tablesByID[id] = entity.flatMap { Self.makeTable(id, $0) }
            changes.schemaChanged = true
            changes.affectedTables.insert(id)
        case .field:
            let old = fieldsByID[id]
            fieldsByID[id] = entity.flatMap { Self.makeField(id, $0) }
            changes.schemaChanged = true
            if let t = old?.tableID ?? fieldsByID[id]?.tableID { changes.affectedTables.insert(t) }
        case .view:
            viewsByID[id] = entity.flatMap { Self.makeView(id, $0) }
            changes.schemaChanged = true
        case .record:
            let newRecord = entity.flatMap { Self.makeRecord(id, $0) }
            if let prevTable = previousTable, prevTable != newRecord?.tableID {
                recordIDsByTable[prevTable]?.remove(id)
                changes.affectedTables.insert(prevTable)
            }
            if let r = newRecord {
                recordsByID[id] = r
                recordIDsByTable[r.tableID, default: []].insert(id)
                changes.affectedTables.insert(r.tableID)
                if !wasLive {
                    // A record coming back through undo or redo isn't new; only a first write of
                    // `_created` counts, so undo can't re-fire "record created" automations.
                    if changedKeys.contains("_created") {
                        changes.createdRecords[id] = r.tableID
                    } else {
                        changes.restoredRecords[id] = r.tableID
                    }
                } else {
                    let fieldKeys = changedKeys.filter { !$0.hasPrefix("_") }
                    if !fieldKeys.isEmpty { changes.updatedRecords[id, default: []].formUnion(fieldKeys) }
                    if changedKeys.contains("_order") { changes.reorderedTables.insert(r.tableID) }
                }
            } else {
                recordsByID[id] = nil
                if wasLive, let t = previousTable {
                    changes.deletedRecords[id] = t
                }
            }
        case .automation:
            automationsByID[id] = entity.flatMap { Self.makeAutomation(id, $0) }
            changes.automationsChanged = true
        case .comment:
            commentsByID[id] = entity.flatMap { makeComment(id, $0) }
            changes.commentsChanged = true
        case .device:
            devicesByID[id] = entity.flatMap { Self.makeDevice(id, $0) }
            changes.baseInfoChanged = true
        }
    }

    private static func isDeleted(_ e: EntityState) -> Bool {
        e["_deleted"]?.boolValue == true
    }

    private static func makeInfo(_ e: EntityState?) -> BaseInfo {
        var info = BaseInfo()
        guard let e else { return info }
        if let n = e["name"]?.stringValue, !n.isEmpty { info.name = n }
        if let i = e["icon"]?.stringValue, !i.isEmpty { info.icon = i }
        if let c = e["color"]?.stringValue, let color = ChoiceColor(rawValue: c) { info.color = color }
        info.description = e["description"]?.stringValue ?? ""
        info.automationHostDeviceID = e["automationHost"]?.stringValue
        return info
    }

    private static func makeTable(_ id: String, _ e: EntityState) -> TableModel? {
        guard !isDeleted(e), let name = e["name"]?.stringValue else { return nil }
        return TableModel(
            id: id,
            name: name,
            order: e["order"]?.numberValue ?? 0,
            primaryFieldID: e["primaryField"]?.stringValue,
            description: e["description"]?.stringValue ?? "",
            icon: e["icon"]?.stringValue
        )
    }

    private static func makeField(_ id: String, _ e: EntityState) -> FieldModel? {
        guard !isDeleted(e), let table = e["table"]?.stringValue, let name = e["name"]?.stringValue,
              let typeName = e["type"]?.stringValue, let type = FieldType(rawValue: typeName)
        else { return nil }
        return FieldModel(
            id: id,
            tableID: table,
            name: name,
            type: type,
            options: e["options"]?.decode(FieldOptions.self) ?? FieldOptions(),
            order: e["order"]?.numberValue ?? 0,
            description: e["description"]?.stringValue ?? ""
        )
    }

    private static func makeView(_ id: String, _ e: EntityState) -> ViewModel? {
        guard !isDeleted(e), let table = e["table"]?.stringValue, let name = e["name"]?.stringValue,
              let typeName = e["type"]?.stringValue, let type = ViewType(rawValue: typeName)
        else { return nil }
        return ViewModel(
            id: id,
            tableID: table,
            name: name,
            type: type,
            config: e["config"]?.decode(ViewConfig.self) ?? ViewConfig(),
            order: e["order"]?.numberValue ?? 0
        )
    }

    private static func makeRecord(_ id: String, _ e: EntityState) -> RecordModel? {
        guard !isDeleted(e), let table = e["_table"]?.stringValue else { return nil }
        var cells: [String: JSONValue] = [:]
        var stamps: [String: HLC] = [:]
        cells.reserveCapacity(e.props.count)
        for (key, reg) in e.props where !key.hasPrefix("_") {
            stamps[key] = reg.ts
            if !reg.value.isNull { cells[key] = reg.value }
        }
        let createdReg = e.props["_created"] ?? e.props["_table"]!
        let createdMs = e["_created"]?.numberValue ?? Double(createdReg.ts.wall)
        return RecordModel(
            id: id,
            tableID: table,
            order: e["_order"]?.numberValue ?? createdMs,
            createdTime: Date(timeIntervalSince1970: createdMs / 1000),
            createdStamp: createdReg.ts,
            cells: cells,
            cellStamps: stamps
        )
    }

    private static func makeAutomation(_ id: String, _ e: EntityState) -> AutomationModel? {
        guard !isDeleted(e), let name = e["name"]?.stringValue,
              let trigger = e["trigger"]?.decode(AutomationTrigger.self)
        else { return nil }
        return AutomationModel(
            id: id,
            name: name,
            description: e["description"]?.stringValue ?? "",
            enabled: e["enabled"]?.boolValue ?? false,
            trigger: trigger,
            actions: e["actions"]?.decode([AutomationAction].self) ?? [],
            order: e["order"]?.numberValue ?? 0
        )
    }

    private func makeComment(_ id: String, _ e: EntityState) -> CommentModel? {
        guard !Self.isDeleted(e), let record = e["record"]?.stringValue, let text = e["text"]?.stringValue else { return nil }
        let author = e["author"]?.stringValue ?? ""
        return CommentModel(
            id: id,
            recordID: record,
            text: text,
            authorDeviceID: author,
            authorName: e["authorName"]?.stringValue ?? "Unknown",
            createdTime: Date(timeIntervalSince1970: (e["created"]?.numberValue ?? 0) / 1000)
        )
    }

    private static func makeDevice(_ id: String, _ e: EntityState) -> DeviceInfo? {
        guard let name = e["name"]?.stringValue else { return nil }
        return DeviceInfo(id: id, name: name, lastSeen: Date(timeIntervalSince1970: (e["lastSeen"]?.numberValue ?? 0) / 1000))
    }

    // MARK: - Internal helpers for extensions

    func allFieldsUnsorted() -> Dictionary<String, FieldModel>.Values { fieldsByID.values }
    func allRecordsByID() -> [String: RecordModel] { recordsByID }
    func recordIDs(in tableID: String) -> Set<String> { recordIDsByTable[tableID] ?? [] }
    func hasDevice(_ id: String) -> DeviceInfo? { devicesByID[id] }
}
