import Foundation
import Testing
@testable import RowHouseCore

/// A table of named records with a Status select and an optional self-link, for layout tests.
@MainActor
private struct Fixture {
    let doc = TestSupport.document()
    let table: String
    let name: String
    let status: String
    let statusChoices: [String: String]

    init(selfLink: Bool = false) {
        table = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        name = doc.primaryField(of: table)!.id
        var options = FieldOptions()
        let choices = [SelectChoice(name: "Todo", color: .gray), SelectChoice(name: "Doing", color: .yellow), SelectChoice(name: "Done", color: .green)]
        options.choices = choices
        status = doc.createField(in: table, name: "Status", type: .singleSelect, options: options)
        statusChoices = Dictionary(uniqueKeysWithValues: choices.map { ($0.name, $0.id) })
    }

    func linkField(_ name: String = "Subtasks") -> String {
        var options = FieldOptions()
        options.linkedTableID = table
        return doc.createField(in: table, name: name, type: .link, options: options)
    }

    @discardableResult
    func add(_ title: String, status: String? = nil, _ extra: [String: JSONValue] = [:]) -> String {
        var values: [String: JSONValue] = [name: .string(title)]
        if let status { values[self.status] = .string(statusChoices[status]!) }
        values.merge(extra) { _, new in new }
        return doc.createRecord(in: table, values: values)
    }

    func link(_ parent: String, _ children: String..., field: String) {
        doc.updateRecord(parent, values: [field: .array(children.map(JSONValue.string))])
    }

    func view(_ type: ViewType, _ configure: (inout ViewConfig) -> Void = { _ in }) -> ViewModel {
        let id = doc.createView(in: table, name: "Test", type: type)
        doc.updateViewConfig(id, configure)
        return doc.view(id)!
    }

    func titles(_ rows: [ListOutlineRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .group(let g): "#" + g.title
            case .record(let id): String(repeating: "  ", count: row.level) + doc.primaryTitle(recordID: id)
            }
        }
    }
}

@Suite("List outline") @MainActor
struct ListOutlineTests {
    @Test func selfLinksNestChildrenUnderTheirParents() {
        let f = Fixture()
        let subtasks = f.linkField()
        let a = f.add("A"), b = f.add("B"), c = f.add("C")
        f.add("D")
        f.link(a, b, field: subtasks)
        f.link(b, c, field: subtasks)
        let view = f.view(.list) { $0.listChildLinkFieldID = subtasks }

        let collapsed = f.doc.listOutline(view: view)
        #expect(f.titles(collapsed) == ["A", "D"])
        #expect(collapsed[0].hasChildren && !collapsed[0].isExpanded)
        #expect(!collapsed[1].hasChildren)

        let all = f.doc.listOutline(view: view, expansion: ListExpansion(expandedByDefault: true))
        #expect(f.titles(all) == ["A", "  B", "    C", "D"])
        #expect(all.map(\.id) == [a, "\(a)/\(b)", "\(a)/\(b)/\(c)", all[3].recordID!])
        #expect(all[2].parentRecordID == b)

        var expansion = ListExpansion()
        expansion.toggle(a)
        #expect(f.titles(f.doc.listOutline(view: view, expansion: expansion)) == ["A", "  B", "D"])
    }

    @Test func cyclesAreCutAndStillShown() {
        let f = Fixture()
        let subtasks = f.linkField()
        let a = f.add("A"), b = f.add("B"), c = f.add("C")
        f.link(a, b, field: subtasks)
        f.link(b, a, field: subtasks)
        f.link(c, c, field: subtasks)
        let view = f.view(.list) { $0.listChildLinkFieldID = subtasks }

        let rows = f.doc.listOutline(view: view, expansion: ListExpansion(expandedByDefault: true))
        // A and B only reach each other: the first becomes the root; the loop back to A is cut.
        #expect(f.titles(rows) == ["A", "  B", "C"])
        #expect(rows[1].hasChildren == false)
        #expect(rows[2].hasChildren == false)
    }

