import Foundation

extension BaseDocument {
    // MARK: - Base

    public func updateBaseInfo(name: String? = nil, icon: String? = nil, color: ChoiceColor? = nil, description: String? = nil) {
        var set: [String: JSONValue] = [:]
        if let name { set["name"] = .string(name) }
        if let icon { set["icon"] = .string(icon) }
        if let color { set["color"] = .string(color.rawValue) }
        if let description { set["description"] = .string(description) }
        commit([Mutation(.base, "base", set)], actionName: "Edit Base")
    }

    public func setAutomationHost(_ deviceID: String?) {
        commit([Mutation(.base, "base", ["automationHost": deviceID.map(JSONValue.string) ?? .null])], actionName: "Change Automation Host")
    }

    /// The device that runs scheduled automations: the configured host or, when none is set, the
    /// same Mac on every device (the lowest registered device id), so schedules never fire twice.
    public var effectiveAutomationHost: String {
        if let host = info.automationHostDeviceID { return host }
        return (devices.map(\.id) + [deviceID]).min() ?? deviceID
    }

    /// Records this device's name so other devices can show who made changes. Not undoable.
    public func registerDevice() {
        let existing = hasDevice(deviceID)
        let stale = existing.map { Date().timeIntervalSince($0.lastSeen) > 86_400 } ?? true
        guard existing?.name != deviceName || stale else { return }
        commit([Mutation(.device, deviceID, [
            "name": .string(deviceName),
            "lastSeen": .number(Date().timeIntervalSince1970 * 1000),
        ])], undoable: false)
    }

    // MARK: - Tables

    @discardableResult
    public func createTable(name: String, starterFields: Bool = true, emptyRecords: Int = 3) -> String {
        let tableID = RowID.table()
        let primaryID = RowID.field()
        let order = (tables.map(\.order).max() ?? 0) + 1
        var mutations: [Mutation] = [
            Mutation(.table, tableID, ["name": .string(uniqueTableName(name)), "order": .number(order), "primaryField": .string(primaryID), "_deleted": .bool(false)]),
            fieldMutation(id: primaryID, tableID: tableID, name: "Name", type: .singleLineText, options: FieldOptions(), order: 0),
        ]
        if starterFields {
            var status = FieldOptions()
            status.choices = [
                SelectChoice(name: "Todo", color: .red),
                SelectChoice(name: "In progress", color: .yellow),
                SelectChoice(name: "Done", color: .green),
            ]
            mutations.append(fieldMutation(id: RowID.field(), tableID: tableID, name: "Notes", type: .multilineText, options: FieldOptions(), order: 1))
            mutations.append(fieldMutation(id: RowID.field(), tableID: tableID, name: "Status", type: .singleSelect, options: status, order: 2))
            mutations.append(fieldMutation(id: RowID.field(), tableID: tableID, name: "Attachments", type: .attachment, options: FieldOptions(), order: 3))
        }
        mutations.append(viewMutation(id: RowID.view(), tableID: tableID, name: "Grid view", type: .grid, config: ViewConfig(), order: 0))
        let now = Date().timeIntervalSince1970 * 1000
        for i in 0..<emptyRecords {
            mutations.append(Mutation(.record, RowID.record(), ["_table": .string(tableID), "_order": .number(Double(i + 1)), "_created": .number(now), "_deleted": .bool(false)]))
        }
        commit(mutations, actionName: "Add Table")
        return tableID
    }

    public func renameTable(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit([Mutation(.table, id, ["name": .string(trimmed)])], actionName: "Rename Table")
    }

    public func updateTableDescription(_ id: String, _ description: String) {
        commit([Mutation(.table, id, ["description": .string(description)])], actionName: "Edit Table Description")
    }

    public func moveTable(_ id: String, before otherID: String?) {
        let ordered = tables
        let order = orderBetween(ordered.map { ($0.id, $0.order) }, movingID: id, beforeID: otherID)
        commit([Mutation(.table, id, ["order": .number(order)])], actionName: "Move Table")
    }

