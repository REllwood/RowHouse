import Foundation
import Testing
@testable import RowHouseCore

@Suite("Collaborators")
@MainActor
struct CollaboratorTests {
    @Test func peopleCanBeAddedEditedAndRemoved() throws {
        let doc = TestSupport.document()
        let ada = try #require(doc.addPerson(name: "Ada Lovelace", email: "ada@example.com"))
        let grace = try #require(doc.addPerson(name: "", email: "grace@example.com"))
        #expect(doc.addPerson(name: "  ", email: "") == nil)
        #expect(doc.people.map(\.id) == [ada.id, grace.id])
        #expect(ada.initials == "AL")
        #expect(grace.displayName == "grace@example.com")
        #expect(grace.initials == "G")

        var edited = grace
        edited.name = " Grace Hopper "
        edited.color = .green
        doc.updatePerson(edited)
        #expect(doc.person(grace.id)?.name == "Grace Hopper")
        #expect(doc.person(grace.id)?.color == .green)
        #expect(doc.person(matching: "GRACE@example.com")?.id == grace.id)
        #expect(doc.person(matching: "ada lovelace")?.id == ada.id)

        doc.removePerson(ada.id)
        #expect(doc.people.map(\.id) == [grace.id])

        // People live in the base's mergeable state, so they reach other devices.
        let other = BaseDocument(baseID: doc.baseID, deviceID: "devB", deviceName: "B", state: doc.state)
        #expect(other.people == doc.people)
    }

    @Test func removingAPersonCanBeUndone() throws {
        let doc = TestSupport.document()
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        undo.beginUndoGrouping()
        let ada = try #require(doc.addPerson(name: "Ada"))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        doc.removePerson(ada.id)
        undo.endUndoGrouping()
        #expect(doc.people.isEmpty)
        undo.undo()
        #expect(doc.people.map(\.id) == [ada.id])
    }

