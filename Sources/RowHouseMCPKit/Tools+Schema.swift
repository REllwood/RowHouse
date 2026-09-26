import Foundation
import RowHouseCore

extension Tools {
    // MARK: - Bases

    static let listBases = Tool(
        name: "list_bases",
        title: "List bases",
        description: "Lists every RowHouse base with its tables and how many records each table has. Start here.",
        inputSchema: Schema.object([:]),
        effect: .readOnly
    ) { _, ws in
        .object(["bases": .array(try await ws.allSessions().map(baseSummary))])
    }

    static let getBaseSchema = Tool(
        name: "get_base_schema",
        title: "Get base schema",
        description: "Describes a base: its tables, each table's fields (type, options such as select choices, linked table, formula) with the primary field marked, and its views. Read this before working with records.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": Schema.string("Only describe this table (id or name). Default: every table."),
        ], required: ["base"]),
        effect: .readOnly
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let doc = session.document
        let tables = try args.optionalString("table").map { key throws(ToolError) in [try lookup.table(key)] } ?? doc.tables
        var out: [String: JSONValue] = [
            "id": .string(session.entry.baseID),
            "name": .string(doc.info.name),
            "tables": .array(tables.map { tableSchema($0, in: doc) }),
        ]
        if !doc.info.description.isEmpty { out["description"] = .string(doc.info.description) }
        return .object(out)
    }

    static let createBase = Tool(
        name: "create_base",
        title: "Create base",
        description: "Creates a new base, empty (one table) or from a template with sample data, views and automations. Returns its tables.",
        inputSchema: Schema.object([
            "name": Schema.string("Name of the new base."),
            "template": Schema.string(
                "Starting point: " + BaseTemplate.allCases.map { "\($0.rawValue) (\($0.summary.dropLast()))" }.joined(separator: "; ") + ". Default: blank.",
                enumerated: BaseTemplate.allCases.map(\.rawValue)
            ),
        ], required: ["name"]),
        effect: .additive
    ) { args, ws in
        let name = try args.string("name")
        var template = BaseTemplate.blank
        if let raw = try args.optionalString("template") {
            let folded = raw.lowercased().filter { $0.isLetter }
            guard let match = BaseTemplate.allCases.first(where: { $0.rawValue.lowercased() == folded || $0.name.lowercased().filter(\.isLetter) == folded }) else {
                throw ToolError("Unknown template \(raw). Templates: \(BaseTemplate.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            template = match
        }
        _ = try ws.entries()
        let entry: LibraryEntry
        do {
            entry = try ws.library.createPackage(named: name)
        } catch {
            throw ToolError("Couldn't create the base in \(ws.library.rootURL.path): \(error.localizedDescription)")
        }
        let session = await AgentSession.open(entry: entry, deviceID: ws.agent.deviceID, deviceName: ws.deviceName)
        session.document.apply(template: template, storage: session.storage)
        session.document.updateBaseInfo(name: name)
        try session.flush()
        session.writeSnapshot()
        ws.adopt(session)
        return baseSummary(session)
    }

    // MARK: - Tables

    static let createTable = Tool(
        name: "create_table",
        title: "Create table",
        description: """
            Creates a table. The first field listed becomes the primary field (the record's name; it can't be a checkbox, link, attachment, multiple select, rating, lookup, rollup, count or button). Without fields the table gets a single text field called Name. Fields may refer to each other (formulas, lookups of a link field in the same list). Returns the new table's schema.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "name": Schema.string("Table name; must be unique in the base."),
            "description": Schema.string("What the table holds."),
            "fields": Schema.array(fieldSpecSchema, "Fields to create, in order. The first is the primary field."),
        ], required: ["base", "name"]),
        effect: .additive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let doc = session.document
        let name = try args.string("name")
        if let existing = doc.table(named: name) { throw ToolError("A table named \(existing.name) already exists in \(doc.info.name)") }
        let description = try args.optionalText("description")
        let specs = try fieldSpecs(try args.array("fields") ?? [])

        // Check everything that doesn't depend on the new fields before creating anything.
        for (i, spec) in specs.enumerated() {
            if i == 0 && !spec.type.canBePrimary {
                throw ToolError("\(spec.name) can't be the primary field: \(spec.type.displayName) fields can't be primary. List a text, number, date, single select or formula field first.")
            }
            let target = FieldOptionsCoding.Target(tableID: nil, tableName: name, fieldID: nil, fieldName: spec.name)
            _ = try FieldOptionsCoding.apply(spec.options, to: FieldOptions(), type: spec.type, target: target, document: doc, resolveReferences: false)
        }

        let tableID = doc.createTable(name: name, starterFields: false, emptyRecords: 0)
        do {
            if let description, !description.isEmpty { doc.updateTableDescription(tableID, description) }
            try createFields(specs, in: tableID, tableName: name, document: doc, replacingPrimary: true)
        } catch {
            discardTable(tableID, in: doc)
            try? session.flush()
            throw error
        }
        try session.flush()
        guard let table = doc.table(tableID) else { throw ToolError("The table couldn't be created") }
        return tableSchema(table, in: doc)
    }

    static let updateTable = Tool(
        name: "update_table",
        title: "Update table",
        description: "Renames a table or changes its description.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "name": Schema.string("New name; must be unique in the base."),
            "description": Schema.string("New description (empty string clears it)."),
        ], required: ["base", "table"]),
        effect: .destructive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let doc = session.document
        let table = try BaseLookup(session: session).table(try args.string("table"))
        let name = try args.optionalString("name")
        let description = try args.optionalText("description")
        guard name != nil || description != nil else { throw ToolError("Pass a new name or description") }
        if let name {
            if let other = doc.table(named: name), other.id != table.id { throw ToolError("A table named \(other.name) already exists in \(doc.info.name)") }
            doc.renameTable(table.id, to: name)
        }
        if let description { doc.updateTableDescription(table.id, description) }
        try session.flush()
        return tableSchema(doc.table(table.id) ?? table, in: doc)
    }

    // MARK: - Fields

    static let fieldSpecSchema = Schema.object([
        "name": Schema.string("Field name."),
        "type": Schema.string("Field type, e.g. singleLineText, number, singleSelect, date, link, formula. See describe_field_types.", enumerated: FieldType.allCases.map(\.rawValue)),
        "options": Schema.freeObject("Type-specific options, e.g. {\"choices\": [\"Todo\", \"Done\"]}, {\"linked_table\": \"Projects\"}, {\"formula\": \"{Price} * {Qty}\"}, {\"precision\": 2}. See describe_field_types."),
        "description": Schema.string("What the field is for."),
    ], required: ["name", "type"])

    static let createField = Tool(
        name: "create_field",
        title: "Create field",
        description: """
            Adds a field to a table. Options depend on the type (describe_field_types lists them), for example choices for selects, linked_table for links (a paired field is added to the linked table), link_field and target_field for lookups and rollups, formula for formulas. Returns the new field.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "name": Schema.string("Field name; must be unique in the table."),
            "type": Schema.string("Field type, e.g. singleLineText, number, singleSelect, date, link, formula. See describe_field_types.", enumerated: FieldType.allCases.map(\.rawValue)),
            "options": Schema.freeObject("Type-specific options. See describe_field_types."),
            "description": Schema.string("What the field is for."),
        ], required: ["base", "table", "name", "type"]),
        effect: .additive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let doc = session.document
        let table = try BaseLookup(session: session).table(try args.string("table"))
        var spec: [String: JSONValue] = ["name": .string(try args.string("name")), "type": .string(try args.string("type"))]
        if let options = try args.object("options") { spec["options"] = .object(options) }
        if let description = try args.optionalText("description") { spec["description"] = .string(description) }
        guard let parsed = try fieldSpecs([.object(spec)], existing: doc.fields(in: table.id)).first else { throw ToolError("Pass a field name and type") }
        // Every option, including ones naming other fields, is resolved before the field is created.
        let target = FieldOptionsCoding.Target(tableID: table.id, tableName: table.name, fieldID: nil, fieldName: parsed.name)
        let options = try FieldOptionsCoding.apply(parsed.options, to: FieldOptions(), type: parsed.type, target: target, document: doc, resolveReferences: true)
        let id = doc.createField(in: table.id, name: parsed.name, type: parsed.type, options: options, description: parsed.description ?? "")
        try session.flush()
        guard let field = doc.field(id) else { throw ToolError("The field couldn't be created") }
        return fieldSchema(field, in: doc)
    }

    static let updateField = Tool(
        name: "update_field",
        title: "Update field",
        description: """
            Renames a field, changes its description or changes its options (for example the choices of a select, a formula, precision). Options not mentioned keep their values; choices replaces the whole list, keeping existing options that are listed by name. The type can't be changed here.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "field": Schema.string("Field id or name."),
            "name": Schema.string("New name; must be unique in the table."),
            "description": Schema.string("New description (empty string clears it)."),
            "options": Schema.freeObject("Options to change. See describe_field_types."),
        ], required: ["base", "table", "field"]),
        effect: .destructive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let doc = session.document
        let lookup = BaseLookup(session: session)
        let table = try lookup.table(try args.string("table"))
        let field = try lookup.field(try args.string("field"), in: table)
        let name = try args.optionalString("name")
        let description = try args.optionalText("description")
        let rawOptions = try args.object("options")
        guard name != nil || description != nil || rawOptions != nil else { throw ToolError("Pass a new name, description or options") }
        if let name, let other = doc.field(named: name, in: table.id), other.id != field.id {
            throw ToolError("A field named \(other.name) already exists in \(table.name)")
        }
        var options: FieldOptions?
        if let rawOptions {
            let normalized = try FieldOptionsCoding.normalize(rawOptions, for: field.type, fieldName: field.name)
            if field.isInverseLink, normalized["linked_table"] != nil || normalized["single_record"] != nil {
                let owner = doc.field(field.options.inverseFieldID)?.name ?? "the paired field"
                throw ToolError("\(field.name) is the paired side of \(owner); change the link on \(owner) instead")
            }
            let target = FieldOptionsCoding.Target(tableID: table.id, tableName: table.name, fieldID: field.id, fieldName: field.name)
            options = try FieldOptionsCoding.apply(normalized, to: field.options, type: field.type, target: target, document: doc, resolveReferences: true)
        }
        doc.updateField(field.id, name: name, options: options, description: description)
        try session.flush()
        return fieldSchema(doc.field(field.id) ?? field, in: doc)
    }

    // MARK: - Field creation

    struct FieldSpec {
        var name: String
        var type: FieldType
        var options: [String: JSONValue]
        var description: String?
    }

    /// Parses and checks field definitions: names present and unique (among themselves and against
    /// `existing`), known types and options, required options present.
    static func fieldSpecs(_ items: [JSONValue], existing: [FieldModel] = []) throws(ToolError) -> [FieldSpec] {
        var specs: [FieldSpec] = []
        var names = Set(existing.map { $0.name.lowercased() })
        for (i, item) in items.enumerated() {
            guard let object = item.objectValue else { throw ToolError("Field \(i + 1) must be an object like {\"name\": \"Status\", \"type\": \"singleSelect\"}") }
            let extra = object.keys.filter { !["name", "type", "options", "description"].contains($0) }.sorted()
            if !extra.isEmpty { throw ToolError("Field \(i + 1) has unexpected keys \(extra.joined(separator: ", ")); use name, type, options and description") }
            guard let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw ToolError("Field \(i + 1) needs a name")
            }
            guard names.insert(name.lowercased()).inserted else { throw ToolError("There's already a field named \(name)") }
            guard let rawType = object["type"]?.stringValue else { throw ToolError("\(name) needs a type") }
            let (type, implied) = try fieldType(rawType)
            var rawOptions = implied
            if let options = object["options"], !options.isNull {
                guard let dict = options.objectValue else { throw ToolError("\(name): options must be an object") }
                rawOptions.merge(dict) { _, given in given }
            }
            let options = try FieldOptionsCoding.normalize(rawOptions, for: type, fieldName: name)
            let missing = FieldOptionsCoding.missingRequired(options, for: type)
            if !missing.isEmpty { throw ToolError("\(name) (\(type.displayName)) needs the option\(missing.count == 1 ? "" : "s") \(missing.joined(separator: ", "))") }
            var description: String?
            if let d = object["description"], !d.isNull {
                guard let text = d.stringValue else { throw ToolError("\(name): description must be a string") }
                description = text
            }
            specs.append(FieldSpec(name: name, type: type, options: options, description: description))
        }
        return specs
    }

    /// Creates fields in order, then fills in options that name other fields once they all exist.
    /// With `replacingPrimary` the first spec reshapes the table's existing primary field.
    @discardableResult
    static func createFields(_ specs: [FieldSpec], in tableID: String, tableName: String, document doc: BaseDocument, replacingPrimary: Bool) throws(ToolError) -> [String] {
        var created: [(FieldSpec, String)] = []
        for (i, spec) in specs.enumerated() {
            let primaryID = replacingPrimary && i == 0 ? doc.primaryField(of: tableID)?.id : nil
            let target = FieldOptionsCoding.Target(tableID: tableID, tableName: tableName, fieldID: primaryID, fieldName: spec.name)
            let options = try FieldOptionsCoding.apply(spec.options, to: FieldOptions(), type: spec.type, target: target, document: doc, resolveReferences: false)
            if let primaryID {
                doc.updateField(primaryID, name: spec.name, type: spec.type, options: options, description: spec.description)
                created.append((spec, primaryID))
            } else {
                created.append((spec, doc.createField(in: tableID, name: spec.name, type: spec.type, options: options, description: spec.description ?? "")))
            }
        }
        for (spec, id) in created where !FieldOptionsCoding.referenceKeys.isDisjoint(with: spec.options.keys) {
            guard let field = doc.field(id) else { continue }
            let target = FieldOptionsCoding.Target(tableID: tableID, tableName: tableName, fieldID: id, fieldName: spec.name)
            let options = try FieldOptionsCoding.apply(spec.options, to: field.options, type: spec.type, target: target, document: doc, resolveReferences: true)
            doc.updateField(id, options: options)
        }
        return created.map(\.1)
    }

    /// Removes a table created by a call that then failed, with its fields, views and the paired
    /// link fields it added to other tables.
    static func discardTable(_ tableID: String, in doc: BaseDocument) {
        var mutations = [Mutation(.table, tableID, ["_deleted": true])]
        for table in doc.tables {
            for field in doc.fields(in: table.id) where field.tableID == tableID || (field.type == .link && field.options.linkedTableID == tableID) {
                mutations.append(Mutation(.field, field.id, ["_deleted": true]))
            }
        }
        for view in doc.views(in: tableID) { mutations.append(Mutation(.view, view.id, ["_deleted": true])) }
        doc.commit(mutations, actionName: "Delete Table")
    }

    // MARK: - Field types

    static let describeFieldTypes = Tool(
        name: "describe_field_types",
        title: "Describe field types",
        description: "Explains every field type: how its values appear in records, what create_records / update_records accept, and which options create_field takes.",
        inputSchema: Schema.object([:]),
        effect: .readOnly
    ) { _, _ in
        FieldTypeGuide.all()
    }
}