    @Test func nestingStopsAtTheDepthLimit() {
        let f = Fixture()
        let subtasks = f.linkField()
        let chain = (1...8).map { f.add("R\($0)") }
        for (parent, child) in zip(chain, chain.dropFirst()) { f.link(parent, child, field: subtasks) }
        let view = f.view(.list) { $0.listChildLinkFieldID = subtasks }

        let rows = f.doc.listOutline(view: view, expansion: ListExpansion(expandedByDefault: true))
        #expect(rows.count == ListOutline.maxLevels)
        #expect(rows.map(\.level) == Array(0..<ListOutline.maxLevels))
        #expect(rows.last?.hasChildren == false)
    }

    @Test func groupsCountOnlyTopLevelRecordsAndCollapse() {
        let f = Fixture()
        let subtasks = f.linkField()
        let parent = f.add("Parent", status: "Todo")
        let child = f.add("Child", status: "Done")
        f.add("Other", status: "Doing")
        f.add("Loose", status: "Todo")
        f.link(parent, child, field: subtasks)
        let view = f.view(.list) {
            $0.listChildLinkFieldID = subtasks
            $0.groups = [SortSpec(fieldID: f.status)]
        }

        let rows = f.doc.listOutline(view: view, expansion: ListExpansion(expandedByDefault: true))
        // "Done" only holds a nested child, so it has no top-level records and no header.
        #expect(f.titles(rows) == ["#Todo", "Parent", "  Child", "Loose", "#Doing", "Other"])
        if case .group(let todo) = rows[0].kind { #expect(todo.count == 2) } else { Issue.record("expected a group header") }
        #expect(rows[1].groupDepth == 1)

        guard case .group(let todo) = rows[0].kind else { return }
        let collapsed = f.doc.listOutline(view: view, collapsedGroups: [todo.id], expansion: ListExpansion(expandedByDefault: true))
        #expect(f.titles(collapsed) == ["#Todo", "#Doing", "Other"])
        #expect(collapsed[0].isExpanded == false)
    }

    @Test func linksToAnotherTableNestOneLevelAndIgnoreTheFilter() {
        let doc = TestSupport.document()
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        let tasks = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        var options = FieldOptions()
        options.linkedTableID = projects
        options.singleRecordLink = true
        let taskProject = doc.createField(in: tasks, name: "Project", type: .link, options: options)
        let projectTasks = doc.field(taskProject)!.options.inverseFieldID!
        let pName = doc.primaryField(of: projects)!.id
        let tName = doc.primaryField(of: tasks)!.id
        let site = doc.createRecord(in: projects, values: [pName: "Site"])
        doc.createRecord(in: projects, values: [pName: "App"])
        doc.createRecord(in: tasks, values: [tName: "Design", taskProject: [.string(site)]])
        doc.createRecord(in: tasks, values: [tName: "Build", taskProject: [.string(site)]])
        let viewID = doc.createView(in: projects, name: "Outline", type: .list)
        doc.updateViewConfig(viewID) { $0.listChildLinkFieldID = projectTasks }

        let rows = doc.listOutline(view: doc.view(viewID)!, expansion: ListExpansion(expandedByDefault: true))
        #expect(rows.map { doc.primaryTitle(recordID: $0.recordID!) } == ["Site", "Design", "Build", "App"])
        #expect(rows.map(\.level) == [0, 1, 1, 0])

        // "Add child" through the inverse side links the new task to the project.
        let child = doc.createChildRecord(parentID: site, linkFieldID: projectTasks, values: [tName: "Launch"])
        #expect(child.map { doc.record($0)?.tableID } == tasks)
        #expect(doc.value(recordID: child!, fieldID: taskProject) == .links([LinkedRecordRef(id: site, title: "Site")]))
        #expect(doc.listOutline(view: doc.view(viewID)!, expansion: ListExpansion(expandedByDefault: true)).count == 5)
    }

    @Test func addChildAppendsToASelfLink() {
        let f = Fixture()
        let subtasks = f.linkField()
        let a = f.add("A")
        let b = f.add("B")
        f.link(a, b, field: subtasks)
        let c = f.doc.createChildRecord(parentID: a, linkFieldID: subtasks, values: [f.name: "C"])
        #expect(c != nil)
        #expect(f.doc.record(a)![subtasks].stringArray == [b, c!])
        #expect(f.doc.createChildRecord(parentID: a, linkFieldID: f.status) == nil)
    }

    @Test func listTimelineAndGanttViewsHonourGroups() {
        let f = Fixture()
        f.add("One", status: "Done")
        f.add("Two", status: "Todo")
        for type in [ViewType.list, .timeline, .gantt, .grid] {
            let view = f.view(type) { $0.groups = [SortSpec(fieldID: f.status)] }
            let groups = f.doc.evaluate(view: view).rows.filter { $0.recordID == nil }
            #expect(groups.count == 2, "\(type) groups")
        }
        let kanban = f.view(.kanban) { $0.groups = [SortSpec(fieldID: f.status)] }
        #expect(f.doc.evaluate(view: kanban).rows.allSatisfy { $0.recordID != nil })
    }
}

@Suite("Gantt and timeline") @MainActor
struct GanttTests {
    private let calendar = Calendar.current

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!
    }