    public func deleteTable(_ id: String) {
        guard tables.count > 1 else { return }
        var mutations = [Mutation(.table, id, ["_deleted": .bool(true)])]
        for f in allFieldsUnsorted() {
            if f.tableID == id {
                mutations.append(Mutation(.field, f.id, ["_deleted": .bool(true)]))
            } else if f.type == .link, f.options.linkedTableID == id {
                mutations.append(Mutation(.field, f.id, ["_deleted": .bool(true)]))
            }
        }
        for v in views(in: id) { mutations.append(Mutation(.view, v.id, ["_deleted": .bool(true)])) }
        commit(mutations, actionName: "Delete Table")
    }

    @discardableResult
    public func duplicateTable(_ id: String, includeRecords: Bool) -> String? {
        guard let table = table(id) else { return nil }
        let newTableID = RowID.table()
        var fieldMap: [String: String] = [:]
        let sourceFields = fields(in: id)
        for f in sourceFields { fieldMap[f.id] = RowID.field() }
        var mutations: [Mutation] = [
            Mutation(.table, newTableID, [
                "name": .string(uniqueTableName(table.name + " copy")),
                "order": .number(table.order + 0.5),
                "primaryField": .string(fieldMap[table.primaryFieldID ?? ""] ?? fieldMap[sourceFields.first?.id ?? ""] ?? ""),
                "description": .string(table.description),
                "_deleted": .bool(false),
            ]),
        ]
        for f in sourceFields {
            var options = f.options
            // Links are copied as plain text fields to avoid creating hidden inverse relationships.
            var type = f.type
            if f.type == .link || f.type == .lookup || f.type == .rollup || f.type == .count {
                type = .singleLineText
                options = FieldOptions()
            }
            if var formula = options.formula {
                for (old, new) in fieldMap { formula = formula.replacingOccurrences(of: "{\(old)}", with: "{\(new)}") }
                options.formula = formula
            }
            mutations.append(fieldMutation(id: fieldMap[f.id]!, tableID: newTableID, name: f.name, type: type, options: options, order: f.order, description: f.description))
        }
        for v in views(in: id) {
            var config = v.config
            config.remap(fieldMap)
            mutations.append(viewMutation(id: RowID.view(), tableID: newTableID, name: v.name, type: v.type, config: config, order: v.order))
        }
        if includeRecords {
            let now = Date().timeIntervalSince1970 * 1000
            for r in records(in: id) {
                var set: [String: JSONValue] = ["_table": .string(newTableID), "_order": .number(r.order), "_created": .number(now), "_deleted": .bool(false)]
                for f in sourceFields {
                    guard let newID = fieldMap[f.id] else { continue }
                    if f.type == .link || f.type == .lookup || f.type == .rollup || f.type == .count {
                        let text = displayString(r, f)
                        if !text.isEmpty { set[newID] = .string(text) }
                    } else if let v = r.cells[f.id] {
                        set[newID] = v
                    }
                }
                mutations.append(Mutation(.record, RowID.record(), set))
            }
        }
        commit(mutations, actionName: "Duplicate Table")
        return newTableID
    }

    /// Saves a record's editable values as a template for new records in its table.
    @discardableResult
    public func saveTemplate(named name: String, from recordID: String) -> RecordTemplate? {
        guard let r = record(recordID), let table = table(r.tableID) else { return nil }
        var values: [String: JSONValue] = [:]
        for f in fields(in: r.tableID) where f.isEditable && !f.isInverseLink {
            if let v = r.cells[f.id], !v.isEmptyCell { values[f.id] = v }
        }
        let template = RecordTemplate(name: name.isEmpty ? "Template" : name, values: values)
        setTemplates(table.recordTemplates + [template], in: table.id)
        return template
    }

    public func setTemplates(_ templates: [RecordTemplate], in tableID: String) {
        commit([Mutation(.table, tableID, ["recordTemplates": JSONValue(encoding: templates)])], actionName: "Edit Record Templates")
    }

    /// Creates a record from a template; values for fields that no longer exist are skipped.
    @discardableResult
    public func createRecord(from template: RecordTemplate, in tableID: String, after afterID: String? = nil) -> String {
        let values = template.values.filter { key, _ in field(key).map { $0.tableID == tableID && $0.isEditable } ?? false }
        return createRecord(in: tableID, values: values, after: afterID)
    }

    public func uniqueTableName(_ base: String) -> String {
        let names = Set(tables.map { $0.name.lowercased() })
        return uniqueName(base, taken: names)
    }

