import Foundation
import Testing
@testable import RowHouseCore

@Suite("Record value coding") @MainActor
struct RecordValueCodingTests {
    /// A table with one field of every type, plus a People table to link to.
    struct Fixture {
        let doc: BaseDocument
        let table: String
        let people: String
        let ada: String
        let grace: String
        var fields: [FieldType: FieldModel] = [:]

        func field(_ type: FieldType) -> FieldModel { fields[type]! }
    }

    func fixture() -> Fixture {
        let doc = TestSupport.document()
        let people = doc.createTable(name: "People", starterFields: false, emptyRecords: 0)
        let personName = doc.primaryField(of: people)!.id
        let ada = doc.createRecord(in: people, values: [personName: "Ada"])
        let grace = doc.createRecord(in: people, values: [personName: "Grace"])
        let table = doc.createTable(name: "Things", starterFields: false, emptyRecords: 0)
        var f = Fixture(doc: doc, table: table, people: people, ada: ada, grace: grace)
        f.fields[.singleLineText] = doc.primaryField(of: table)!
        var linkID = ""
        for type in FieldType.allCases where type != .singleLineText {
            var options = FieldOptions()
            switch type {
            case .singleSelect, .multipleSelects:
                options.choices = [SelectChoice(name: "Todo", color: .red), SelectChoice(name: "Done", color: .green)]
            case .link:
                options.linkedTableID = people
            case .lookup, .rollup, .count:
                options.linkFieldID = linkID
                options.targetFieldID = personName
                if type == .rollup { options.rollupFormula = "COUNTA(values)" }
            case .formula:
                options.formula = "{Number} * 2"
            case .button:
                options.buttonURLFormula = "\"https://example.com/\" & {Name}"
            case .currency:
                options.currencySymbol = "$"
            default:
                break
            }
            let id = doc.createField(in: table, name: type.displayName, type: type, options: options)
            if type == .link { linkID = id }
            f.fields[type] = doc.field(id)!
        }
        // Lookups and rollups need the link field, which may have been created after them.
        for type in [FieldType.lookup, .rollup, .count] {
            var options = f.field(type).options
            options.linkFieldID = linkID
            doc.updateField(f.field(type).id, options: options)
            f.fields[type] = doc.field(f.field(type).id)!
        }
        return f
    }

    /// Writes `input` into a fresh record and reads the field back.
    func roundTrip(_ f: Fixture, _ type: FieldType, _ input: JSONValue, typecast: Bool = false) throws -> JSONValue {
        let coding = RecordValueCoding(document: f.doc, typecast: typecast)
        let ids = try coding.createRecords([[f.field(type).name: input]], in: f.table)
        let record = f.doc.record(ids[0])!
        return coding.value(of: record, field: f.doc.field(f.field(type).id)!)
    }

    @Test func editableTypesRoundTrip() throws {
        let f = fixture()
        let samples: [FieldType: [(JSONValue, JSONValue)]] = [
            .singleLineText: [("Hello", "Hello"), ("Two\nlines", "Two lines"), (42, "42")],
            .multilineText: [("Line 1\nLine 2", "Line 1\nLine 2")],
            .email: [(" ada@example.com ", "ada@example.com")],
            .url: [("https://example.com/a", "https://example.com/a")],
            .phoneNumber: [("+1 555 0100", "+1 555 0100")],
            .number: [(3.25, 3.25), ("1,234.5", 1234.5), (-7, -7)],
            .currency: [(12.5, 12.5), ("$1,200", 1200)],
            .percent: [(0.25, 0.25), ("25%", 0.25)],
            .duration: [(5400, 5400), ("1:30", 5400)],
            .rating: [(4, 4), (9, 5), ("★★★", 3)],
            .checkbox: [(true, true), (false, false), ("yes", true), (1, true)],
            .singleSelect: [("Done", "Done"), ("done", "Done"), (["name": "Todo"], "Todo")],
            .multipleSelects: [(["Todo", "Done"], ["Todo", "Done"]), ("Done, Todo", ["Done", "Todo"])],
            .date: [("2026-09-26", "2026-09-26")],
            .link: [
                (["Ada"], [["id": .string(f.ada), "name": "Ada"]]),
                (.string(f.grace), [["id": .string(f.grace), "name": "Grace"]]),
                ([["id": .string(f.ada)], "Grace"], [["id": .string(f.ada), "name": "Ada"], ["id": .string(f.grace), "name": "Grace"]]),
            ],
        ]
        for type in FieldType.allCases where !type.isComputed && type != .attachment {
            guard let cases = samples[type] else {
                // Types added later still accept null to clear a cell.
                #expect(try RecordValueCoding(document: f.doc).storedValue(.null, for: f.field(type)) == .null)
                continue
            }
            for (input, expected) in cases {
                #expect(try roundTrip(f, type, input) == expected, "\(type) \(input)")
            }
        }
    }