    private func span(_ start: Int, _ end: Int) -> TimelineSpan {
        TimelineSpan(start: day(start), end: day(end))
    }

    @Test func dependenciesPointFromPrerequisitesAndFlagOverlaps() {
        let spans = ["design": span(0, 4), "build": span(5, 9), "test": span(9, 12), "launch": span(3, 3), "docs": span(0, 1)]
        let prerequisites: [String: [String]] = [
            "build": ["design"], "test": ["build", "unscheduled"], "launch": ["test", "launch"], "docs": ["design", "design"],
        ]
        let deps = GanttLayout.dependencies(recordIDs: ["design", "build", "test", "launch", "docs"], prerequisites: { prerequisites[$0] ?? [] }, spans: spans)
        #expect(deps == [
            GanttDependency(prerequisiteID: "design", dependentID: "build", isViolated: false),
            GanttDependency(prerequisiteID: "build", dependentID: "test", isViolated: true),
            GanttDependency(prerequisiteID: "test", dependentID: "launch", isViolated: true),
            GanttDependency(prerequisiteID: "design", dependentID: "docs", isViolated: true),
        ])
    }

    @Test func spansAndDependenciesComeFromRecords() {
        let f = Fixture()
        let start = f.doc.createField(in: f.table, name: "Start", type: .date)
        let end = f.doc.createField(in: f.table, name: "End", type: .date)
        let dependsOn = f.linkField("Depends on")
        func d(_ offset: Int) -> JSONValue { .string(DateCoding.encode(day(offset), includeTime: false)) }
        let plan = f.add("Plan", [start: d(0), end: d(2)])
        let build = f.add("Build", [start: d(3), end: d(1), dependsOn: [.string(plan)]])
        let ship = f.add("Ship", [start: d(2), dependsOn: [.string(build), .string(plan)]])
        let idea = f.add("Idea", [end: d(5), dependsOn: [.string(plan)]])

        let spans = f.doc.timelineSpans(recordIDs: [plan, build, ship, idea], startField: f.doc.field(start)!, endField: f.doc.field(end))
        #expect(spans[plan] == span(0, 2))
        #expect(spans[build] == span(3, 3), "an end before the start collapses to one day")
        #expect(spans[ship] == span(2, 2))
        #expect(spans[idea] == nil)
        #expect(spans[plan]?.dayCount() == 3)

        let deps = f.doc.ganttDependencies(recordIDs: [plan, build, ship, idea], dependencyField: f.doc.field(dependsOn)!, spans: spans)
        #expect(deps.map { "\(f.doc.primaryTitle(recordID: $0.prerequisiteID))→\(f.doc.primaryTitle(recordID: $0.dependentID)):\($0.isViolated)" }
            == ["Plan→Build:false", "Build→Ship:true", "Plan→Ship:true"])
    }

    @Test func draggingMovesDatesByWholeDays() {
        let f = Fixture()
        let start = f.doc.field(f.doc.createField(in: f.table, name: "Start", type: .date))!
        let end = f.doc.field(f.doc.createField(in: f.table, name: "End", type: .date))!
        let id = f.add("Task", [start.id: "2026-03-02", end.id: "2026-03-04"])

        let moved = f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 3)
        #expect(moved == [start.id: "2026-03-05", end.id: "2026-03-07"])
        #expect(f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: -2) == [start.id: "2026-02-28", end.id: "2026-03-02"])

        let stretched = f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 0, resizeDays: 4)
        #expect(stretched == [end.id: "2026-03-08"])
        // Shrinking stops at the start day.
        #expect(f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 0, resizeDays: -9) == [end.id: "2026-03-02"])
        #expect(f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 0).isEmpty)

        // Without an end date, stretching creates one; moving only moves the start.
        let single = f.add("Single", [start.id: "2026-03-10"])
        #expect(f.doc.scheduleUpdate(recordID: single, startField: start, endField: end, moveDays: 0, resizeDays: 2) == [end.id: "2026-03-12"])
        #expect(f.doc.scheduleUpdate(recordID: single, startField: start, endField: end, moveDays: 1) == [start.id: "2026-03-11"])
        #expect(f.doc.scheduleUpdate(recordID: single, startField: start, endField: nil, moveDays: 0, resizeDays: 2).isEmpty)
    }

    @Test func draggingKeepsTheTimeOfDayAcrossDaylightSaving() {
        let f = Fixture()
        var options = FieldOptions()
        options.includeTime = true
        let start = f.doc.field(f.doc.createField(in: f.table, name: "Starts", type: .date, options: options))!
        let end = f.doc.field(f.doc.createField(in: f.table, name: "Ends", type: .date, options: options))!
        let id = f.add("Meeting", [start.id: "2026-03-07T15:30:00-05:00", end.id: "2026-03-07T17:00:00-05:00"])
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        let update = f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 2, calendar: newYork)
        // US clocks go forward on 8 March: 15:30 local is now 19:30 UTC instead of 20:30.
        #expect(update[start.id]?.stringValue.flatMap { DateCoding.decode($0) } == DateCoding.parseISO("2026-03-09T19:30:00Z"))
        #expect(update[end.id]?.stringValue.flatMap { DateCoding.decode($0) } == DateCoding.parseISO("2026-03-09T21:00:00Z"))

        f.doc.updateRecord(id, values: update)
        let resized = f.doc.scheduleUpdate(recordID: id, startField: start, endField: end, moveDays: 0, resizeDays: 1, calendar: newYork)
        #expect(resized[end.id]?.stringValue.flatMap { DateCoding.decode($0) } == DateCoding.parseISO("2026-03-10T21:00:00Z"))
    }

    @Test func computedStartFieldsCannotBeDragged() {
        let f = Fixture()
        var options = FieldOptions()
        options.formula = "TODAY()"
        let formula = f.doc.field(f.doc.createField(in: f.table, name: "Today", type: .formula, options: options))!
        let id = f.add("Task")
        #expect(f.doc.scheduleUpdate(recordID: id, startField: formula, endField: nil, moveDays: 2).isEmpty)
    }
}

