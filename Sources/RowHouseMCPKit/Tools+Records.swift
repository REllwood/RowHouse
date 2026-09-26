import Foundation
import RowHouseCore

extension Tools {
    // MARK: - list_records

    static let listRecords = Tool(
        name: "list_records",
        title: "List records",
        description: """
            Lists records of a table, oldest first unless sorted. Optionally applies a view's filters and sort, an Airtable-style filter_formula, a text search and your own sort, then returns one page. Each record is {id, createdTime, fields}; fields are keyed by field name and empty fields are left out. When more records remain the result includes offset: pass it back to get the next page.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "view": Schema.string("View id or name. Only records the view shows are returned, in the view's order."),
            "fields": Schema.array(Schema.string("Field name or id"), "Only return these fields (names or ids). Default: all fields."),
            "filter_formula": Schema.string("Airtable formula; records where it is truthy are kept, e.g. AND({Status} = \"Done\", {Qty} > 3) or FIND(\"acme\", LOWER({Company})). Field names go in braces."),
            "search": Schema.string("Only records where some field contains this text (case-insensitive)."),
            "sort": Schema.array(
                Schema.object([
                    "field": Schema.string("Field name or id"),
                    "direction": Schema.string("asc (default) or desc", enumerated: ["asc", "desc"]),
                ], required: ["field"]),
                "Sort order, most significant first. Replaces the view's sort. Empty values sort last."
            ),
            "max_records": Schema.integer("Records per page.", minimum: 1, maximum: 1000, default: 100),
            "offset": Schema.integer("Number of records to skip; use the offset returned by the previous page.", minimum: 0, default: 0),
        ], required: ["base", "table"]),
        effect: .readOnly
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let doc = session.document
        let table = try lookup.table(try args.string("table"))
        let maxRecords = try args.int("max_records", default: 100, range: 1...1000)
        let offset = try args.int("offset", default: 0, range: 0...Int(Int32.max))
        let outputFields = try args.stringArray("fields")?.map { key throws(ToolError) in try lookup.field(key, in: table) }

        var records: [RecordModel]
        if let viewKey = try args.optionalString("view") {
            let view = try lookup.view(viewKey, in: table)
            records = doc.evaluate(view: view).recordIDs.compactMap { doc.record($0) }
        } else {
            records = doc.records(in: table.id)
        }
        if let formula = try args.optionalString("filter_formula") {
            records = try filter(records, formula: formula, table: table, doc: doc)
        }
        if let query = try args.optionalString("search") {
            let fields = doc.fields(in: table.id)
            records = records.filter { r in fields.contains { doc.displayString(r, $0).localizedCaseInsensitiveContains(query) } }
        }
        if let sort = try args.array("sort") {
            records = try sorted(records, by: sort, table: table, lookup: lookup)
        }

        let total = records.count
        let page = offset < total ? Array(records[offset..<min(total, offset + maxRecords)]) : []
        let coding = coding(session)
        var result: [String: JSONValue] = [
            "records": .array(page.map { recordJSON($0, coding: coding, fields: outputFields) }),
            "total": .number(Double(total)),
        ]
        if offset + page.count < total { result["offset"] = .number(Double(offset + page.count)) }
        return .object(result)
    }

    static func filter(_ records: [RecordModel], formula: String, table: TableModel, doc: BaseDocument) throws(ToolError) -> [RecordModel] {
        do {
            return try doc.compute.filter(records, formula: formula, tableID: table.id)
        } catch {
            let names = doc.fields(in: table.id).map(\.name).joined(separator: ", ")
            throw ToolError("filter_formula: \(error.message). Refer to fields by name in braces, e.g. {Status}. Fields in \(table.name): \(names)")
        }
    }

    private static func sorted(_ records: [RecordModel], by specs: [JSONValue], table: TableModel, lookup: BaseLookup) throws(ToolError) -> [RecordModel] {
        var keys: [(field: FieldModel, ascending: Bool)] = []
        for spec in specs {
            if let name = spec.stringValue {
                keys.append((try lookup.field(name, in: table), true))
                continue
            }
            guard let name = spec["field"]?.stringValue else { throw ToolError("Each sort entry needs a field, e.g. {\"field\": \"Due\", \"direction\": \"desc\"}") }
            let direction = spec["direction"]?.stringValue?.lowercased() ?? "asc"
            guard direction == "asc" || direction == "desc" else { throw ToolError("Sort direction must be asc or desc") }
            keys.append((try lookup.field(name, in: table), direction == "asc"))
        }
        let doc = lookup.document
        let decorated = records.map { r in (r, keys.map { doc.value(r, $0.field) }) }
        return decorated.enumerated().sorted { lhs, rhs in
            for (i, key) in keys.enumerated() {
                let a = lhs.element.1[i], b = rhs.element.1[i]
                let aEmpty = a.isEmpty && key.field.type != .checkbox
                let bEmpty = b.isEmpty && key.field.type != .checkbox
                if aEmpty != bEmpty { return bEmpty }
                let order = CellComparison.compare(a, b, field: key.field)
                if order != .orderedSame { return key.ascending ? order == .orderedAscending : order == .orderedDescending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element.0)
    }

    // MARK: - get_record

    static let getRecord = Tool(
        name: "get_record",
        title: "Get record",
        description: "Gets one record with every field (empty fields as null), its table and its comment count.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "record_id": Schema.string("Record id (rec…), or the record's primary field value when table is given."),
            "table": Schema.string("Table id or name. Optional; needed to look a record up by its primary field value."),
        ], required: ["base", "record_id"]),
        effect: .readOnly
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let table = try args.optionalString("table").map { key throws(ToolError) in try lookup.table(key) }
        let record = try lookup.record(try args.string("record_id"), in: table)
        let doc = session.document
        guard case .object(var json) = recordJSON(record, coding: coding(session), includeEmpty: true) else { return .null }
        json["table"] = .string(doc.table(record.tableID)?.name ?? "")
        json["tableId"] = .string(record.tableID)
        json["commentCount"] = .number(Double(doc.commentCount(for: record.id)))
        return .object(json)
    }

    // MARK: - search_records

    static let searchRecords = Tool(
        name: "search_records",
        title: "Search records",
        description: "Finds records containing some text (case-insensitive) in any field, across every table of a base or in one table. Results say which table each record is in and which fields matched.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "query": Schema.string("Text to look for."),
            "table": Schema.string("Table id or name to search. Default: every table."),
            "max_records": Schema.integer("Maximum number of results.", minimum: 1, maximum: 1000, default: 100),
        ], required: ["base", "query"]),
        effect: .readOnly
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let doc = session.document
        let query = try args.string("query")
        let maxRecords = try args.int("max_records", default: 100, range: 1...1000)
        let tables = try args.optionalString("table").map { key throws(ToolError) in [try lookup.table(key)] } ?? doc.tables
        let coding = coding(session)
        var results: [JSONValue] = []
        var total = 0
        for table in tables {
            let fields = doc.fields(in: table.id)
            for record in doc.records(in: table.id) {
                let matched = fields.filter { doc.displayString(record, $0).localizedCaseInsensitiveContains(query) }
                guard !matched.isEmpty else { continue }
                total += 1
                guard results.count < maxRecords, case .object(var json) = recordJSON(record, coding: coding) else { continue }
                json["table"] = .string(table.name)
                json["tableId"] = .string(table.id)
                json["matchedFields"] = .array(matched.map { .string($0.name) })
                results.append(.object(json))
            }
        }
        return .object(["records": .array(results), "total": .number(Double(total))])
    }

    // MARK: - create_records

    static let createRecords = Tool(
        name: "create_records",
        title: "Create records",
        description: """
            Creates up to 100 records in a table and returns them. Each record is {"fields": {"Field name": value}}; see describe_field_types for value formats. Links take record ids or primary field values of existing records. All records are checked first, so if one is invalid nothing is created.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "records": Schema.array(
                Schema.object(["fields": Schema.freeObject("Values keyed by field name or id.")], required: ["fields"]),
                "Records to create.", minItems: 1, maxItems: maxRecordsPerWrite
            ),
            "typecast": typecastArgument,
        ], required: ["base", "table", "records"]),
        effect: .additive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let table = try BaseLookup(session: session).table(try args.string("table"))
        let items = try recordItems(try args.array("records"), requireID: false)
        let coding = coding(session, typecast: try args.bool("typecast", default: false))
        let ids = try coding.createRecords(items.map(\.fields), in: table.id)
        session.flush()
        let doc = session.document
        return .object(["records": .array(ids.compactMap { doc.record($0) }.map { recordJSON($0, coding: coding) })])
    }

    private static func recordItems(_ items: [JSONValue]?, requireID: Bool) throws(ToolError) -> [(id: String, fields: [String: JSONValue])] {
        guard let items, !items.isEmpty else { throw ToolError("records must list at least one record") }
        guard items.count <= maxRecordsPerWrite else { throw ToolError("At most \(maxRecordsPerWrite) records per call; split the rest into more calls") }
        let shape = requireID ? "{\"id\": \"rec…\", \"fields\": {…}}" : "{\"fields\": {…}}"
        var out: [(id: String, fields: [String: JSONValue])] = []
        for (i, item) in items.enumerated() {
            guard let object = item.objectValue, let fields = object["fields"]?.objectValue else {
                throw ToolError("Record \(i + 1) must look like \(shape)")
            }
            let extra = object.keys.filter { $0 != "fields" && $0 != "id" }.sorted()
            if !extra.isEmpty { throw ToolError("Record \(i + 1) has unexpected keys \(extra.joined(separator: ", ")); it must look like \(shape)") }
            var id = ""
            if requireID {
                guard let given = object["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !given.isEmpty else {
                    throw ToolError("Record \(i + 1) needs an id")
                }
                id = given
            }
            out.append((id, fields))
        }
        return out
    }

    // MARK: - update_records

    static let updateRecords = Tool(
        name: "update_records",
        title: "Update records",
        description: """
            Updates up to 100 records of a table and returns them. Each entry is {"id": "rec…", "fields": {…}}; only the fields listed change (pass null to clear one). The id may also be the record's primary field value. All updates are checked first, so if one is invalid nothing changes.
            """,
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "records": Schema.array(
                Schema.object([
                    "id": Schema.string("Record id (rec…) or primary field value."),
                    "fields": Schema.freeObject("Values to change, keyed by field name or id."),
                ], required: ["id", "fields"]),
                "Records to update.", minItems: 1, maxItems: maxRecordsPerWrite
            ),
            "typecast": typecastArgument,
        ], required: ["base", "table", "records"]),
        effect: .additive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let table = try lookup.table(try args.string("table"))
        var updates = try recordItems(try args.array("records"), requireID: true)
        for i in updates.indices { updates[i].id = try lookup.record(updates[i].id, in: table).id }
        let coding = coding(session, typecast: try args.bool("typecast", default: false))
        try coding.updateRecords(updates, in: table.id)
        session.flush()
        let doc = session.document
        var seen = Set<String>()
        let ids = updates.map(\.id).filter { seen.insert($0).inserted }
        return .object(["records": .array(ids.compactMap { doc.record($0) }.map { recordJSON($0, coding: coding) })])
    }

    // MARK: - delete_records

    static let deleteRecords = Tool(
        name: "delete_records",
        title: "Delete records",
        description: "Deletes up to 100 records of a table. Every id is checked first, so if one doesn't exist nothing is deleted. Deleted records can't be restored from here; confirm with the user first.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "table": tableArgument,
            "record_ids": Schema.array(Schema.string("Record id (rec…)"), "Records to delete.", minItems: 1, maxItems: maxRecordsPerWrite),
        ], required: ["base", "table", "record_ids"]),
        effect: .destructive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let table = try lookup.table(try args.string("table"))
        guard let keys = try args.stringArray("record_ids"), !keys.isEmpty else { throw ToolError("record_ids must list at least one record") }
        guard keys.count <= maxRecordsPerWrite else { throw ToolError("At most \(maxRecordsPerWrite) records per call; split the rest into more calls") }
        var seen = Set<String>()
        let ids = try lookup.records(keys, in: table).map(\.id).filter { seen.insert($0).inserted }
        session.document.deleteRecords(ids)
        session.flush()
        return .object(["records": .array(ids.map { .object(["id": .string($0), "deleted": true]) })])
    }

    // MARK: - Comments

    static let listComments = Tool(
        name: "list_comments",
        title: "List comments",
        description: "Lists the comments on a record, oldest first.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "record_id": Schema.string("Record id (rec…), or primary field value when table is given."),
            "table": Schema.string("Table id or name. Optional."),
        ], required: ["base", "record_id"]),
        effect: .readOnly
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let table = try args.optionalString("table").map { key throws(ToolError) in try lookup.table(key) }
        let record = try lookup.record(try args.string("record_id"), in: table)
        let doc = session.document
        return .object([
            "record": .object(["id": .string(record.id), "name": .string(doc.primaryTitle(record))]),
            "comments": .array(doc.comments(for: record.id).map(commentJSON)),
        ])
    }

    static let addComment = Tool(
        name: "add_comment",
        title: "Add comment",
        description: "Adds a comment to a record. It shows in the record's comment thread in RowHouse, signed with this assistant's name.",
        inputSchema: Schema.object([
            "base": baseArgument,
            "record_id": Schema.string("Record id (rec…), or primary field value when table is given."),
            "text": Schema.string("The comment."),
            "table": Schema.string("Table id or name. Optional."),
        ], required: ["base", "record_id", "text"]),
        effect: .additive
    ) { args, ws in
        let session = try await ws.base(try args.string("base"))
        let lookup = BaseLookup(session: session)
        let table = try args.optionalString("table").map { key throws(ToolError) in try lookup.table(key) }
        let record = try lookup.record(try args.string("record_id"), in: table)
        let text = try args.string("text")
        let doc = session.document
        doc.addComment(to: record.id, text: text)
        session.flush()
        guard let comment = doc.comments(for: record.id).last(where: { $0.authorDeviceID == doc.deviceID }) else {
            throw ToolError("The comment couldn't be added")
        }
        return .object(["comment": commentJSON(comment), "recordId": .string(record.id)])
    }

    static func commentJSON(_ comment: CommentModel) -> JSONValue {
        .object([
            "id": .string(comment.id),
            "author": .string(comment.authorName),
            "text": .string(comment.text),
            "createdTime": iso(comment.createdTime),
        ])
    }
}
