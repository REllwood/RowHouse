import Foundation
import RowHouseCore
import Testing
@testable import RowHouseMCPKit

@Suite("MCP tools", .serialized) @MainActor
struct MCPToolTests {
    /// A base with a Tasks table: Task (primary), Qty, Status, Due, Tags, Double (formula).
    func harnessWithTasks() async -> MCPHarness {
        let h = MCPHarness()
        _ = await h.initialize()
        _ = await h.call("create_base", ["name": "Work"])
        _ = await h.call("create_table", [
            "base": "Work",
            "name": "Tasks",
            "description": "Things to do",
            "fields": [
                ["name": "Task", "type": "singleLineText"],
                ["name": "Double", "type": "formula", "options": ["formula": "{Qty} * 2"]],
                ["name": "Qty", "type": "number", "options": ["precision": 0]],
                ["name": "Status", "type": "singleSelect", "options": ["choices": ["Todo", ["name": "Done", "color": "green"]]]],
                ["name": "Due", "type": "date"],
                ["name": "Tags", "type": "multipleSelects", "options": ["choices": ["red", "blue"]]],
            ],
        ])
        return h
    }

    func fieldNames(_ records: JSONValue?, _ field: String) -> [String] {
        (records?.arrayValue ?? []).map { $0["fields"]?[field]?.stringValue ?? "" }
    }

    @Test func recordsCanBeCreatedListedUpdatedAndDeleted() async {
        let h = await harnessWithTasks()
        defer { h.cleanUp() }

        let created = await h.call("create_records", [
            "base": "work",
            "table": "tasks",
            "records": [
                ["fields": ["Task": "Write spec", "Qty": 3, "Status": "Todo", "Due": "2026-10-01", "Tags": ["red"]]],
                ["fields": ["Task": "Review", "Qty": 8, "Status": "Done", "Due": "2026-09-20"]],
                ["fields": ["Task": "Ship", "Qty": 5, "Status": "Todo"]],
                ["fields": ["Task": "Celebrate", "Qty": 1]],
            ],
        ])
        let records = created["records"]?.arrayValue ?? []
        #expect(records.count == 4)
        #expect(records.first?["id"]?.stringValue?.hasPrefix("rec") == true)
        #expect(records.first?["createdTime"]?.stringValue.flatMap(DateCoding.parseISO) != nil)
        #expect(records.first?["fields"] == ["Task": "Write spec", "Qty": 3, "Double": 6, "Status": "Todo", "Due": "2026-10-01", "Tags": ["red"]])
        let ids = records.compactMap { $0["id"]?.stringValue }

        let todo = await h.call("list_records", ["base": "Work", "table": "Tasks", "filter_formula": "{Status} = \"Todo\""])
        #expect(fieldNames(todo["records"], "Task") == ["Write spec", "Ship"])
        #expect(todo["total"] == 2)
        #expect(todo["offset"] == nil)

        let sorted = await h.call("list_records", ["base": "Work", "table": "Tasks", "sort": [["field": "Qty", "direction": "desc"]], "fields": ["Task"]])
        #expect(fieldNames(sorted["records"], "Task") == ["Review", "Ship", "Write spec", "Celebrate"])
        #expect(sorted["records"]?.arrayValue?.first?["fields"]?.objectValue?.keys.sorted() == ["Task"])

        let byDue = await h.call("list_records", ["base": "Work", "table": "Tasks", "sort": [["field": "Due"]]])
        #expect(fieldNames(byDue["records"], "Task") == ["Review", "Write spec", "Ship", "Celebrate"])

        let page1 = await h.call("list_records", ["base": "Work", "table": "Tasks", "max_records": 3])
        #expect(fieldNames(page1["records"], "Task") == ["Write spec", "Review", "Ship"])
        #expect(page1["offset"] == 3)
        let page2 = await h.call("list_records", ["base": "Work", "table": "Tasks", "max_records": 3, "offset": 3])
        #expect(fieldNames(page2["records"], "Task") == ["Celebrate"])
        #expect(page2["offset"] == nil)

        let searched = await h.call("list_records", ["base": "Work", "table": "Tasks", "search": "REVIEW"])
        #expect(fieldNames(searched["records"], "Task") == ["Review"])

        let updated = await h.call("update_records", [
            "base": "Work",
            "table": "Tasks",
            "records": [
                ["id": .string(ids[0]), "fields": ["Status": "Done", "Tags": .null]],
                ["id": "Ship", "fields": ["Qty": "12"]],
            ],
        ])
        let first = updated["records"]?.arrayValue?.first?["fields"]
        #expect(first == ["Task": "Write spec", "Qty": 3, "Double": 6, "Status": "Done", "Due": "2026-10-01"])
        #expect(updated["records"]?.arrayValue?.last?["fields"]?["Double"] == 24)

        let deleted = await h.call("delete_records", ["base": "Work", "table": "Tasks", "record_ids": [.string(ids[1]), .string(ids[3])]])
        #expect(deleted["records"]?.arrayValue?.count == 2)
        let remaining = await h.call("list_records", ["base": "Work", "table": "Tasks"])
        #expect(fieldNames(remaining["records"], "Task") == ["Write spec", "Ship"])
    }