@Suite("Manual record order") @MainActor
struct ManualOrderTests {
    @Test func dropIndexesResolveToAnAnchorRecord() {
        let visible = ["a", "b", "c", "d"]
        #expect(ManualOrder.anchor(visible: visible, moving: ["d"], dropIndex: 0) == "a")
        #expect(ManualOrder.anchor(visible: visible, moving: ["a"], dropIndex: 1) == "b")
        #expect(ManualOrder.anchor(visible: visible, moving: ["b", "c"], dropIndex: 1) == "d")
        #expect(ManualOrder.anchor(visible: visible, moving: ["a"], dropIndex: 4) == nil)
        #expect(ManualOrder.anchor(visible: visible, moving: ["a"], dropIndex: 99) == nil)
        #expect(ManualOrder.anchor(visible: visible, moving: [], dropIndex: -3) == "a")
    }

    @Test func movingRecordsReordersTheTable() {
        let f = Fixture()
        let ids = (1...5).map { f.add("R\($0)") }
        func order() -> [String] { f.doc.records(in: f.table).map { f.doc.primaryTitle($0) } }

        f.doc.moveRecords([ids[3]], before: ids[0])
        #expect(order() == ["R4", "R1", "R2", "R3", "R5"])
        f.doc.moveRecords([ids[0], ids[1]], before: nil)
        #expect(order() == ["R4", "R3", "R5", "R1", "R2"])
        f.doc.moveRecords([ids[4], ids[2]], before: ids[3])
        #expect(order() == ["R5", "R3", "R4", "R1", "R2"])

        let revision = f.doc.dataRevision
        f.doc.moveRecords([ids[3]], before: ids[0])
        #expect(f.doc.dataRevision == revision, "dropping a record where it already is changes nothing")
        f.doc.moveRecords([ids[0]], before: ids[0])
        #expect(f.doc.dataRevision == revision)
    }