    @Test func datesWithTimesUseISO8601() throws {
        let f = fixture()
        var options = f.field(.date).options
        options.includeTime = true
        f.doc.updateField(f.field(.date).id, options: options)
        let coding = RecordValueCoding(document: f.doc)
        let id = try coding.createRecords([["Date": "2026-09-26T14:30:00Z"]], in: f.table)[0]
        #expect(coding.value(of: f.doc.record(id)!, field: f.doc.field(f.field(.date).id)!) == "2026-09-26T14:30:00.000Z")
    }

    @Test func computedFieldsReadAndRefuseWrites() throws {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc, attachmentsURL: URL(fileURLWithPath: "/tmp/base.rowhouse/attachments"))
        let id = try coding.createRecords([["Name": "Widget", "Number": 21, "Link to another record": ["Ada", "Grace"]]], in: f.table)[0]
        let attachment = AttachmentInfo(filename: "photo.png", hash: "abc", size: 10, mimeType: "image/png", width: 4, height: 3)
        f.doc.updateRecord(id, values: [f.field(.attachment).id: JSONValue(encoding: [attachment])])
        let fields = coding.fields(of: f.doc.record(id)!)
        #expect(fields["Formula"] == 42)
        #expect(fields["Lookup"] == ["Ada", "Grace"])
        #expect(fields["Rollup"] == 2)
        #expect(fields["Count"] == 2)
        #expect(fields["Autonumber"] == 1)
        #expect(fields["Button"] == ["label": "Open", "url": "https://example.com/Widget"])
        #expect(fields["Created time"]?.stringValue.flatMap(DateCoding.parseISO) != nil)
        #expect(fields["Last modified time"]?.stringValue.flatMap(DateCoding.parseISO) != nil)
        #expect(fields["Attachment"] == [[
            "id": .string(attachment.id), "filename": "photo.png", "size": 10, "type": "image/png",
            "url": "file:///tmp/base.rowhouse/attachments/abc.png", "width": 4, "height": 3,
        ]])
        #expect(fields["Checkbox"] == nil)
        #expect(coding.fields(of: f.doc.record(id)!, includeEmpty: true)["Checkbox"] == false)

        for type in FieldType.allCases where type.isComputed || type == .attachment {
            #expect(throws: RecordValueCoding.Failure.self) {
                try coding.storedValues([f.field(type).name: "x"], tableID: f.table)
            }
        }
    }

    @Test func fieldsCanBeAddressedByIDOrAnyCase() throws {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc)
        let values = try coding.storedValues([f.field(.number).id: 1, "CHECKBOX": true], tableID: f.table)
        #expect(values[f.field(.number).id] == 1)
        #expect(values[f.field(.checkbox).id] == true)
        #expect(throws: RecordValueCoding.Failure("No field named Missing in table Things. Fields: " + f.doc.fields(in: f.table).map(\.name).joined(separator: ", "))) {
            try coding.storedValues(["Missing": 1], tableID: f.table)
        }
    }

    @Test func typecastAddsSelectOptionsOnlyWhenAsked() throws {
        let f = fixture()
        let strict = RecordValueCoding(document: f.doc)
        #expect(throws: RecordValueCoding.Failure.self) { try strict.createRecords([["Single select": "Blocked"]], in: f.table) }
        #expect(f.doc.field(f.field(.singleSelect).id)!.choices.count == 2)

        let lenient = RecordValueCoding(document: f.doc, typecast: true)
        let ids = try lenient.createRecords([
            ["Single select": "Blocked", "Multiple select": ["Later", "Done"]],
            ["Single select": "blocked", "Multiple select": "later"],
        ], in: f.table)
        #expect(f.doc.field(f.field(.singleSelect).id)!.choices.map(\.name) == ["Todo", "Done", "Blocked"])
        #expect(f.doc.field(f.field(.multipleSelects).id)!.choices.map(\.name) == ["Todo", "Done", "Later"])
        let second = lenient.fields(of: f.doc.record(ids[1])!)
        #expect(second["Single select"] == "Blocked")
        #expect(second["Multiple select"] == ["Later"])
    }

    @Test func aFailingRecordWritesNothing() throws {
        let f = fixture()
        let before = f.doc.recordCount(in: f.table)
        let coding = RecordValueCoding(document: f.doc, typecast: true)
        #expect(throws: RecordValueCoding.Failure("Record 2: Number expects a number, not \"lots\"")) {
            try coding.createRecords([["Single select": "Brand new"], ["Number": "lots"]], in: f.table)
        }
        #expect(f.doc.recordCount(in: f.table) == before)
        #expect(f.doc.field(f.field(.singleSelect).id)!.choice(named: "Brand new") == nil)
    }

    @Test func linksNeverCreateRecords() throws {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc, typecast: true)
        #expect(throws: RecordValueCoding.Failure.self) { try coding.createRecords([["Link to another record": ["Linus"]]], in: f.table) }
        #expect(f.doc.recordCount(in: f.people) == 2)
    }

    @Test func updatesOnlyTouchNamedFields() throws {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc)
        let id = try coding.createRecords([["Name": "Widget", "Number": 5, "Single select": "Todo"]], in: f.table)[0]
        try coding.updateRecords([(id, ["Number": 6, "Single select": .null])], in: f.table)
        let fields = coding.fields(of: f.doc.record(id)!)
        #expect(fields["Name"] == "Widget")
        #expect(fields["Number"] == 6)
        #expect(fields["Single select"] == nil)
        #expect(throws: RecordValueCoding.Failure.self) { try coding.updateRecords([(f.ada, ["Number": 1])], in: f.table) }
    }

    @Test func invalidValuesExplainWhatIsExpected() {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc)
        #expect(throws: RecordValueCoding.Failure("Date expects a date such as \"2026-09-26\" or \"2026-09-26T14:30:00Z\", not \"someday\"")) {
            try coding.storedValue("someday", for: f.field(.date))
        }
        #expect(throws: RecordValueCoding.Failure("Name expects text")) { try coding.storedValue(["a"], for: f.field(.singleLineText)) }
        #expect(throws: RecordValueCoding.Failure("Checkbox expects true or false")) { try coding.storedValue(["x": 1], for: f.field(.checkbox)) }
        #expect(throws: RecordValueCoding.Failure("Single select is a single select; pass one option")) {
            try coding.storedValue(["Todo", "Done"], for: f.field(.singleSelect))
        }
    }

    @Test func numbersInStringsMeanTheSameAsNumbers() throws {
        let f = fixture()
        #expect(try roundTrip(f, .percent, "0.25") == 0.25)
        #expect(try roundTrip(f, .percent, "50%") == 0.5)
        #expect(try roundTrip(f, .duration, "5400") == 5400)
        #expect(try roundTrip(f, .duration, "90m") == 5400)
        #expect(try roundTrip(f, .number, " 12.5 ") == 12.5)
        #expect(try roundTrip(f, .singleLineText, 0.1234567891) == "0.1234567891")
    }

    @Test func dateTimesKeepTheirCalendarDayInDateOnlyFields() throws {
        let f = fixture()
        #expect(try roundTrip(f, .date, "2026-09-26T00:00:00Z") == "2026-09-26")
        #expect(try roundTrip(f, .date, "2026-09-26T23:59:59-11:00") == "2026-09-26")
        #expect(try roundTrip(f, .date, "2026-09-26T09:15:00") == "2026-09-26")
        #expect(throws: RecordValueCoding.Failure.self) { try roundTrip(f, .date, "2026-02-30T00:00:00Z") }

        var options = f.field(.date).options
        options.includeTime = true
        f.doc.updateField(f.field(.date).id, options: options)
        let coding = RecordValueCoding(document: f.doc)
        let local = try coding.createRecords([["Date": "2026-09-26T09:15:00"]], in: f.table)[0]
        let stored = f.doc.record(local)![f.field(.date).id].stringValue.flatMap(DateCoding.parseISO)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(stored.map { calendar.dateComponents([.hour, .minute], from: $0) } == DateComponents(hour: 9, minute: 15))
    }

    @Test func linksByAmbiguousTitleAreRejected() throws {
        let f = fixture()
        let name = f.doc.primaryField(of: f.people)!.id
        f.doc.createRecord(in: f.people, values: [name: "Ada"])
        let coding = RecordValueCoding(document: f.doc)
        #expect(throws: RecordValueCoding.Failure("Link to another record: 2 records in People are called Ada; link them by record id")) {
            try coding.createRecords([["Link to another record": ["Ada"]]], in: f.table)
        }
        #expect(coding.recordIDs(titled: "ada", in: f.people).count == 2)
        #expect(coding.recordIDs(titled: "Grace", in: f.people) == [f.grace])
    }

    @Test func lenientCodingDropsWhatScriptsAlwaysDropped() throws {
        let f = fixture()
        var options = f.field(.link).options
        options.singleRecordLink = true
        f.doc.updateField(f.field(.link).id, options: options)
        let coding = RecordValueCoding(document: f.doc, style: .scripting, typecast: true, lenient: true)
        let id = try coding.createRecords([[
            "Link to another record": ["Nobody", "Grace", "Ada"],
            "Date": "someday",
            "Name": ["a", "b"],
            "Checkbox": ["yes"],
        ]], in: f.table)[0]
        let record = f.doc.record(id)!
        #expect(f.doc.value(record, f.doc.field(f.field(.link).id)!) == .links([LinkedRecordRef(id: f.grace, title: "Grace")]))
        #expect(record[f.field(.date).id] == .null)
        #expect(record[f.field(.singleLineText).id] == "a, b")
        #expect(record[f.field(.checkbox).id] == true)
        #expect(throws: RecordValueCoding.Failure.self) { try coding.createRecords([["Number": "lots"]], in: f.table) }
    }

    @Test func scriptingStyleKeepsAirtableScriptingShapes() throws {
        let f = fixture()
        let coding = RecordValueCoding(document: f.doc, style: .scripting)
        let id = try coding.createRecords([["Single select": "Done", "Multiple select": ["Todo"]]], in: f.table)[0]
        let record = f.doc.record(id)!
        let done = f.field(.singleSelect).choice(named: "Done")!
        #expect(coding.value(of: record, field: f.field(.singleSelect)) == ["id": .string(done.id), "name": "Done", "color": "green"])
        #expect(coding.value(of: record, field: f.field(.multipleSelects)).arrayValue?.first?["name"] == "Todo")
        #expect(coding.value(of: record, field: f.field(.checkbox)) == false)
        #expect(coding.value(of: record, field: f.field(.button)) == "Open")
    }
}