    @Test func invalidWritesChangeNothingAndExplainWhy() async {
        let h = await harnessWithTasks()
        defer { h.cleanUp() }
        let unknownOption = await h.callError("create_records", ["base": "Work", "table": "Tasks", "records": [
            ["fields": ["Task": "A"]],
            ["fields": ["Task": "B", "Status": "Blocked"]],
        ]])
        #expect(unknownOption.contains("Record 2: Blocked isn't an option of Status"))
        #expect(await h.call("list_records", ["base": "Work", "table": "Tasks"])["total"] == 0)

        let typecast = await h.call("create_records", ["base": "Work", "table": "Tasks", "typecast": true, "records": [["fields": ["Task": "B", "Status": "Blocked"]]]])
        #expect(typecast["records"]?.arrayValue?.first?["fields"]?["Status"] == "Blocked")

        let computed = await h.callError("create_records", ["base": "Work", "table": "Tasks", "records": [["fields": ["Double": 4]]]])
        #expect(computed.contains("computed"))
        let noTable = await h.callError("list_records", ["base": "Work", "table": "Projects"])
        #expect(noTable == "No table named Projects in base Work. Tables: Table 1, Tasks")
        let noField = await h.callError("create_records", ["base": "Work", "table": "Tasks", "records": [["fields": ["Owner": "Ada"]]]])
        #expect(noField.hasPrefix("No field named Owner in table Tasks. Fields: Task, Double, Qty"))
        let badShape = await h.callError("create_records", ["base": "Work", "table": "Tasks", "records": [["Task": "No wrapper"]]])
        #expect(badShape.contains("{\"fields\": {…}}"))
        let tooMany = await h.callError("create_records", ["base": "Work", "table": "Tasks", "records": .array(Array(repeating: ["fields": [:]], count: 101))])
        #expect(tooMany.contains("At most 100"))
        let badFormula = await h.callError("list_records", ["base": "Work", "table": "Tasks", "filter_formula": "{Nope} > 1"])
        #expect(badFormula.hasPrefix("filter_formula: Unknown field {Nope}"))
        let missingRecord = await h.callError("delete_records", ["base": "Work", "table": "Tasks", "record_ids": ["recDoesNotExist1"]])
        #expect(missingRecord.contains("No record recDoesNotExist1 in table Tasks"))
        let badPage = await h.callError("list_records", ["base": "Work", "table": "Tasks", "max_records": 5000])
        #expect(badPage == "max_records must be between 1 and 1000")
    }

    @Test func viewsSchemaAndRecordLookups() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        _ = await h.initialize()
        let base = await h.call("create_base", ["name": "Tracker", "template": "projectTracker"])
        #expect(base["tables"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Team", "Projects", "Tasks"])