    @Test func exhaustedGapsRenumberTheTable() {
        let f = Fixture()
        let a = f.add("A"), b = f.add("B"), c = f.add("C")
        f.doc.commit([Mutation(.record, a, ["_order": .number(1)]), Mutation(.record, b, ["_order": .number(1.0.nextUp)]), Mutation(.record, c, ["_order": .number(5)])])
        f.doc.moveRecords([c], before: b)
        #expect(f.doc.records(in: f.table).map(\.id) == [a, c, b])
        #expect(f.doc.records(in: f.table).map(\.order) == [1, 2, 3])
    }
}

@Suite("Dashboards and charts") @MainActor
struct DashboardTests {
    private func sales() -> (doc: BaseDocument, table: String, stage: String, stages: [String: String], value: String, won: String, name: String, ids: [String]) {
        let doc = TestSupport.document()
        let table = doc.createTable(name: "Deals", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: table)!.id
        var options = FieldOptions()
        let choices = [SelectChoice(name: "Lead", color: .gray), SelectChoice(name: "Proposal", color: .blue), SelectChoice(name: "Won", color: .green)]
        options.choices = choices
        let stage = doc.createField(in: table, name: "Stage", type: .singleSelect, options: options)
        var money = FieldOptions()
        money.currencySymbol = "$"
        money.precision = 0
        let value = doc.createField(in: table, name: "Value", type: .currency, options: money)
        let won = doc.createField(in: table, name: "Signed", type: .checkbox)
        let stages = Dictionary(uniqueKeysWithValues: choices.map { ($0.name, $0.id) })
        let rows: [(String, String?, Double?)] = [("Acme", "Won", 1200), ("Globex", "Proposal", 800), ("Initech", "Won", 300), ("Umbrella", nil, 50), ("Hooli", "Lead", nil)]
        let ids = rows.map { r in
            var values: [String: JSONValue] = [name: .string(r.0)]
            if let s = r.1 { values[stage] = .string(stages[s]!) }
            if let v = r.2 { values[value] = .number(v) }
            if r.1 == "Won" { values[won] = .bool(true) }
            return doc.createRecord(in: table, values: values)
        }
        return (doc, table, stage, stages, value, won, name, ids)
    }

    @Test func numberWidgetsAggregateAndFormatLikeTheirField() {
        let s = sales()
        var total = DashboardWidget(kind: .number)
        total.aggregate = .sum
        total.fieldID = s.value
        #expect(s.doc.dashboardValue(total, recordIDs: s.ids) == .number(2350, text: "$2,350"))
        #expect(s.doc.widgetTitle(total) == "Total Value")

        total.filter = FilterGroup(conditions: [FilterCondition(fieldID: s.stage, op: .is, value: .array([.string(s.stages["Won"]!)]))])
        #expect(s.doc.dashboardValue(total, recordIDs: s.ids) == .number(1500, text: "$1,500"))

        var count = DashboardWidget(kind: .number, title: "Open")
        count.filter = FilterGroup(conditions: [FilterCondition(fieldID: s.won, op: .is, value: .bool(false))])
        #expect(s.doc.dashboardValue(count, recordIDs: s.ids) == .number(3, text: "3"))
        #expect(s.doc.widgetTitle(count) == "Open")

        var average = DashboardWidget(kind: .number)
        average.aggregate = .average
        average.fieldID = s.value
        #expect(s.doc.dashboardValue(average, recordIDs: s.ids) == .number(587.5, text: "$588"))
        #expect(s.doc.dashboardValue(average, recordIDs: [s.ids[4]]) == .number(nil, text: "–"))
        average.aggregate = .max
        #expect(s.doc.dashboardValue(average, recordIDs: s.ids) == .number(1200, text: "$1,200"))
    }