@Suite("Formula filters") @MainActor
struct FormulaFilterTests {
    func document() -> (BaseDocument, String) {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Stock", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let qty = doc.createField(in: t, name: "Qty", type: .number)
        var options = FieldOptions()
        options.choices = [SelectChoice(name: "Low", color: .red), SelectChoice(name: "OK", color: .green)]
        let level = doc.createField(in: t, name: "Level", type: .singleSelect, options: options)
        let low = options.choices![0].id, ok = options.choices![1].id
        doc.createRecord(in: t, values: [name: "Pens", qty: 3, level: .string(low)])
        doc.createRecord(in: t, values: [name: "Paper", qty: 40, level: .string(ok)])
        doc.createRecord(in: t, values: [name: "Ink", qty: 0])
        return (doc, t)
    }

    func names(_ doc: BaseDocument, _ records: [RecordModel]) -> [String] {
        records.map { doc.primaryTitle($0) }
    }

    @Test func truthyRecordsAreKeptInOrder() throws {
        let (doc, t) = document()
        #expect(names(doc, try doc.records(in: t, matchingFormula: "{Qty} > 2")) == ["Pens", "Paper"])
        #expect(names(doc, try doc.records(in: t, matchingFormula: "AND({Level} = 'OK', {Qty} >= 40)")) == ["Paper"])
        #expect(names(doc, try doc.records(in: t, matchingFormula: "OR(FIND(\"pa\", LOWER(Name)), {Level} = BLANK())")) == ["Paper", "Ink"])
        #expect(names(doc, try doc.records(in: t, matchingFormula: "{Qty}")) == ["Pens", "Paper"])
        #expect(try doc.records(in: t, matchingFormula: "  ").count == 3)
    }