    // MARK: - Fields

    func fieldMutation(id: String, tableID: String, name: String, type: FieldType, options: FieldOptions, order: Double, description: String = "") -> Mutation {
        Mutation(.field, id, [
            "table": .string(tableID),
            "name": .string(name),
            "type": .string(type.rawValue),
            "options": JSONValue(encoding: options),
            "order": .number(order),
            "description": .string(description),
            "_deleted": .bool(false),
        ])
    }

    public func uniqueFieldName(_ base: String, in tableID: String, excluding fieldID: String? = nil) -> String {
        let names = Set(fields(in: tableID).filter { $0.id != fieldID }.map { $0.name.lowercased() })
        return uniqueName(base, taken: names)
    }

    /// Creates a field. Link fields automatically get a paired inverse field in the linked table.
    @discardableResult
    public func createField(in tableID: String, name: String, type: FieldType, options: FieldOptions = FieldOptions(), description: String = "", after afterFieldID: String? = nil) -> String {
        let fieldID = RowID.field()
        let existing = fields(in: tableID)
        var order = (existing.map(\.order).max() ?? 0) + 1
        if let afterFieldID, let idx = existing.firstIndex(where: { $0.id == afterFieldID }) {
            let next = idx + 1 < existing.count ? existing[idx + 1].order : existing[idx].order + 2
            order = (existing[idx].order + next) / 2
        }
        var options = normalizedOptions(options, for: type, tableID: tableID)
        var mutations: [Mutation] = []
        if type == .link, let target = options.linkedTableID, target != tableID, options.isInverseLink != true {
            let inverseID = RowID.field()
            options.inverseFieldID = inverseID
            var inverse = FieldOptions()
            inverse.linkedTableID = tableID
            inverse.inverseFieldID = fieldID
            inverse.isInverseLink = true
            let targetFields = fields(in: target)
            let inverseName = uniqueName(table(tableID)?.name ?? "Linked", taken: Set(targetFields.map { $0.name.lowercased() }))
            mutations.append(fieldMutation(id: inverseID, tableID: target, name: inverseName, type: .link, options: inverse, order: (targetFields.map(\.order).max() ?? 0) + 1))
        }
        let finalName = uniqueFieldName(name.isEmpty ? type.displayName : name, in: tableID)
        mutations.insert(fieldMutation(id: fieldID, tableID: tableID, name: finalName, type: type, options: options, order: order, description: description), at: 0)
        commit(mutations, actionName: "Add Field")
        return fieldID
    }

    /// Updates a field's name, type, options or description, converting existing cell values when the type changes.
    public func updateField(_ id: String, name: String? = nil, type newType: FieldType? = nil, options newOptions: FieldOptions? = nil, description: String? = nil) {
        guard let field = field(id) else { return }
        var set: [String: JSONValue] = [:]
        var mutations: [Mutation] = []
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != field.name {
                set["name"] = .string(uniqueFieldName(trimmed, in: field.tableID, excluding: id))
            }
        }
        if let description { set["description"] = .string(description) }
        let targetType = newType ?? field.type
        var options = newOptions ?? field.options
        options = normalizedOptions(options, for: targetType, tableID: field.tableID)