    @Test func progressWidgetsCountMatchingRecords() {
        let s = sales()
        var widget = DashboardWidget(kind: .progress)
        widget.filter = FilterGroup(conditions: [FilterCondition(fieldID: s.won, op: .is, value: .bool(true))])
        #expect(s.doc.dashboardValue(widget, recordIDs: s.ids) == .progress(matching: 2, total: 5))
        #expect(s.doc.dashboardValue(widget, recordIDs: []) == .progress(matching: 0, total: 0))
    }

    @Test func listWidgetsShowTheTopRecordsBySort() {
        let s = sales()
        var widget = DashboardWidget(kind: .list)
        widget.sort = SortSpec(fieldID: s.value, ascending: false)
        widget.limit = 3
        #expect(s.doc.dashboardValue(widget, recordIDs: s.ids) == .list([s.ids[0], s.ids[1], s.ids[2]]))
        widget.sort = SortSpec(fieldID: s.value, ascending: true)
        widget.limit = 10
        // Records without a value sort last in either direction.
        #expect(s.doc.dashboardValue(widget, recordIDs: s.ids) == .list([s.ids[3], s.ids[2], s.ids[1], s.ids[0], s.ids[4]]))
        widget.sort = nil
        widget.filter = FilterGroup(conditions: [FilterCondition(fieldID: s.stage, op: .isEmpty)])
        #expect(s.doc.dashboardValue(widget, recordIDs: s.ids) == .list([s.ids[3]]))
    }

    @Test func chartDataBucketsByCategory() {
        let s = sales()
        var config = ChartConfig()
        config.categoryFieldID = s.stage
        let counts = s.doc.chartData(config, recordIDs: s.ids)
        #expect(counts.map(\.label) == ["Lead", "Proposal", "Won", "Empty"])
        #expect(counts.map(\.value) == [1, 1, 2, 1])
        #expect(counts.map(\.color) == [.gray, .blue, .green, .gray])
        #expect(counts.map(\.isEmptyBucket) == [false, false, false, true])

        config.aggregate = .sum
        config.valueFieldID = s.value
        config.sortByValue = true
        let sums = s.doc.chartData(config, recordIDs: s.ids)
        #expect(sums.map(\.label) == ["Won", "Proposal", "Empty", "Lead"])
        #expect(sums.map(\.value) == [1500, 800, 50, 0])

        var byName = ChartConfig()
        byName.categoryFieldID = s.name
        let names = s.doc.chartData(byName, recordIDs: s.ids)
        #expect(names.map(\.label) == ["Acme", "Globex", "Hooli", "Initech", "Umbrella"])
        #expect(names.map(\.color) == [.blue, .purple, .teal, .orange, .pink])

        var byCheckbox = ChartConfig()
        byCheckbox.categoryFieldID = s.won
        #expect(s.doc.chartData(byCheckbox, recordIDs: s.ids).map { "\($0.label)=\(Int($0.value))" } == ["Checked=2", "Unchecked=3"])

        var widget = DashboardWidget(kind: .chart)
        widget.chart = config
        #expect(s.doc.dashboardValue(widget, recordIDs: s.ids) == .chart(sums))
    }

