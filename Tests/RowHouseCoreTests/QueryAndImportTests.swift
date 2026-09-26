import Foundation
import Testing
@testable import RowHouseCore

@Suite("View queries") @MainActor
struct ViewQueryTests {
    struct Fixture {
        let doc: BaseDocument
        let table: String
        let name: String
        let amount: String
        let status: String
        let tags: String
        let due: String
        let done: String
        let view: String
        var choice: [String: String]
        var tagChoice: [String: String]
    }

    func fixture() -> Fixture {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Deals", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let amount = doc.createField(in: t, name: "Amount", type: .number)
        var s = FieldOptions()
        s.choices = [SelectChoice(name: "Lead", color: .gray), SelectChoice(name: "Won", color: .green), SelectChoice(name: "Lost", color: .red)]
        let status = doc.createField(in: t, name: "Status", type: .singleSelect, options: s)
        var m = FieldOptions()
        m.choices = [SelectChoice(name: "a", color: .blue), SelectChoice(name: "b", color: .pink), SelectChoice(name: "c", color: .teal)]
        let tags = doc.createField(in: t, name: "Tags", type: .multipleSelects, options: m)
        let due = doc.createField(in: t, name: "Due", type: .date)
        let done = doc.createField(in: t, name: "Done", type: .checkbox)
        let fieldStatus = doc.field(status)!
        let fieldTags = doc.field(tags)!
        let choice = Dictionary(uniqueKeysWithValues: fieldStatus.choices.map { ($0.name, $0.id) })
        let tagChoice = Dictionary(uniqueKeysWithValues: fieldTags.choices.map { ($0.name, $0.id) })
        let today = Calendar.current.startOfDay(for: Date())
        func day(_ n: Int) -> JSONValue { .string(DateCoding.encode(Calendar.current.date(byAdding: .day, value: n, to: today)!, includeTime: false)) }
        let rows: [(String, Double?, String?, [String], Int?, Bool)] = [
            ("Alpha", 100, "Lead", ["a"], -3, false),
            ("Bravo", 250, "Won", ["a", "b"], 2, true),
            ("Charlie", nil, "Lost", [], 10, false),
            ("Delta", 50, "Won", ["c"], nil, true),
            ("echo", 250, nil, ["b"], -40, false),
        ]
        for r in rows {
            var values: [String: JSONValue] = [name: .string(r.0), done: .bool(r.5)]
            if let n = r.1 { values[amount] = .number(n) }
            if let s = r.2 { values[status] = .string(choice[s]!) }
            if !r.3.isEmpty { values[tags] = .array(r.3.map { .string(tagChoice[$0]!) }) }
            if let d = r.4 { values[due] = day(d) }
            doc.createRecord(in: t, values: values)
        }
        return Fixture(doc: doc, table: t, name: name, amount: amount, status: status, tags: tags, due: due, done: done, view: doc.views(in: t)[0].id, choice: choice, tagChoice: tagChoice)
    }

    func titles(_ f: Fixture, _ configure: (inout ViewConfig) -> Void, search: String = "") -> [String] {
        f.doc.updateViewConfig(f.view) { configure(&$0) }
        let result = f.doc.evaluate(view: f.doc.view(f.view)!, search: search)
        return result.recordIDs.map { f.doc.primaryTitle(recordID: $0) }
    }