    private func setUp() throws -> (BaseDocument, table: String, single: FieldModel, multi: FieldModel, ada: Person, grace: Person) {
        let doc = TestSupport.document()
        let ada = try #require(doc.addPerson(name: "Ada Lovelace", email: "ada@example.com"))
        let grace = try #require(doc.addPerson(name: "Grace Hopper", email: "grace@example.com"))
        let table = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        let single = doc.createField(in: table, name: "Owner", type: .collaborator)
        var options = FieldOptions()
        options.allowMultipleCollaborators = true
        let multi = doc.createField(in: table, name: "Reviewers", type: .collaborator, options: options)
        return (doc, table, try #require(doc.field(single)), try #require(doc.field(multi)), ada, grace)
    }

    @Test func textIsParsedByNameOrEmailAndDisplayedAsNames() throws {
        let (doc, table, single, multi, ada, grace) = try setUp()
        let r = doc.createRecord(in: table)
        doc.setCell(recordID: r, fieldID: single.id, text: "ada@example.com")
        doc.setCell(recordID: r, fieldID: multi.id, text: "grace hopper, Ada Lovelace")
        let record = try #require(doc.record(r))
        #expect(record[single.id] == .string(ada.id))
        #expect(record[multi.id] == .array([.string(grace.id), .string(ada.id)]))
        #expect(doc.value(record, single) == .collaborators([ada]))
        #expect(doc.displayString(record, multi) == "Grace Hopper, Ada Lovelace")
        #expect(doc.value(record, multi).formulaValue == .array([.text("Grace Hopper"), .text("Ada Lovelace")]))

        // Unknown names only become people when the caller allows it (typing does; automations' "match only" doesn't).
        #expect(doc.parseValue("Linus", for: single, createMissingChoices: false) == .null)
        doc.setCell(recordID: r, fieldID: single.id, text: "Linus")
        let linus = try #require(doc.person(matching: "Linus"))
        #expect(doc.record(r)?[single.id] == .string(linus.id))

        // A single-person field shows one person even if several ids were written.
        doc.updateRecord(r, values: [single.id: .array([.string(grace.id), .string(ada.id)])])
        #expect(doc.value(try #require(doc.record(r)), single) == .collaborators([grace]))

        // Removing a person hides them from cells without touching the stored ids.
        doc.removePerson(grace.id)
        #expect(doc.displayString(try #require(doc.record(r)), multi) == "Ada Lovelace")
    }

    @Test func filtersCompareThePeopleInACell() throws {
        let (doc, table, single, multi, ada, grace) = try setUp()
        let both = doc.createRecord(in: table, values: [single.id: .string(ada.id), multi.id: .array([.string(ada.id), .string(grace.id)])])
        let justGrace = doc.createRecord(in: table, values: [single.id: .string(grace.id), multi.id: .array([.string(grace.id)])])
        let nobody = doc.createRecord(in: table)
        func matching(_ field: FieldModel, _ op: FilterOperator, _ value: JSONValue? = nil) -> Set<String> {
            let filter = FilterGroup(conditions: [FilterCondition(fieldID: field.id, op: op, value: value)])
            return Set(doc.records(in: table).filter { doc.matches($0, filter: filter) }.map(\.id))
        }
        #expect(matching(single, .is, [.string(ada.id)]) == [both])
        #expect(matching(single, .isNot, [.string(ada.id)]) == [justGrace, nobody])
        #expect(matching(single, .isAnyOf, [.string(ada.id), .string(grace.id)]) == [both, justGrace])
        #expect(matching(single, .isNoneOf, [.string(ada.id)]) == [justGrace, nobody])
        #expect(matching(single, .isEmpty) == [nobody])
        #expect(matching(single, .isNotEmpty) == [both, justGrace])
        #expect(matching(multi, .hasAnyOf, [.string(ada.id)]) == [both])
        #expect(matching(multi, .hasAllOf, [.string(ada.id), .string(grace.id)]) == [both])
        #expect(matching(multi, .hasNoneOf, [.string(ada.id)]) == [justGrace, nobody])
        #expect(matching(multi, .isExactly, [.string(grace.id)]) == [justGrace])
        // Automations can name people instead of using ids.
        #expect(matching(single, .is, "grace@example.com") == [justGrace])

        #expect(FilterOperator.available(for: single) == [.is, .isNot, .isAnyOf, .isNoneOf, .isEmpty, .isNotEmpty])
        #expect(FilterOperator.available(for: multi) == [.hasAnyOf, .hasAllOf, .hasNoneOf, .isExactly, .isEmpty, .isNotEmpty])
    }

    @Test func sortingAndGroupingUseNames() throws {
        let (doc, table, single, _, ada, grace) = try setUp()
        let zed = try #require(doc.addPerson(name: "Zed Shaw"))
        let r1 = doc.createRecord(in: table, values: [single.id: .string(zed.id)])
        let r2 = doc.createRecord(in: table, values: [single.id: .string(ada.id)])
        let r3 = doc.createRecord(in: table)
        let r4 = doc.createRecord(in: table, values: [single.id: .string(grace.id)])
        let r5 = doc.createRecord(in: table, values: [single.id: .string(ada.id)])
        let viewID = try #require(doc.views(in: table).first).id
        doc.updateViewConfig(viewID) { $0.sorts = [SortSpec(fieldID: single.id)] }
        let view = try #require(doc.view(viewID))
        #expect(doc.evaluate(view: view).recordIDs == [r2, r5, r4, r1, r3])

        doc.updateViewConfig(viewID) { $0.groups = [SortSpec(fieldID: single.id, ascending: false)] }
        let grouped = doc.evaluate(view: try #require(doc.view(viewID)))
        let titles = grouped.rows.compactMap { row -> String? in if case .group(let g) = row { g.title } else { nil } }
        #expect(titles == ["Zed Shaw", "Grace Hopper", "Ada Lovelace", "Empty"])
    }

    @Test func convertingTextToCollaboratorsCreatesPeople() throws {
        let doc = TestSupport.document()
        let ada = try #require(doc.addPerson(name: "Ada Lovelace"))
        let table = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let owner = doc.createField(in: table, name: "Owner", type: .singleLineText)
        let r1 = doc.createRecord(in: table, values: [owner: "Ada Lovelace"])
        let r2 = doc.createRecord(in: table, values: [owner: "new@example.com"])
        doc.updateField(owner, type: .collaborator)
        let newcomer = try #require(doc.person(matching: "new@example.com"))
        #expect(doc.record(r1)?[owner] == .string(ada.id))
        #expect(doc.record(r2)?[owner] == .string(newcomer.id))
        #expect(doc.people.count == 2)
    }
}

@Suite("Created by and last modified by")
@MainActor
struct DeviceAuthorTests {
    @Test func fieldsShowTheMacThatCreatedAndLastEditedEachRecord() throws {
        let local = TestSupport.document(device: "devA")
        let table = local.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let name = try #require(local.primaryField(of: table)).id
        let notes = local.createField(in: table, name: "Notes", type: .multilineText)
        let createdBy = try #require(local.field(local.createField(in: table, name: "Created by", type: .createdBy)))
        let modifiedBy = try #require(local.field(local.createField(in: table, name: "Modified by", type: .lastModifiedBy)))
        var watching = FieldOptions()
        watching.watchedFieldIDs = [notes]
        let notesBy = try #require(local.field(local.createField(in: table, name: "Notes by", type: .lastModifiedBy, options: watching)))
        let first = local.createRecord(in: table, values: [name: "Local"])

        // A second Mac edits the record and adds one of its own; its log is merged here.
        let remote = BaseDocument(baseID: local.baseID, deviceID: "devB", deviceName: "Studio Mac", state: local.state)
        var ops: [ChangeOperation] = []
        remote.outbox = { ops.append(contentsOf: $0) }
        remote.registerDevice()
        remote.updateRecord(first, values: [name: "Edited remotely"])
        let second = remote.createRecord(in: table, values: [name: "Remote"])
        local.mergeRemote(ops)

        let firstRecord = try #require(local.record(first))
        let secondRecord = try #require(local.record(second))
        #expect(local.displayString(firstRecord, createdBy) == "Mac devA")
        #expect(local.displayString(firstRecord, modifiedBy) == "Studio Mac")
        #expect(local.displayString(firstRecord, notesBy) == "Mac devA")
        #expect(local.displayString(secondRecord, createdBy) == "Studio Mac")
        guard case .collaborators(let people) = local.value(firstRecord, modifiedBy) else {
            Issue.record("Expected a person")
            return
        }
        #expect(people.map(\.id) == ["devB"])

        ops = []
        remote.updateRecord(first, values: [notes: "Written on the studio Mac"])
        local.mergeRemote(ops)
        #expect(local.displayString(try #require(local.record(first)), notesBy) == "Studio Mac")
        local.updateRecord(first, values: [name: "Back home"])
        #expect(local.displayString(try #require(local.record(first)), modifiedBy) == "Mac devA")
        #expect(local.displayString(try #require(local.record(first)), notesBy) == "Studio Mac")

        // Filterable and sortable as text.
        let byStudio = FilterGroup(conditions: [FilterCondition(fieldID: createdBy.id, op: .contains, value: "studio")])
        #expect(local.records(in: table).filter { local.matches($0, filter: byStudio) }.map(\.id) == [second])
        #expect(FilterOperator.available(for: .createdBy).contains(.startsWith))
        let viewID = try #require(local.views(in: table).first).id
        local.updateViewConfig(viewID) { $0.sorts = [SortSpec(fieldID: createdBy.id, ascending: false)] }
        #expect(local.evaluate(view: try #require(local.view(viewID))).recordIDs == [second, first])
    }
}

@Suite("Barcodes")
@MainActor
struct BarcodeTests {
    @Test func valuesAreStoredAsTextAndTypeAndShownAsText() throws {
        #expect(BarcodeValue(json: "4006381333931") == BarcodeValue(text: "4006381333931"))
        #expect(BarcodeValue(json: ["text": "ABC-123", "type": "code39"])?.type == "code39")
        #expect(BarcodeValue(json: ["text": "", "type": "qr"]) == nil)
        #expect(BarcodeValue(json: .number(42))?.text == "42")
        #expect(BarcodeValue(text: "x", type: "QR").isQRCode)
        #expect(BarcodeValue(text: "x", type: "").json == ["text": "x"])

        let doc = TestSupport.document()
        let table = doc.createTable(name: "Stock", starterFields: false, emptyRecords: 0)
        let code = try #require(doc.field(doc.createField(in: table, name: "Code", type: .barcode)))
        let r = doc.createRecord(in: table, values: [code.id: ["text": "https://example.com", "type": "qr"]])
        #expect(doc.displayString(try #require(doc.record(r)), code) == "https://example.com")

        // Retyping the text keeps the symbology; plain strings from scripts still read.
        doc.setCell(recordID: r, fieldID: code.id, text: " https://rowhouse.app ")
        #expect(doc.record(r)?[code.id] == ["text": "https://rowhouse.app", "type": "qr"])
        #expect(doc.parseValue("", for: code, createMissingChoices: false) == .null)
        doc.updateRecord(r, values: [code.id: "plain"])
        #expect(doc.value(try #require(doc.record(r)), code) == .text("plain"))

        let filter = FilterGroup(conditions: [FilterCondition(fieldID: code.id, op: .startsWith, value: "pla")])
        #expect(doc.matches(try #require(doc.record(r)), filter: filter))

        let skus = doc.createField(in: table, name: "SKU", type: .singleLineText)
        doc.updateRecord(r, values: [skus: "SKU-9"])
        doc.updateField(skus, type: .barcode)
        #expect(doc.record(r)?[skus] == ["text": "SKU-9"])
    }
}

@Suite("Rich text")
@MainActor
struct RichTextTests {
    @Test func markdownIsStrippedToReadableText() {
        let markdown = """
        # Launch plan
        **Bold** and *italic*, ~~gone~~, `code` and [a link](https://example.com).
        - first
        - [x] done
          * nested _emphasis_
        1. one
        2. two
        > quoted __strong__
        ---
        ```
        let x = **not bold**
        ```
        snake_case_name stays, 2 * 3 * 4 stays, \\*escaped\\* stays
        """
        #expect(RichText.plainText(from: markdown) == """
        Launch plan
        Bold and italic, gone, code and a link.
        • first
        ☑ done
          • nested emphasis
        1. one
        2. two
        quoted strong

        let x = **not bold**
        snake_case_name stays, 2 * 3 * 4 stays, *escaped* stays
        """)
        #expect(RichText.plainText(from: "***both*** and **_mixed_**") == "both and mixed")
        #expect(RichText.plainText(from: "No markup at all") == "No markup at all")
        #expect(RichText.stripInline("![logo](https://x/logo.png) <https://rowhouse.app>") == "logo https://rowhouse.app")
    }

    @Test func blocksDescribeHeadingsListsAndCode() {
        #expect(RichText.blocks(from: "## Title ##\n- [ ] task\n3) third\n\n```\ncode\n```") == [
            .heading(level: 2, text: "Title"),
            .bullet(indent: 0, text: "task", checked: false),
            .numbered(indent: 0, number: 3, text: "third"),
            .blank,
            .code("code"),
        ])
        #expect(RichText.blocks(from: "#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func gridAndCSVShowPlainTextOnlyForRichTextFields() throws {
        let doc = TestSupport.document()
        let table = doc.createTable(name: "Notes", starterFields: false, emptyRecords: 0)
        var rich = FieldOptions()
        rich.richText = true
        let formatted = try #require(doc.field(doc.createField(in: table, name: "Formatted", type: .multilineText, options: rich)))
        let plain = try #require(doc.field(doc.createField(in: table, name: "Plain", type: .multilineText)))
        let r = doc.createRecord(in: table, values: [formatted.id: "**Hi** there", plain.id: "**Hi** there"])
        let record = try #require(doc.record(r))
        #expect(record[formatted.id] == "**Hi** there")
        #expect(doc.displayString(record, formatted) == "Hi there")
        #expect(doc.displayString(record, plain) == "**Hi** there")
        let csv = doc.exportCSV(view: try #require(doc.views(in: table).first))
        #expect(csv.contains("Hi there,**Hi** there"))
    }

    @Test func toolbarEditsWrapAndToggleMarkdown() {
        func run(_ format: MarkdownFormat, _ text: String, _ location: Int, _ length: Int) -> (String, NSRange) {
            let edit = RichText.edit(format, text: text, selection: NSRange(location: location, length: length))
            return (edit.applied(to: text), edit.selection)
        }
        #expect(run(.bold, "make this bold", 10, 4) == ("make this **bold**", NSRange(location: 10, length: 8)))
        #expect(run(.bold, "make this **bold**", 12, 4) == ("make this bold", NSRange(location: 10, length: 4)))
        #expect(run(.bold, "make this **bold**", 10, 8) == ("make this bold", NSRange(location: 10, length: 4)))
        #expect(run(.italic, "a **b** c", 4, 1).0 == "a ***b*** c")
        #expect(run(.italic, "", 0, 0) == ("**", NSRange(location: 1, length: 0)))
        #expect(run(.strikethrough, " old ", 0, 5).0 == " ~~old~~ ")
        #expect(run(.code, "call run()", 5, 5).0 == "call `run()`")
        #expect(run(.code, "a\nb", 0, 3).0 == "```\na\nb\n```")
        #expect(run(.link, "see docs", 4, 4) == ("see [docs](https://)", NSRange(location: 11, length: 8)))
        #expect(run(.link, "https://rowhouse.app", 0, 20) == ("[](https://rowhouse.app)", NSRange(location: 1, length: 0)))
        #expect(run(.heading, "Title\nbody", 2, 0) == ("# Title\nbody", NSRange(location: 4, length: 0)))
        #expect(run(.heading, "# Title", 3, 0).0 == "Title")
        #expect(run(.bulletList, "one\ntwo\n\nthree", 0, 14).0 == "- one\n- two\n\n- three")
        #expect(run(.bulletList, "- one\n- two", 0, 11).0 == "one\ntwo")
        #expect(run(.numberedList, "- one\n- two", 0, 11).0 == "1. one\n2. two")
        #expect(run(.numberedList, "", 0, 0) == ("1. ", NSRange(location: 3, length: 0)))
    }
}

@Suite("Default values")
@MainActor
struct DefaultValueTests {
    @Test func newRecordsGetDefaultsForFieldsWithoutAValue() throws {
        let doc = TestSupport.document()
        let ada = try #require(doc.addPerson(name: "Ada"))
        let table = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        func field(_ name: String, _ type: FieldType, _ configure: (inout FieldOptions) -> Void) -> String {
            var options = FieldOptions()
            configure(&options)
            return doc.createField(in: table, name: name, type: type, options: options)
        }
        let status = SelectChoice(name: "Todo", color: .red)
        let tag = SelectChoice(name: "Urgent", color: .orange)
        let text = field("Text", .singleLineText) { $0.defaultValue = "Hello" }
        let number = field("Number", .number) { $0.defaultValue = 3 }
        let rating = field("Rating", .rating) { $0.defaultValue = 9 }
        let check = field("Check", .checkbox) { $0.defaultValue = true }
        let single = field("Status", .singleSelect) { $0.choices = [status]; $0.defaultValue = .string(status.id) }
        let multi = field("Tags", .multipleSelects) { $0.choices = [tag]; $0.defaultValue = [.string(tag.id), "selMissing"] }
        let today = field("Today", .date) { $0.defaultValue = ["today": true] }
        let now = field("Now", .date) { $0.includeTime = true; $0.defaultValue = ["today": true] }
        let fixed = field("Fixed", .date) { $0.defaultValue = "2026-01-05" }
        let owner = field("Owner", .collaborator) { $0.defaultValue = .string(ada.id) }
        let formula = field("Formula", .formula) { $0.formula = "1"; $0.defaultValue = "ignored" }

        let r = doc.createRecord(in: table, values: [text: "Given"])
        let record = try #require(doc.record(r))
        #expect(record[text] == "Given")
        #expect(record[number] == 3)
        #expect(record[rating] == 5)
        #expect(record[check] == true)
        #expect(record[single] == .string(status.id))
        #expect(record[multi] == [.string(tag.id)])
        #expect(record[today] == .string(DateCoding.encode(Date(), includeTime: false)))
        let stamped = try #require(record[now].stringValue.flatMap(DateCoding.parseISO))
        #expect(abs(stamped.timeIntervalSinceNow) < 60)
        #expect(record[fixed] == "2026-01-05")
        #expect(record[owner] == .string(ada.id))
        #expect(record.cells[formula] == nil)
        #expect(doc.field(formula)?.options.defaultValue == nil)

        // Duplicates copy the original's values rather than filling in defaults.
        doc.updateRecord(r, values: [number: .null])
        let copy = try #require(doc.duplicateRecords([r]).first)
        #expect(doc.record(copy)?.cells[number] == nil)

        // Imports keep what the file says.
        let rows = [["Text"], [""], ["From file"]]
        var plan = CSVImporter.plan(rows: rows, hasHeader: true)
        plan[0].targetFieldID = text
        doc.importCSV(rows: rows, hasHeader: true, plan: plan, into: table)
        let imported = doc.records(in: table).suffix(2)
        #expect(imported.map { $0.cells[text] } == [nil, "From file"])
        #expect(imported.allSatisfy { $0.cells[number] == nil })

        // A default belongs to its type: changing the type clears it.
        doc.updateField(number, type: .singleLineText)
        #expect(doc.field(number)?.options.defaultValue == nil)
        #expect(doc.resolvedDefaultValue(for: try #require(doc.field(text))) == "Hello")
    }

    @Test func defaultsAreNotAppliedWhenTheCallerOptsOut() throws {
        let doc = TestSupport.document()
        let table = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        var options = FieldOptions()
        options.defaultValue = "Hi"
        let text = doc.createField(in: table, name: "Text", type: .singleLineText, options: options)
        let r = doc.createRecord(in: table, applyingDefaults: false)
        #expect(doc.record(r)?.cells[text] == nil)
    }
}

@Suite("Conditional lookups, rollups and counts")
@MainActor
struct ConditionalRelationTests {
    @Test func onlyLinkedRecordsMatchingTheConditionsAreUsed() throws {
        let doc = TestSupport.document()
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        let tasks = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        let taskName = try #require(doc.primaryField(of: tasks)).id
        let hours = doc.createField(in: tasks, name: "Hours", type: .number)
        let done = doc.createField(in: tasks, name: "Done", type: .checkbox)
        var linkOptions = FieldOptions()
        linkOptions.linkedTableID = tasks
        let link = doc.createField(in: projects, name: "Tasks", type: .link, options: linkOptions)
        let onlyDone = FilterGroup(conditions: [FilterCondition(fieldID: done, op: .is, value: true)])

        var lookupOptions = FieldOptions()
        lookupOptions.linkFieldID = link
        lookupOptions.targetFieldID = taskName
        lookupOptions.linkFilter = onlyDone
        let lookup = try #require(doc.field(doc.createField(in: projects, name: "Done tasks", type: .lookup, options: lookupOptions)))
        var rollupOptions = lookupOptions
        rollupOptions.targetFieldID = hours
        rollupOptions.rollupFormula = "SUM(values)"
        rollupOptions.linkFilter = FilterGroup(conditions: [FilterCondition(fieldID: hours, op: .greaterThan, value: 2)])
        let rollup = try #require(doc.field(doc.createField(in: projects, name: "Big hours", type: .rollup, options: rollupOptions)))
        var countOptions = FieldOptions()
        countOptions.linkFieldID = link
        countOptions.linkFilter = onlyDone
        let count = try #require(doc.field(doc.createField(in: projects, name: "Done count", type: .count, options: countOptions)))
        var allOptions = FieldOptions()
        allOptions.linkFieldID = link
        let allCount = try #require(doc.field(doc.createField(in: projects, name: "All", type: .count, options: allOptions)))

        let t1 = doc.createRecord(in: tasks, values: [taskName: "Design", hours: 3, done: true])
        let t2 = doc.createRecord(in: tasks, values: [taskName: "Build", hours: 5])
        let t3 = doc.createRecord(in: tasks, values: [taskName: "Ship", hours: 1, done: true])
        let p = doc.createRecord(in: projects, values: [link: [.string(t1), .string(t2), .string(t3)]])
        let project = try #require(doc.record(p))

        #expect(doc.value(project, lookup) == .list([.text("Design"), .text("Ship")]))
        #expect(doc.value(project, rollup) == .number(8))
        #expect(doc.value(project, count) == .number(2))
        #expect(doc.value(project, allCount) == .number(3))

        doc.updateRecord(t2, values: [done: true])
        #expect(doc.value(try #require(doc.record(p)), count) == .number(3))
        #expect(doc.value(try #require(doc.record(p)), lookup) == .list([.text("Design"), .text("Build"), .text("Ship")]))
    }
}

@Suite("Comment mentions") @MainActor
struct MentionTests {
    @Test func mentionsMatchLongestNamesAndReachOtherMacs() async throws {
        let entry = try TestSupport.makePackage()
        let a = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "MacBook"))
        let doc = a.document
        let ada = doc.addPerson(name: "Ada")!
        let adaL = doc.addPerson(name: "Ada Lovelace")!
        let grace = doc.addPerson(name: "Grace Hopper", email: "grace@example.com")!
        let t = doc.createTable(name: "T")
        let r = doc.records(in: t)[0].id
        #expect(doc.mentionedPeople(in: "Hi @ada lovelace and @Grace Hopper, cc @Ada.").map(\.id) == [adaL.id, grace.id, ada.id])
        #expect(doc.mentionedPeople(in: "mail me at x@Ada or @Adam").isEmpty)
        #expect(doc.mentionRanges(in: "@Ada @Ada").count == 2)
        doc.addComment(to: r, text: "@Grace Hopper can you check this?")
        #expect(doc.comments(for: r)[0].mentions == [grace.id])
        a.storage.flush()

        let b = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devB", name: "iMac"))
        var created: [String] = []
        let token = b.document.addObserver { created += $0.createdComments }
        doc.addComment(to: r, text: "Thanks @Ada")
        a.storage.flush()
        let changes = b.storage.pollChanges()
        for snapshot in changes.snapshots { b.document.mergeRemote(snapshot) }
        b.document.mergeRemote(changes.ops)
        #expect(created.count == 1)
        #expect(b.document.comments(for: r).last?.mentions == [ada.id])
        b.document.removeObserver(token)
        a.close()
        b.close()
    }
}

@Suite("Current user filter") @MainActor
struct CurrentUserFilterTests {
    @Test func meMatchesThePersonMarkedOnThisMac() {
        let doc = TestSupport.document()
        let ada = doc.addPerson(name: "Ada")!
        let grace = doc.addPerson(name: "Grace")!
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let owner = doc.createField(in: t, name: "Owner", type: .collaborator)
        let a = doc.createRecord(in: t, values: [owner: .string(ada.id)])
        _ = doc.createRecord(in: t, values: [owner: .string(grace.id)])
        let v = doc.views(in: t)[0].id
        doc.updateViewConfig(v) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: owner, op: .is, value: [.string(Person.meToken)])]) }
        #expect(doc.evaluate(view: doc.view(v)!).recordIDs.isEmpty)
        doc.currentPersonID = ada.id
        #expect(doc.evaluate(view: doc.view(v)!).recordIDs == [a])
    }
}