        let schema = await h.call("get_base_schema", ["base": "Tracker", "table": "Tasks"])
        let tasks = schema["tables"]?.arrayValue?.first
        #expect(tasks?["primaryField"] == "Task")
        let fields = tasks?["fields"]?.arrayValue ?? []
        let status = fields.first { $0["name"] == "Status" }
        #expect(status?["type"] == "singleSelect")
        #expect((status?["options"]?["choices"]?.arrayValue?.count ?? 0) > 1)
        let project = fields.first { $0["name"] == "Project" }
        #expect(project?["options"]?["linked_table"] == "Projects")
        #expect(fields.first?["primary"] == true)
        let views = tasks?["views"]?.arrayValue ?? []
        #expect(!views.isEmpty)

        // A view's filters and order are applied.
        for view in views {
            guard let name = view["name"]?.stringValue else { continue }
            let listed = await h.call("list_records", ["base": "Tracker", "table": "Tasks", "view": .string(name), "max_records": 1000])
            #expect(listed["total"]?.numberValue != nil)
        }

        let some = await h.call("list_records", ["base": "Tracker", "table": "Tasks", "max_records": 1])
        let firstID = some["records"]?.arrayValue?.first?["id"]?.stringValue ?? ""
        let title = some["records"]?.arrayValue?.first?["fields"]?["Task"]?.stringValue ?? ""
        let record = await h.call("get_record", ["base": "Tracker", "record_id": .string(firstID)])
        #expect(record["table"] == "Tasks")
        #expect(record["fields"]?.objectValue?.count == fields.count)
        let byTitle = await h.call("get_record", ["base": "Tracker", "table": "Tasks", "record_id": .string(title)])
        #expect(byTitle["id"]?.stringValue == firstID)

        let found = await h.call("search_records", ["base": "Tracker", "query": .string(String(title.prefix(5)).uppercased())])
        #expect(found["records"]?.arrayValue?.contains { $0["id"]?.stringValue == firstID } == true)
        #expect(found["records"]?.arrayValue?.first?["matchedFields"]?.arrayValue?.isEmpty == false)