    @Test func filtersByType() {
        let f = fixture()
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.amount, op: .greaterThan, value: 90)]) } == ["Alpha", "Bravo", "echo"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.amount, op: .isEmpty)]) } == ["Charlie"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.status, op: .isAnyOf, value: [.string(f.choice["Won"]!), .string(f.choice["Lead"]!)])]) } == ["Alpha", "Bravo", "Delta"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.status, op: .isNot, value: [.string(f.choice["Won"]!)])]) } == ["Alpha", "Charlie", "echo"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.tags, op: .hasAllOf, value: [.string(f.tagChoice["a"]!), .string(f.tagChoice["b"]!)])]) } == ["Bravo"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.tags, op: .hasNoneOf, value: [.string(f.tagChoice["a"]!)])]) } == ["Charlie", "Delta", "echo"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.done, op: .is, value: true)]) } == ["Bravo", "Delta"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.name, op: .contains, value: "ha")]) } == ["Alpha", "Charlie"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.due, op: .isWithin, value: ["mode": "nextWeek"])]) } == ["Bravo"])
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.due, op: .isBefore, value: ["mode": "today"])]) } == ["Alpha", "echo"])
        // Incomplete conditions (no value yet) are ignored.
        #expect(titles(f) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: f.name, op: .contains)]) }.count == 5)
    }

    @Test func nestedGroupsCombineWithOr() {
        let f = fixture()
        let group = FilterGroup(conjunction: .or, conditions: [
            FilterCondition(fieldID: f.name, op: .is, value: "Charlie"),
        ], groups: [
            FilterGroup(conjunction: .and, conditions: [
                FilterCondition(fieldID: f.done, op: .is, value: true),
                FilterCondition(fieldID: f.amount, op: .lessThan, value: 100),
            ]),
        ])
        #expect(titles(f) { $0.filter = group } == ["Charlie", "Delta"])
    }

    @Test func sortsWithEmptiesLastAndStableTies() {
        let f = fixture()
        #expect(titles(f) { $0.sorts = [SortSpec(fieldID: f.amount, ascending: false)] } == ["Bravo", "echo", "Alpha", "Delta", "Charlie"])
        #expect(titles(f) { $0.sorts = [SortSpec(fieldID: f.amount, ascending: true), SortSpec(fieldID: f.name, ascending: false)] } == ["Delta", "Alpha", "echo", "Bravo", "Charlie"])
        #expect(titles(f) { $0.sorts = [SortSpec(fieldID: f.status)] } == ["Alpha", "Bravo", "Delta", "Charlie", "echo"])
        #expect(titles(f) { $0.sorts = [SortSpec(fieldID: f.name)] } == ["Alpha", "Bravo", "Charlie", "Delta", "echo"])
    }

    @Test func groupsProduceHeadersAndCollapse() {
        let f = fixture()
        f.doc.updateViewConfig(f.view) { $0.groups = [SortSpec(fieldID: f.status)] }
        let view = f.doc.view(f.view)!
        let result = f.doc.evaluate(view: view)
        let headers = result.rows.compactMap { row -> GroupHeader? in if case .group(let g) = row { return g } else { return nil } }
        #expect(headers.map(\.title) == ["Lead", "Won", "Lost", "Empty"])
        #expect(headers.map(\.count) == [1, 2, 1, 1])
        let collapsed = f.doc.evaluate(view: view, collapsedGroups: [headers[1].id])
        #expect(collapsed.rows.count == result.rows.count - 2)
        #expect(collapsed.recordIDs.count == 5)
    }

    @Test func searchMatchesVisibleText() {
        let f = fixture()
        #expect(titles(f, { _ in }, search: "won") == ["Bravo", "Delta"])
        #expect(titles(f, { _ in }, search: "250") == ["Bravo", "echo"])
    }

    @Test func summaries() {
        let f = fixture()
        let ids = f.doc.records(in: f.table).map(\.id)
        let amount = f.doc.field(f.amount)!
        #expect(f.doc.summary(.sum, field: amount, recordIDs: ids) == "Sum 650")
        #expect(f.doc.summary(.average, field: amount, recordIDs: ids) == "Avg 162.5")
        #expect(f.doc.summary(.empty, field: amount, recordIDs: ids) == "1 empty")
        #expect(f.doc.summary(.checked, field: f.doc.field(f.done)!, recordIDs: ids) == "2 checked")
    }
}

@Suite("CSV")
struct CSVTests {
    @Test func parsesQuotedFieldsNewlinesAndBOM() {
        let text = "\u{FEFF}Name,Notes,Amount\r\n\"Smith, Jane\",\"Line one\nLine \"\"two\"\"\",12\r\nBob,,3\n"
        let rows = CSV.parse(text)
        #expect(rows == [["Name", "Notes", "Amount"], ["Smith, Jane", "Line one\nLine \"two\"", "12"], ["Bob", "", "3"]])
    }

    @Test func detectsSemicolonsAndTabs() {
        #expect(CSV.parse("a;b;c\n1;2;3") == [["a", "b", "c"], ["1", "2", "3"]])
        #expect(CSV.parse("a\tb\n1\t2") == [["a", "b"], ["1", "2"]])
    }

    @Test func writingRoundTrips() {
        let rows = [["Name", "Quote"], ["A, B", "He said \"hi\"\nthen left"], ["", " padded "]]
        #expect(CSV.parse(CSV.write(rows)) == rows)
    }

    @Test func infersTypes() {
        #expect(CSVImporter.inferType(["1", "2.5", "-3"]) == .number)
        #expect(CSVImporter.inferType(["$1,200", "$3.50"]) == .currency)
        #expect(CSVImporter.inferType(["10%", "55%"]) == .percent)
        #expect(CSVImporter.inferType(["yes", "no", "yes"]) == .checkbox)
        #expect(CSVImporter.inferType(["a@b.com", "c@d.org"]) == .email)
        #expect(CSVImporter.inferType(["https://a.com", "http://b.com/x"]) == .url)
        #expect(CSVImporter.inferType(["2026-01-02", "2026-03-04"]) == .date)
        #expect(CSVImporter.inferType(["Open", "Closed", "Open", "Open", "Closed", "Open"]) == .singleSelect)
        #expect(CSVImporter.inferType(["Alice", "Bob", "Carol", "Dan"]) == .singleLineText)
    }