    @Test func newDashboardsStartWithUsefulWidgets() {
        let doc = TestSupport.document()
        let tasks = doc.createTable(name: "Tasks")
        let taskDashboard = doc.view(doc.createView(in: tasks, name: "Overview", type: .dashboard))!
        let widgets = taskDashboard.config.dashboard?.widgets ?? []
        #expect(widgets.map(\.kind) == [.number, .progress, .chart])
        #expect(widgets[0].title == "Tasks")
        #expect(widgets[1].title == "Done")
        #expect(widgets[2].columnSpan == 2)
        #expect(doc.widgetTitle(widgets[2]) == "Records by Status")

        let s = sales()
        let dealWidgets = DashboardConfig.starter(tableName: "Deals", fields: s.doc.fields(in: s.table), primaryFieldID: s.name).widgets
        #expect(dealWidgets.map(\.kind) == [.number, .number, .chart])
        #expect(dealWidgets[1].fieldID == s.value)

        let notes = doc.createTable(name: "Notes", starterFields: false, emptyRecords: 0)
        let noteWidgets = doc.view(doc.createView(in: notes, name: "Overview", type: .dashboard))!.config.dashboard!.widgets
        #expect(noteWidgets.map(\.kind) == [.number, .progress, .list])
    }
}

@Suite("New view types") @MainActor
struct NewViewTypeTests {
    @Test func newViewsPickSensibleDefaults() {
        let f = Fixture()
        let start = f.doc.createField(in: f.table, name: "Start", type: .date)
        let end = f.doc.createField(in: f.table, name: "End", type: .date)
        let dependsOn = f.linkField("Depends on")
        let gantt = f.view(.gantt)
        #expect(gantt.config.dateFieldID == start)
        #expect(gantt.config.endDateFieldID == end)
        #expect(gantt.config.dependencyFieldID == dependsOn)
        #expect(f.view(.list).config.listChildLinkFieldID == dependsOn)
        #expect(f.view(.timeline).config.dependencyFieldID == nil)
        #expect(ViewType.list.symbolName == "list.bullet.indent")
        #expect(ViewType.gantt.symbolName == "chart.bar.doc.horizontal")
        #expect(ViewType.dashboard.symbolName == "rectangle.3.group")
    }

    @Test func viewConfigsRoundTripTheirNewSettings() throws {
        var config = ViewConfig()
        config.calendarMode = .week
        config.hideEmptyStacks = true
        config.collapsedStacks = ["", "choice"]
        config.timelineScale = .year
        var widget = DashboardWidget(kind: .list, title: "Top", span: 2)
        widget.sort = SortSpec(fieldID: "fld", ascending: false)
        config.dashboard = DashboardConfig(widgets: [widget])
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ViewConfig.self, from: data) == config)
        #expect(try JSONDecoder().decode(ViewConfig.self, from: Data("{}".utf8)) == ViewConfig())
    }

    @Test func projectTrackerHasAGanttPlanAndADashboard() {
        let doc = TestSupport.document()
        doc.apply(template: .projectTracker, storage: nil)
        let projects = doc.table(named: "Projects")!
        let views = doc.views(in: projects.id)
        let plan = views.first { $0.type == .gantt }!
        #expect(plan.name == "Delivery plan")
        let start = doc.field(plan.config.dateFieldID)!
        let dependsOn = doc.field(plan.config.dependencyFieldID)!
        #expect(dependsOn.options.linkedTableID == projects.id)
        #expect(plan.config.groups?.count == 1)
        let ids = doc.evaluate(view: plan).recordIDs
        let spans = doc.timelineSpans(recordIDs: ids, startField: start, endField: doc.field(plan.config.endDateFieldID))
        let deps = doc.ganttDependencies(recordIDs: ids, dependencyField: dependsOn, spans: spans)
        #expect(deps.count == 5)
        #expect(deps.allSatisfy { !$0.isViolated })

        let overview = views.first { $0.type == .dashboard }!
        #expect(overview.name == "Overview")
        let widgets = overview.config.dashboard?.widgets ?? []
        #expect(Set(widgets.map(\.kind)) == Set(DashboardWidgetKind.allCases))
        let all = doc.evaluate(view: overview).recordIDs
        for widget in widgets {
            switch doc.dashboardValue(widget, recordIDs: all) {
            case .number(let value, _): #expect(value != nil)
            case .chart(let data): #expect(!data.isEmpty)
            case .list(let rows): #expect(rows.count == 5)
            case .progress(let matching, let total): #expect(matching == 2 && total == 8)
            }
        }
    }
}