        let guide = await h.call("describe_field_types")
        #expect(guide["fieldTypes"]?.arrayValue?.compactMap { $0["type"]?.stringValue } == FieldType.allCases.map(\.rawValue))
    }

    @Test func tablesAndFieldsCanBeBuiltAndChanged() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        _ = await h.initialize()
        _ = await h.call("create_base", ["name": "Shop"])
        _ = await h.call("create_table", ["base": "Shop", "name": "Suppliers", "fields": [["name": "Supplier", "type": "text"]]])
        let orders = await h.call("create_table", ["base": "Shop", "name": "Orders", "fields": [
            ["name": "Order", "type": "autoNumber"],
            ["name": "Items", "type": "rollup", "options": ["link_field": "Lines", "target_field": "Qty", "formula": "SUM(values)"]],
            ["name": "Lines", "type": "link", "options": ["linked_table": "Orders"]],
            ["name": "Qty", "type": "number"],
            ["name": "Supplier", "type": "link", "options": ["linked_table": "Suppliers", "single_record": true]],
            ["name": "Supplier name", "type": "lookup", "options": ["link_field": "Supplier", "target_field": "Supplier"]],
            ["name": "Line count", "type": "count", "options": ["link_field": "Lines"]],
            ["name": "Placed", "type": "dateTime"],
        ]])
        let fields = orders["fields"]?.arrayValue ?? []
        #expect(fields.compactMap { $0["name"]?.stringValue } == ["Order", "Items", "Lines", "Qty", "Supplier", "Supplier name", "Line count", "Placed"])
        #expect(fields.first { $0["name"] == "Items" }?["options"]?["link_field"] == "Lines")
        #expect(fields.first { $0["name"] == "Placed" }?["options"]?["include_time"] == true)
        #expect(fields.first { $0["name"] == "Supplier" }?["options"]?["single_record"] == true)

        let suppliers = await h.call("get_base_schema", ["base": "Shop", "table": "Suppliers"])
        #expect(suppliers["tables"]?.arrayValue?.first?["fields"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Supplier", "Orders"])

        _ = await h.call("create_records", ["base": "Shop", "table": "Suppliers", "records": [["fields": ["Supplier": "Acme"]]]])
        let lines = await h.call("create_records", ["base": "Shop", "table": "Orders", "records": [["fields": ["Qty": 2]], ["fields": ["Qty": 5]]]])
        let lineIDs = (lines["records"]?.arrayValue ?? []).compactMap { $0["id"] }
        let order = await h.call("create_records", ["base": "Shop", "table": "Orders", "records": [["fields": ["Lines": .array(lineIDs), "Supplier": "Acme", "Placed": "2026-09-26T09:00:00Z"]]]])
        let orderFields = order["records"]?.arrayValue?.first?["fields"]
        #expect(orderFields?["Items"] == 7)
        #expect(orderFields?["Line count"] == 2)
        #expect(orderFields?["Supplier name"] == ["Acme"])
        #expect(orderFields?["Order"] == 3)
        #expect(orderFields?["Placed"] == "2026-09-26T09:00:00.000Z")

        let rollback = await h.callError("create_table", ["base": "Shop", "name": "Broken", "fields": [
            ["name": "Name", "type": "text"],
            ["name": "Total", "type": "formula", "options": ["formula": "{Missing} + 1"]],
        ]])
        #expect(rollback.contains("Unknown field {Missing}"))
        let tables = await h.call("list_bases")
        #expect(tables["bases"]?.arrayValue?.first?["tables"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Table 1", "Suppliers", "Orders"])

        let primary = await h.callError("create_table", ["base": "Shop", "name": "Bad", "fields": [["name": "Done", "type": "checkbox"]]])
        #expect(primary.contains("can't be the primary field"))
        let duplicate = await h.callError("create_table", ["base": "Shop", "name": "orders"])
        #expect(duplicate.contains("already exists"))
        let badOption = await h.callError("create_field", ["base": "Shop", "table": "Orders", "name": "Price", "type": "currency", "options": ["colour": "red"]])
        #expect(badOption.contains("Unknown option colour"))
        let needsLink = await h.callError("create_field", ["base": "Shop", "table": "Orders", "name": "Other", "type": "link"])
        #expect(needsLink.contains("needs the option linked_table"))

        let status = await h.call("create_field", ["base": "Shop", "table": "Orders", "name": "Status", "type": "singleSelect", "description": "Where it is", "options": ["choices": ["New", "Sent"]]])
        let newID = status["options"]?["choices"]?.arrayValue?.first?["id"]
        #expect(status["description"] == "Where it is")
        let changed = await h.call("update_field", ["base": "Shop", "table": "Orders", "field": "Status", "name": "Stage", "options": ["choices": ["Sent", ["name": "new", "color": "purple"], "Returned"]]])
        let choices = changed["options"]?["choices"]?.arrayValue ?? []
        #expect(changed["name"] == "Stage")
        #expect(choices.compactMap { $0["name"]?.stringValue } == ["Sent", "new", "Returned"])
        #expect(choices[1]["id"] == newID)
        #expect(choices[1]["color"] == "purple")

        let formula = await h.call("create_field", ["base": "Shop", "table": "Orders", "name": "Twice", "type": "formula", "options": ["formula": "{Qty} * 2", "result_format": "number"]])
        #expect(formula["options"]?["formula"] == "{Qty} * 2")
        let renamed = await h.call("update_field", ["base": "Shop", "table": "Orders", "field": "Qty", "name": "Quantity"])
        #expect(renamed["name"] == "Quantity")
        let schema = await h.call("get_base_schema", ["base": "Shop", "table": "Orders"])
        let twice = schema["tables"]?.arrayValue?.first?["fields"]?.arrayValue?.first { $0["name"] == "Twice" }
        #expect(twice?["options"]?["formula"] == "{Quantity} * 2")

        let table = await h.call("update_table", ["base": "Shop", "table": "Orders", "name": "Purchase orders", "description": "Placed with suppliers"])
        #expect(table["name"] == "Purchase orders")
        #expect(table["description"] == "Placed with suppliers")
        let clash = await h.callError("update_table", ["base": "Shop", "table": "Purchase orders", "name": "suppliers"])
        #expect(clash.contains("already exists"))
    }

    @Test func edgeCasesAreReportedClearly() async {
        let h = await harnessWithTasks()
        defer { h.cleanUp() }
        let created = await h.call("create_records", ["base": "Work", "table": "Tasks", "records": [["fields": ["Task": "Only a name"]]]])
        let id = created["records"]?.arrayValue?.first?["id"] ?? .null
        let record = await h.call("get_record", ["base": "Work", "record_id": id])
        #expect(record["fields"]?["Qty"] == .null)
        #expect(record["fields"]?["Task"] == "Only a name")
        #expect(record["tableId"]?.stringValue?.hasPrefix("tbl") == true)
        #expect(record["commentCount"] == 0)

        let unknownField = await h.callError("list_records", ["base": "Work", "table": "Tasks", "fields": ["Task", "Owner"]])
        #expect(unknownField.hasPrefix("No field named Owner in table Tasks"))
        let badSort = await h.callError("list_records", ["base": "Work", "table": "Tasks", "sort": [["field": "Qty", "direction": "down"]]])
        #expect(badSort == "Sort direction must be asc or desc")
        let noChange = await h.callError("update_field", ["base": "Work", "table": "Tasks", "field": "Qty"])
        #expect(noChange == "Pass a new name, description or options")
        let wrongTable = await h.callError("update_records", ["base": "Work", "table": "Table 1", "records": [["id": id, "fields": ["Name": "x"]]]])
        #expect(wrongTable.contains("belongs to table Tasks"))

        _ = await h.call("create_field", ["base": "Work", "table": "Tasks", "name": "Area", "type": "link", "options": ["linked_table": "Table 1"]])
        let inverse = await h.callError("update_field", ["base": "Work", "table": "Table 1", "field": "Tasks", "options": ["linked_table": "Tasks"]])
        #expect(inverse.contains("paired side of Area"))
        let stringified = await h.call("update_records", ["base": "Work", "table": "Tasks", "records": .string("[{\"id\": \"Only a name\", \"fields\": {\"Qty\": 2}}]")])
        #expect(stringified["records"]?.arrayValue?.first?["fields"]?["Double"] == 4)

        _ = await h.call("create_records", ["base": "Work", "table": "Tasks", "records": [["fields": ["Task": "only a name"]], ["fields": ["Qty": 1]], ["fields": ["Qty": 2]]]])
        let exact = await h.call("get_record", ["base": "Work", "table": "Tasks", "record_id": "Only a name"])
        #expect(exact["id"] == id)
        let ambiguous = await h.callError("delete_records", ["base": "Work", "table": "Tasks", "record_ids": ["ONLY A NAME"]])
        #expect(ambiguous.hasPrefix("2 records are called ONLY A NAME"))
        let unnamed = await h.callError("update_records", ["base": "Work", "table": "Tasks", "records": [["id": "Unnamed record", "fields": ["Qty": 3]]]])
        #expect(unnamed.hasPrefix("2 records are called Unnamed record"))
    }

    @Test func commentsAreSignedByTheAssistant() async {
        let h = await harnessWithTasks()
        defer { h.cleanUp() }
        let created = await h.call("create_records", ["base": "Work", "table": "Tasks", "records": [["fields": ["Task": "Call Ada"]]]])
        let id = created["records"]?.arrayValue?.first?["id"] ?? .null
        let added = await h.call("add_comment", ["base": "Work", "record_id": id, "text": "  Left a voicemail  "])
        #expect(added["comment"]?["text"] == "Left a voicemail")
        #expect(added["comment"]?["author"] == "Claude Code (MCP)")
        _ = await h.call("add_comment", ["base": "Work", "table": "Tasks", "record_id": "Call Ada", "text": "Called back"])
        let listed = await h.call("list_comments", ["base": "Work", "record_id": id])
        #expect(Set(listed["comments"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []) == ["Left a voicemail", "Called back"])
        #expect(listed["record"]?["name"] == "Call Ada")
        let empty = await h.callError("add_comment", ["base": "Work", "record_id": id, "text": "   "])
        #expect(empty == "text can't be empty")
    }
}