    @Test func formulaErrorsExcludeRecordsRatherThanFailing() throws {
        let (doc, t) = document()
        #expect(names(doc, try doc.records(in: t, matchingFormula: "10 / {Qty} > 1")) == ["Pens"])
    }

    @Test func badFormulasThrowWithAMessage() {
        let (doc, t) = document()
        #expect(throws: FormulaFilterError("Unknown field {Nope}")) { try doc.records(in: t, matchingFormula: "{Nope} = 1") }
        #expect(throws: FormulaFilterError.self) { try doc.records(in: t, matchingFormula: "AND({Qty} > ") }
        do throws(FormulaFilterError) {
            _ = try doc.records(in: t, matchingFormula: "SUM(1,")
            Issue.record("expected a syntax error")
        } catch {
            #expect(!error.message.isEmpty)
        }
    }
}

@Suite("Agent devices") @MainActor
struct AgentDeviceTests {
    @Test func agentsAreListedApartAndNeverHostAutomations() {
        let mac = TestSupport.document(device: "devZ")
        mac.registerDevice()
        let agent = ChangeOperation(ts: HLC(wall: 1, counter: 0, node: "devA-agent0"), kind: .device, id: "devA-agent0",
                                    set: ["name": "Claude Code (MCP)", "lastSeen": 1, "kind": .string(DeviceInfo.agentKind)])
        mac.mergeRemote([agent])
        #expect(mac.devices.map(\.id) == ["devZ"])
        #expect(mac.agents.map(\.name) == ["Claude Code (MCP)"])
        #expect(mac.effectiveAutomationHost == "devZ")
        #expect(mac.deviceName(for: "devA-agent0") == "Claude Code (MCP)")
    }

    @Test func registeringAKindIsRecordedOnce() {
        let doc = TestSupport.document(device: "devA-agent1")
        doc.registerDevice(kind: DeviceInfo.agentKind)
        #expect(doc.agents.first?.kind == DeviceInfo.agentKind)
        let before = doc.state.latest
        doc.registerDevice(kind: DeviceInfo.agentKind)
        #expect(doc.state.latest == before)
    }

    @Test func aLibraryCanBeOpenedAtAFolder() throws {
        let root = TestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(rootURL: root)
        let entry = try library.createPackage(named: "Inventory")
        #expect(library.rootURL == root)
        #expect(library.entries.map(\.baseID) == [entry.baseID])
    }
}