        if targetType != field.type || newOptions != nil {
            // Link bookkeeping: create or remove the inverse field as needed.
            let wasOwnerLink = field.type == .link && !field.isInverseLink
            let isOwnerLink = targetType == .link && options.isInverseLink != true
            if wasOwnerLink, let inv = field.options.inverseFieldID,
               !isOwnerLink || options.linkedTableID != field.options.linkedTableID {
                if self.field(inv)?.isInverseLink == true {
                    mutations.append(Mutation(.field, inv, ["_deleted": .bool(true)]))
                }
                options.inverseFieldID = nil
            }
            if field.isInverseLink, targetType != .link || options.isInverseLink != true,
               let ownerID = field.options.inverseFieldID, var ownerOptions = self.field(ownerID)?.options {
                // The inverse is becoming an ordinary field: the owner stops pointing at it.
                ownerOptions.inverseFieldID = nil
                mutations.append(Mutation(.field, ownerID, ["options": JSONValue(encoding: ownerOptions)]))
                options.isInverseLink = nil
                options.inverseFieldID = nil
            }
            if isOwnerLink, let target = options.linkedTableID, target != field.tableID,
               options.inverseFieldID == nil || self.field(options.inverseFieldID) == nil {
                let inverseID = RowID.field()
                options.inverseFieldID = inverseID
                var inverse = FieldOptions()
                inverse.linkedTableID = field.tableID
                inverse.inverseFieldID = id
                inverse.isInverseLink = true
                let targetFields = fields(in: target)
                let inverseName = uniqueName(table(field.tableID)?.name ?? "Linked", taken: Set(targetFields.map { $0.name.lowercased() }))
                mutations.append(fieldMutation(id: inverseID, tableID: target, name: inverseName, type: .link, options: inverse, order: (targetFields.map(\.order).max() ?? 0) + 1))
            }
            if targetType != field.type {
                set["type"] = .string(targetType.rawValue)
                let conversion = convertValues(of: field, to: targetType, options: &options)
                mutations.append(contentsOf: conversion)
            }
            set["options"] = JSONValue(encoding: options)
        }
        guard !set.isEmpty || !mutations.isEmpty else { return }
        mutations.insert(Mutation(.field, id, set), at: 0)
        commit(mutations, actionName: targetType != field.type ? "Change Field Type" : "Edit Field")
    }

    public func renameField(_ id: String, to name: String) {
        updateField(id, name: name)
    }

    public func deleteField(_ id: String) {
        guard let field = field(id), table(field.tableID)?.primaryFieldID != id else { return }
        var mutations = [Mutation(.field, id, ["_deleted": .bool(true)])]
        if field.type == .link, let inv = field.options.inverseFieldID {
            if field.isInverseLink {
                // Deleting the inverse side keeps the owning field but forgets the pairing.
                if var ownerOptions = self.field(inv)?.options {
                    ownerOptions.inverseFieldID = nil
                    mutations.append(Mutation(.field, inv, ["options": JSONValue(encoding: ownerOptions)]))
                }
            } else if self.field(inv)?.isInverseLink == true {
                mutations.append(Mutation(.field, inv, ["_deleted": .bool(true)]))
            }
        }
        commit(mutations, actionName: "Delete Field")
    }

    @discardableResult
    public func duplicateField(_ id: String, includeValues: Bool) -> String? {
        guard let field = field(id) else { return nil }
        var options = field.options
        if field.type == .link {
            options.inverseFieldID = nil
            options.isInverseLink = nil
        }
        var newID = ""
        batch("Duplicate Field") {
            newID = createField(in: field.tableID, name: field.name + " copy", type: field.type == .link && field.isInverseLink ? .link : field.type, options: options, description: field.description, after: id)
            if includeValues && !field.type.isComputed {
                var mutations: [Mutation] = []
                for r in records(in: field.tableID) {
                    if field.isInverseLink {
                        let ids = compute.linkedRecordIDs(record: r, field: field)
                        if !ids.isEmpty { mutations.append(Mutation(.record, r.id, [newID: .array(ids.map(JSONValue.string))])) }
                    } else if let v = r.cells[id] {
                        mutations.append(Mutation(.record, r.id, [newID: v]))
                    }
                }
                commit(mutations)
            }
        }
        return newID
    }

    public func setPrimaryField(_ fieldID: String, in tableID: String) {
        guard let f = field(fieldID), f.tableID == tableID, f.type.canBePrimary else { return }
        commit([Mutation(.table, tableID, ["primaryField": .string(fieldID)])], actionName: "Set Primary Field")
    }

    public func moveField(_ id: String, before otherID: String?) {
        guard let f = field(id) else { return }
        let ordered = fields(in: f.tableID)
        let order = orderBetween(ordered.map { ($0.id, $0.order) }, movingID: id, beforeID: otherID)
        commit([Mutation(.field, id, ["order": .number(order)])], actionName: "Move Field")
    }

    /// Adds a choice to a select field (used when a typed or pasted value doesn't exist yet).
    @discardableResult
    public func addChoice(named name: String, to fieldID: String) -> SelectChoice? {
        guard let field = field(fieldID), field.type == .singleSelect || field.type == .multipleSelects else { return nil }
        if let existing = field.choice(named: name) { return existing }
        var options = field.options
        let choice = SelectChoice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: .cycling(options.choices?.count ?? 0))
        options.choices = (options.choices ?? []) + [choice]
        commit([Mutation(.field, fieldID, ["options": JSONValue(encoding: options)])], actionName: "Add Option")
        return choice
    }

    private func normalizedOptions(_ options: FieldOptions, for type: FieldType, tableID: String) -> FieldOptions {
        var o = options
        switch type {
        case .singleSelect, .multipleSelects:
            if o.choices == nil { o.choices = [] }
        case .rating:
            if o.ratingMax == nil { o.ratingMax = 5 }
        case .currency:
            if o.currencySymbol == nil { o.currencySymbol = Locale.current.currencySymbol ?? "$" }
            if o.precision == nil { o.precision = 2 }
        case .percent:
            if o.precision == nil { o.precision = 0 }
        case .duration:
            if o.durationFormat == nil { o.durationFormat = .hoursMinutes }
        case .date:
            if o.dateFormat == nil { o.dateFormat = .friendly }
        case .rollup:
            if o.rollupFormula == nil { o.rollupFormula = "SUM(values)" }
        case .button:
            if o.buttonLabel == nil { o.buttonLabel = "Open" }
            if o.buttonAction == nil { o.buttonAction = .openURL }
        case .formula:
            if let formula = o.formula { o.formula = formulaWithFieldIDs(formula, tableID: tableID) }
        default:
            break
        }
        if type == .button, let formula = o.buttonURLFormula { o.buttonURLFormula = formulaWithFieldIDs(formula, tableID: tableID) }
        return o
    }

    // MARK: - Views

    @discardableResult
    public func createView(in tableID: String, name: String, type: ViewType) -> String {
        let id = RowID.view()
        var config = ViewConfig()
        let fields = fields(in: tableID)
        switch type {
        case .kanban:
            config.stackFieldID = fields.first { $0.type == .singleSelect }?.id
            config.coverFieldID = fields.first { $0.type == .attachment }?.id
        case .gallery:
            config.coverFieldID = fields.first { $0.type == .attachment }?.id
        case .calendar, .timeline:
            let dates = fields.filter { $0.type == .date }
            config.dateFieldID = dates.first?.id ?? fields.first { $0.type.isDateLike }?.id
            if type == .timeline { config.endDateFieldID = dates.dropFirst().first?.id }
        case .form:
            var form = FormConfig()
            form.title = table(tableID)?.name
            form.fieldIDs = fields.filter { $0.isEditable && !$0.isInverseLink }.map(\.id)
            config.form = form
        case .chart:
            var chart = ChartConfig()
            chart.kind = .bar
            chart.categoryFieldID = fields.first { $0.type == .singleSelect }?.id ?? fields.first?.id
            chart.aggregate = .count
            config.chart = chart
        case .grid:
            break
        }
        let order = (views(in: tableID).map(\.order).max() ?? 0) + 1
        let finalName = uniqueName(name, taken: Set(views(in: tableID).map { $0.name.lowercased() }))
        commit([viewMutation(id: id, tableID: tableID, name: finalName, type: type, config: config, order: order)], actionName: "Add View")
        return id
    }

    func viewMutation(id: String, tableID: String, name: String, type: ViewType, config: ViewConfig, order: Double) -> Mutation {
        Mutation(.view, id, [
            "table": .string(tableID),
            "name": .string(name),
            "type": .string(type.rawValue),
            "config": JSONValue(encoding: config),
            "order": .number(order),
            "_deleted": .bool(false),
        ])
    }

    public func renameView(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit([Mutation(.view, id, ["name": .string(trimmed)])], actionName: "Rename View")
    }

    public func updateViewConfig(_ id: String, actionName: String = "Change View", _ update: (inout ViewConfig) -> Void) {
        guard let view = view(id) else { return }
        var config = view.config
        update(&config)
        guard config != view.config else { return }
        if view.config.isLocked {
            // Only unlocking is allowed on a locked view.
            var otherChanges = config
            otherChanges.locked = view.config.locked
            guard otherChanges == view.config else { return }
        }
        commit([Mutation(.view, id, ["config": JSONValue(encoding: config)])], actionName: actionName)
    }

    @discardableResult
    public func duplicateView(_ id: String) -> String? {
        guard let view = view(id) else { return nil }
        let newID = RowID.view()
        let finalName = uniqueName(view.name + " copy", taken: Set(views(in: view.tableID).map { $0.name.lowercased() }))
        commit([viewMutation(id: newID, tableID: view.tableID, name: finalName, type: view.type, config: view.config, order: view.order + 0.5)], actionName: "Duplicate View")
        return newID
    }

    public func deleteView(_ id: String) {
        guard let view = view(id), views(in: view.tableID).count > 1 else { return }
        commit([Mutation(.view, id, ["_deleted": .bool(true)])], actionName: "Delete View")
    }

    public func moveView(_ id: String, before otherID: String?) {
        guard let v = view(id) else { return }
        let ordered = views(in: v.tableID)
        let order = orderBetween(ordered.map { ($0.id, $0.order) }, movingID: id, beforeID: otherID)
        commit([Mutation(.view, id, ["order": .number(order)])], actionName: "Move View")
    }

    // MARK: - Records

    /// Creates a record. `values` maps field ids to stored JSON; edits to inverse link fields are
    /// translated onto the owning side.
    @discardableResult
    public func createRecord(in tableID: String, values: [String: JSONValue] = [:], after afterID: String? = nil, origin: ChangeOrigin = .local) -> String {
        createRecords(in: tableID, values: [values], after: afterID, origin: origin).first ?? ""
    }

    @discardableResult
    public func createRecords(in tableID: String, values: [[String: JSONValue]], after afterID: String? = nil, origin: ChangeOrigin = .local) -> [String] {
        let existing = records(in: tableID)
        var start = (existing.last?.order ?? 0) + 1
        var step = 1.0
        if let afterID, let idx = existing.firstIndex(where: { $0.id == afterID }) {
            let lower = existing[idx].order
            let upper = idx + 1 < existing.count ? existing[idx + 1].order : lower + 1
            step = (upper - lower) / Double(values.count + 1)
            start = lower + step
        }
        let now = Date().timeIntervalSince1970 * 1000
        var ids: [String] = []
        var mutations: [Mutation] = []
        var work = InverseLinkWork()
        for (i, vals) in values.enumerated() {
            let id = RowID.record()
            ids.append(id)
            var set: [String: JSONValue] = [
                "_table": .string(tableID),
                "_order": .number(start + Double(i) * step),
                "_created": .number(now),
                "_deleted": .bool(false),
            ]
            set.merge(splitInverseLinkWrites(recordID: id, values: vals, isNew: true, work: &work)) { _, new in new }
            mutations.append(Mutation(.record, id, set))
        }
        mutations.append(contentsOf: work.mutations)
        commit(mutations, actionName: values.count == 1 ? "Add Record" : "Add Records", origin: origin)
        return ids
    }

    public func updateRecord(_ id: String, values: [String: JSONValue], actionName: String = "Edit Record", origin: ChangeOrigin = .local) {
        updateRecords([id: values], actionName: actionName, origin: origin)
    }

    public func updateRecords(_ updates: [String: [String: JSONValue]], actionName: String = "Edit Records", origin: ChangeOrigin = .local) {
        var mutations: [Mutation] = []
        var work = InverseLinkWork()
        for (id, values) in updates {
            guard record(id) != nil else { continue }
            let own = splitInverseLinkWrites(recordID: id, values: values, isNew: false, work: &work)
            if !own.isEmpty { mutations.append(Mutation(.record, id, own)) }
        }
        mutations.append(contentsOf: work.mutations)
        commit(mutations, actionName: actionName, origin: origin)
    }

    public func deleteRecords(_ ids: [String], origin: ChangeOrigin = .local) {
        let mutations = ids.filter { record($0) != nil }.map { Mutation(.record, $0, ["_deleted": .bool(true)]) }
        commit(mutations, actionName: ids.count == 1 ? "Delete Record" : "Delete Records", origin: origin)
    }

    @discardableResult
    public func duplicateRecords(_ ids: [String]) -> [String] {
        var newIDs: [String] = []
        batch("Duplicate Records") {
            for id in ids {
                guard let r = record(id) else { continue }
                var values = r.cells
                for f in fields(in: r.tableID) where f.isInverseLink {
                    let linked = compute.linkedRecordIDs(record: r, field: f)
                    if !linked.isEmpty { values[f.id] = .array(linked.map(JSONValue.string)) }
                }
                newIDs.append(createRecord(in: r.tableID, values: values, after: id))
            }
        }
        return newIDs
    }

    public func moveRecord(_ id: String, before otherID: String?) {
        guard let r = record(id) else { return }
        let ordered = records(in: r.tableID)
        let order = orderBetween(ordered.map { ($0.id, $0.order) }, movingID: id, beforeID: otherID)
        commit([Mutation(.record, id, ["_order": .number(order)])], actionName: "Move Record")
    }

    /// Parses user-entered text for a cell and stores it. New select options are created on the fly.
    public func setCell(recordID: String, fieldID: String, text: String, origin: ChangeOrigin = .local) {
        guard let field = field(fieldID), field.isEditable else { return }
        batch("Edit Cell", origin: origin) {
            let value = parseValue(text, for: field, createMissingChoices: true)
            updateRecord(recordID, values: [fieldID: value], actionName: "Edit Cell", origin: origin)
        }
    }

    /// Pending writes to owning link fields, accumulated across every record in one update so that
    /// several records changing links to the same target don't overwrite each other.
    struct InverseLinkWork {
        private var arrays: [String: (recordID: String, fieldID: String, ids: [String])] = [:]
        private var order: [String] = []

        mutating func update(target: String, ownerField: String, initial: () -> [String], _ change: (inout [String]) -> Void) {
            let key = target + "|" + ownerField
            if arrays[key] == nil {
                arrays[key] = (target, ownerField, initial())
                order.append(key)
            }
            change(&arrays[key]!.ids)
        }

        var mutations: [Mutation] {
            order.compactMap { key in
                guard let entry = arrays[key] else { return nil }
                return Mutation(.record, entry.recordID, [entry.fieldID: entry.ids.isEmpty ? .null : .array(entry.ids.map(JSONValue.string))])
            }
        }
    }

    /// Writes to inverse link fields become writes to the owning field on the linked records.
    /// Returns the writes that belong to the record itself.
    private func splitInverseLinkWrites(recordID: String, values: [String: JSONValue], isNew: Bool, work: inout InverseLinkWork) -> [String: JSONValue] {
        var own: [String: JSONValue] = [:]
        for (fieldID, value) in values {
            guard let f = field(fieldID) else { continue }
            if f.type.isComputed { continue }
            guard f.isInverseLink, let ownerID = f.options.inverseFieldID, let owner = field(ownerID) else {
                own[fieldID] = value
                continue
            }
            let desired = value.stringArray
            var current: [String] = []
            if !isNew, let r = record(recordID) {
                current = compute.linkedRecordIDs(record: r, field: f)
            }
            let single = owner.options.singleRecordLink == true
            for added in desired where !current.contains(added) {
                guard let target = record(added), target.tableID == owner.tableID else { continue }
                work.update(target: added, ownerField: owner.id, initial: { target[owner.id].stringArray }) { ids in
                    if single {
                        ids = [recordID]
                    } else if !ids.contains(recordID) {
                        ids.append(recordID)
                    }
                }
            }
            for removed in current where !desired.contains(removed) {
                guard let target = record(removed) else { continue }
                work.update(target: removed, ownerField: owner.id, initial: { target[owner.id].stringArray }) { ids in
                    ids.removeAll { $0 == recordID }
                }
            }
        }
        return own
    }

    // MARK: - Comments

    public func addComment(to recordID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit([Mutation(.comment, RowID.comment(), [
            "record": .string(recordID),
            "text": .string(trimmed),
            "author": .string(deviceID),
            "authorName": .string(deviceName),
            "created": .number(Date().timeIntervalSince1970 * 1000),
            "_deleted": .bool(false),
        ])], actionName: "Add Comment")
    }

    public func deleteComment(_ id: String) {
        commit([Mutation(.comment, id, ["_deleted": .bool(true)])], actionName: "Delete Comment")
    }

    // MARK: - Automations

    @discardableResult
    public func createAutomation(name: String, trigger: AutomationTrigger, actions: [AutomationAction] = [], enabled: Bool = false) -> String {
        let id = RowID.automation()
        let order = (automations.map(\.order).max() ?? 0) + 1
        commit([Mutation(.automation, id, [
            "name": .string(name),
            "description": .string(""),
            "enabled": .bool(enabled),
            "trigger": JSONValue(encoding: trigger),
            "actions": JSONValue(encoding: actions),
            "order": .number(order),
            "_deleted": .bool(false),
        ])], actionName: "Add Automation")
        return id
    }

    public func updateAutomation(_ id: String, actionName: String = "Edit Automation", _ update: (inout AutomationModel) -> Void) {
        guard let current = automation(id) else { return }
        var next = current
        update(&next)
        var set: [String: JSONValue] = [:]
        if next.name != current.name { set["name"] = .string(next.name) }
        if next.description != current.description { set["description"] = .string(next.description) }
        if next.enabled != current.enabled { set["enabled"] = .bool(next.enabled) }
        if next.trigger != current.trigger { set["trigger"] = JSONValue(encoding: next.trigger) }
        if next.actions != current.actions { set["actions"] = JSONValue(encoding: next.actions) }
        if next.order != current.order { set["order"] = .number(next.order) }
        guard !set.isEmpty else { return }
        commit([Mutation(.automation, id, set)], actionName: actionName)
    }

    public func deleteAutomation(_ id: String) {
        commit([Mutation(.automation, id, ["_deleted": .bool(true)])], actionName: "Delete Automation")
    }

    @discardableResult
    public func duplicateAutomation(_ id: String) -> String? {
        guard let a = automation(id) else { return nil }
        let actions = a.actions.map { action -> AutomationAction in
            var copy = action
            copy.id = RowID.action()
            return copy
        }
        return createAutomation(name: a.name + " copy", trigger: a.trigger, actions: actions, enabled: false)
    }

    // MARK: - Helpers

    func uniqueName(_ base: String, taken: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Untitled" : trimmed
        if !taken.contains(root.lowercased()) { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    /// Fractional ordering: returns an order value placing `movingID` right before `beforeID` (or last).
    func orderBetween(_ items: [(String, Double)], movingID: String, beforeID: String?) -> Double {
        let others = items.filter { $0.0 != movingID }
        guard let beforeID, let idx = others.firstIndex(where: { $0.0 == beforeID }) else {
            return (others.last?.1 ?? 0) + 1
        }
        let upper = others[idx].1
        let lower = idx > 0 ? others[idx - 1].1 : upper - 2
        return (lower + upper) / 2
    }
}

extension ViewConfig {
    /// Rewrites field ids (used when duplicating a table).
    mutating func remap(_ map: [String: String]) {
        func m(_ id: String?) -> String? { id.flatMap { map[$0] ?? $0 } }
        hiddenFieldIDs = hiddenFieldIDs?.compactMap { map[$0] }
        fieldOrder = fieldOrder?.compactMap { map[$0] }
        if let widths = columnWidths {
            columnWidths = Dictionary(widths.compactMap { k, v in map[k].map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        }
        if let s = summaries {
            summaries = Dictionary(s.compactMap { k, v in map[k].map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        }
        sorts = sorts?.map { SortSpec(fieldID: map[$0.fieldID] ?? $0.fieldID, ascending: $0.ascending) }
        groups = groups?.map { SortSpec(fieldID: map[$0.fieldID] ?? $0.fieldID, ascending: $0.ascending) }
        filter = filter?.remapped(map)
        stackFieldID = m(stackFieldID)
        coverFieldID = m(coverFieldID)
        dateFieldID = m(dateFieldID)
        endDateFieldID = m(endDateFieldID)
        colorFieldID = m(colorFieldID)
        if var f = form {
            f.fieldIDs = f.fieldIDs?.compactMap { map[$0] }
            f.requiredFieldIDs = f.requiredFieldIDs?.compactMap { map[$0] }
            form = f
        }
        if var c = chart {
            c.categoryFieldID = m(c.categoryFieldID)
            c.valueFieldID = m(c.valueFieldID)
            chart = c
        }
    }
}

extension FilterGroup {
    func remapped(_ map: [String: String]) -> FilterGroup {
        var copy = self
        copy.conditions = conditions.map { c in
            var c = c
            c.fieldID = map[c.fieldID] ?? c.fieldID
            return c
        }
        copy.groups = groups.map { $0.remapped(map) }
        return copy
    }
}