    @Test @MainActor func importsIntoANewTable() {
        let doc = TestSupport.document()
        let rows = CSV.parse("Task,Status,Points,Due\nWrite,Open,3,2026-10-01\nTest,Closed,5,2026-10-05\nShip,Open,8,2026-10-09\nDocs,Open,2,2026-10-11")
        let plan = CSVImporter.plan(rows: rows, hasHeader: true)
        #expect(plan.map(\.type) == [.singleLineText, .singleSelect, .number, .date])
        let t = doc.importCSV(rows: rows, hasHeader: true, plan: plan, tableName: "Imported")
        #expect(doc.recordCount(in: t) == 4)
        #expect(doc.primaryField(of: t)?.name == "Task")
        let status = doc.field(named: "Status", in: t)!
        #expect(status.choices.map(\.name) == ["Open", "Closed"])
        let view = doc.views(in: t)[0]
        let csv = doc.exportCSV(view: view)
        #expect(csv.hasPrefix("Task,Status,Points,Due\r\nWrite,Open,3,"))
    }
}

@Suite("Templates for automations")
struct TemplateRendererTests {
    let scope: JSONValue = [
        "trigger": ["record": ["id": "rec1", "Name": "Jane \"JJ\" Doe", "Due.Date": "2026-10-01", "fields": ["fld1": "x"]]],
        "steps": ["1": ["count": 2, "titles": ["A", "B"], "ok": true]],
        "now": "2026-09-26T00:00:00Z",
    ]

    @Test func resolvesPathsIncludingDottedKeys() {
        #expect(TemplateRenderer.render("Hi {{trigger.record.Name}}!", scope: scope) == "Hi Jane \"JJ\" Doe!")
        #expect(TemplateRenderer.render("{{trigger.record.Due.Date}}", scope: scope) == "2026-10-01")
        #expect(TemplateRenderer.render("{{steps.1.titles}} ({{steps.1.count}})", scope: scope) == "A, B (2)")
        #expect(TemplateRenderer.render("{{steps.1.titles.0}}", scope: scope) == "A")
        #expect(TemplateRenderer.render("{{missing.path}}|", scope: scope) == "|")
        #expect(TemplateRenderer.render("no placeholders", scope: scope) == "no placeholders")
        #expect(TemplateRenderer.render("unterminated {{trigger", scope: scope) == "unterminated {{trigger")
    }

    @Test func pipesEncodeValues() {
        #expect(TemplateRenderer.render("{\"n\": {{trigger.record.Name | json}}}", scope: scope) == "{\"n\": \"Jane \\\"JJ\\\" Doe\"}")
        #expect(TemplateRenderer.render("q={{trigger.record.Name | url}}", scope: scope) == "q=Jane%20%22JJ%22%20Doe")
        #expect(TemplateRenderer.render("{{steps.1.ok | json}}", scope: scope) == "true")
        #expect(TemplateRenderer.render("{{trigger.record.Name | upper}}", scope: scope) == "JANE \"JJ\" DOE")
    }
}

@Suite("Schedules")
struct ScheduleTests {
    @Test func computesNextFireDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10))!
        let daily = Schedule(frequency: .daily, hour: 9, minute: 30)
        #expect(daily.nextFireDate(after: start, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 9, minute: 30)))
        let minutes = Schedule(frequency: .minutes, interval: 2)
        #expect(minutes.nextFireDate(after: start, calendar: cal) == start.addingTimeInterval(300))
        let weekly = Schedule(frequency: .weekly, hour: 8, minute: 0, weekday: 2)
        #expect(weekly.nextFireDate(after: start, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8)))
    }
}

@Suite("Printable HTML") @MainActor
struct HTMLExportTests {
    @Test func viewAndRecordHTMLEscapeValuesAndShowGroups() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let notes = doc.createField(in: t, name: "Notes", type: .multilineText)
        let r = doc.createRecord(in: t, values: [name: "Fix <script> & stuff", notes: "line 1\nline 2"])
        let view = doc.views(in: t)[0]
        doc.updateViewConfig(view.id) { $0.groups = [SortSpec(fieldID: notes)] }
        let html = doc.exportHTML(view: doc.view(view.id)!)
        #expect(html.contains("Fix &lt;script&gt; &amp; stuff"))
        #expect(html.contains("line 1<br>line 2"))
        #expect(html.contains("class=\"group\""))
        #expect(!html.contains("<script>"))
        let record = doc.exportHTML(recordID: r)
        #expect(record.contains("<h1>Fix &lt;script&gt; &amp; stuff</h1>"))
        #expect(record.contains("<dt>Notes</dt>"))
    }
}
