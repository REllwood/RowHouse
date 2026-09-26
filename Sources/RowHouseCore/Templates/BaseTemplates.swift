import Foundation

public enum BaseTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank, projectTracker, crm, contentCalendar, inventory

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .blank: "Blank base"
        case .projectTracker: "Project Tracker"
        case .crm: "Sales CRM"
        case .contentCalendar: "Content Calendar"
        case .inventory: "Inventory"
        }
    }

    public var summary: String {
        switch self {
        case .blank: "Start from scratch with a single table."
        case .projectTracker: "Projects, tasks and a team, with a board, Gantt plan, dashboard and automations."
        case .crm: "Companies, contacts and a deal pipeline with weighted forecasts."
        case .contentCalendar: "Plan posts across channels on a calendar and gallery."
        case .inventory: "Products, stock levels, suppliers and low-stock alerts."
        }
    }

    public var icon: String {
        switch self {
        case .blank: "square.grid.3x3.fill"
        case .projectTracker: "checklist"
        case .crm: "person.2.fill"
        case .contentCalendar: "calendar"
        case .inventory: "shippingbox.fill"
        }
    }

    public var color: ChoiceColor {
        switch self {
        case .blank: .blue
        case .projectTracker: .purple
        case .crm: .green
        case .contentCalendar: .orange
        case .inventory: .teal
        }
    }
}

extension BaseDocument {
    /// Fills an empty base with a template. Not undoable (it's the base's starting state).
    public func apply(template: BaseTemplate, storage: BaseStorage?) {
        let manager = undoManager
        undoManager = nil
        defer { undoManager = manager }
        let b = TemplateBuilder(doc: self, storage: storage)
        batch("Create Base") {
            updateBaseInfo(name: template == .blank ? info.name : template.name, icon: template.icon, color: template.color)
            switch template {
            case .blank: b.blank()
            case .projectTracker: b.projectTracker()
            case .crm: b.crm()
            case .contentCalendar: b.contentCalendar()
            case .inventory: b.inventory()
            }
        }
    }
}

@MainActor
struct TemplateBuilder {
    let doc: BaseDocument
    let storage: BaseStorage?

    // MARK: Helpers

    func table(_ name: String, primary: String, description: String = "") -> (id: String, primary: String) {
        let id = doc.createTable(name: name, starterFields: false, emptyRecords: 0)
        let primaryID = doc.primaryField(of: id)!.id
        doc.renameField(primaryID, to: primary)
        if !description.isEmpty { doc.updateTableDescription(id, description) }
        if let grid = doc.views(in: id).first { doc.renameView(grid.id, to: "All \(name.lowercased())") }
        return (id, primaryID)
    }

    @discardableResult
    func field(_ table: String, _ name: String, _ type: FieldType, _ configure: (inout FieldOptions) -> Void = { _ in }) -> String {
        var options = FieldOptions()
        configure(&options)
        return doc.createField(in: table, name: name, type: type, options: options)
    }

    func select(_ table: String, _ name: String, _ choices: [(String, ChoiceColor)], multi: Bool = false) -> (id: String, choice: [String: String]) {
        let list = choices.map { SelectChoice(name: $0.0, color: $0.1) }
        let id = field(table, name, multi ? .multipleSelects : .singleSelect) { $0.choices = list }
        return (id, Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.id) }))
    }

    func link(_ from: String, to: String, name: String, inverseName: String, single: Bool = false) -> (id: String, inverse: String) {
        let id = field(from, name, .link) {
            $0.linkedTableID = to
            $0.singleRecordLink = single ? true : nil
        }
        let inverse = doc.field(id)!.options.inverseFieldID!
        doc.renameField(inverse, to: inverseName)
        return (id, inverse)
    }

    @discardableResult
    func view(_ table: String, _ name: String, _ type: ViewType, _ configure: (inout ViewConfig) -> Void = { _ in }) -> String {
        let id = doc.createView(in: table, name: name, type: type)
        doc.updateViewConfig(id) { configure(&$0) }
        return id
    }

    @discardableResult
    func record(_ table: String, _ values: [String: JSONValue]) -> String {
        doc.createRecord(in: table, values: values.filter { !$0.value.isNull })
    }

    func day(_ offset: Int) -> JSONValue {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
        return .string(DateCoding.encode(date, includeTime: false))
    }

    func links(_ ids: String...) -> JSONValue { .array(ids.map(JSONValue.string)) }

    func cover(_ seed: Int, name: String) -> JSONValue {
        guard let storage, let data = CoverArt.jpeg(seed: seed),
              let info = try? storage.importAttachment(data: data, filename: "\(name).jpg") else { return .null }
        return JSONValue(encoding: [info])
    }

    func condition(_ fieldID: String, _ op: FilterOperator, _ value: JSONValue? = nil) -> FilterGroup {
        FilterGroup(conditions: [FilterCondition(fieldID: fieldID, op: op, value: value)])
    }

    // MARK: Templates

    func blank() {
        let id = doc.createTable(name: "Table 1", starterFields: true, emptyRecords: 3)
        _ = id
    }

    func projectTracker() {
        let team = table("Team", primary: "Name", description: "People working on projects.")
        let role = select(team.id, "Role", [("Design", .pink), ("Engineering", .blue), ("Marketing", .orange), ("Product", .purple)])
        let email = field(team.id, "Email", .email)

        let projects = table("Projects", primary: "Project", description: "Every project the team is running.")
        let status = select(projects.id, "Status", [("Planning", .blue), ("In progress", .yellow), ("Blocked", .red), ("Done", .green)])
        let priority = select(projects.id, "Priority", [("High", .red), ("Medium", .orange), ("Low", .gray)])
        let owner = link(projects.id, to: team.id, name: "Owner", inverseName: "Projects", single: true)
        let start = field(projects.id, "Start", .date)
        let due = field(projects.id, "Due", .date)
        let budget = field(projects.id, "Budget", .currency) { $0.precision = 0 }
        let progress = field(projects.id, "Progress", .percent)
        let coverField = field(projects.id, "Cover", .attachment)
        let notes = field(projects.id, "Notes", .multilineText)
        let dependsOn = field(projects.id, "Depends on", .link) { $0.linkedTableID = projects.id }

        let tasks = table("Tasks", primary: "Task", description: "Work items linked to projects.")
        let taskProject = link(tasks.id, to: projects.id, name: "Project", inverseName: "Tasks", single: true)
        let taskStatus = select(tasks.id, "Status", [("Todo", .gray), ("Doing", .yellow), ("Done", .green)])
        let estimate = field(tasks.id, "Estimate", .duration)
        let taskDue = field(tasks.id, "Due", .date)
        let assignee = link(tasks.id, to: team.id, name: "Assignee", inverseName: "Tasks", single: true)

        let taskCount = field(projects.id, "Task count", .count) { $0.linkFieldID = taskProject.inverse }
        let totalEstimate = field(projects.id, "Total estimate", .rollup) {
            $0.linkFieldID = taskProject.inverse
            $0.targetFieldID = estimate
            $0.rollupFormula = "SUM(values)"
            $0.resultFormat = .duration
        }
        let daysLeft = field(projects.id, "Days left", .formula) {
            $0.formula = "IF({Status} = \"Done\", \"Complete\", IF({Due}, DATETIME_DIFF({Due}, TODAY(), 'days') & \" days\", \"\"))"
        }
        let health = field(projects.id, "Health", .formula) {
            $0.formula = "IF({Status} = \"Done\", \"✅ Done\", IF(AND({Due}, IS_BEFORE({Due}, TODAY())), \"🔴 Overdue\", IF({Progress} >= 0.6, \"🟢 On track\", \"🟡 Watch\")))"
        }

        let people: [(String, String, String)] = [
            ("Ava Chen", "Product", "ava@example.com"), ("Marcus Lee", "Engineering", "marcus@example.com"),
            ("Priya Patel", "Design", "priya@example.com"), ("Diego Alvarez", "Marketing", "diego@example.com"),
            ("Sam Taylor", "Engineering", "sam@example.com"),
        ]
        var personIDs: [String] = []
        for p in people {
            personIDs.append(record(team.id, [team.primary: .string(p.0), role.id: .string(role.choice[p.1]!), email: .string(p.2)]))
        }

        let rows: [(String, String, String, Int, Int, Int, Double, Double, String)] = [
            ("Website redesign", "In progress", "High", 0, -20, 12, 48_000, 0.65, "New marketing site with a faster checkout and refreshed brand."),
            ("Mobile app launch", "Planning", "High", 4, 5, 60, 120_000, 0.1, "Ship the iOS and Android apps to the stores."),
            ("Q4 marketing campaign", "In progress", "Medium", 3, -10, 25, 30_000, 0.4, "Seasonal campaign across email, social and search."),
            ("Customer portal", "Blocked", "High", 1, -35, 3, 65_000, 0.55, "Self-serve portal for invoices and support tickets."),
            ("Data warehouse migration", "In progress", "Medium", 4, -45, 30, 80_000, 0.7, "Move analytics to the new warehouse and retire the old ETL."),
            ("Brand refresh", "Done", "Low", 2, -80, -22, 22_000, 1, "Updated logo, colours and type across every touchpoint."),
            ("Onboarding revamp", "Planning", "Medium", 0, 10, 45, 18_000, 0.05, "Shorter sign-up and a guided first week."),
            ("Security audit", "Done", "High", 1, -60, -5, 15_000, 1, "Annual penetration test and remediation."),
        ]
        var projectIDs: [String] = []
        for (i, r) in rows.enumerated() {
            projectIDs.append(record(projects.id, [
                projects.primary: .string(r.0),
                status.id: .string(status.choice[r.1]!),
                priority.id: .string(priority.choice[r.2]!),
                owner.id: links(personIDs[r.3]),
                start: day(r.4),
                due: day(r.5),
                budget: .number(r.6),
                progress: .number(r.7),
                coverField: cover(i + 1, name: r.0.lowercased().replacingOccurrences(of: " ", with: "-")),
                notes: .string(r.8),
            ]))
        }
        // Website, Q4 campaign ← Brand refresh; Mobile app ← Customer portal, Security audit; Onboarding ← Customer portal.
        let dependencies: [(Int, [Int])] = [(0, [5]), (2, [5]), (1, [3, 7]), (6, [3])]
        doc.updateRecords(Dictionary(uniqueKeysWithValues: dependencies.map { dependent, prerequisites in
            (projectIDs[dependent], [dependsOn: .array(prerequisites.map { .string(projectIDs[$0]) })])
        }))
        let taskRows: [(String, Int, String, Double, Int, Int)] = [
            ("Wireframes", 0, "Done", 6, -12, 2), ("Visual design", 0, "Doing", 16, 2, 2), ("Build landing pages", 0, "Doing", 24, 8, 1),
            ("Checkout flow", 0, "Todo", 20, 11, 4), ("App store listing", 1, "Todo", 4, 50, 3), ("Beta programme", 1, "Todo", 10, 30, 0),
            ("Email sequence", 2, "Doing", 8, 5, 3), ("Paid social creative", 2, "Todo", 12, 15, 2), ("SSO integration", 3, "Todo", 18, 2, 4),
            ("Invoice history", 3, "Doing", 10, 3, 1), ("Schema mapping", 4, "Done", 8, -20, 1), ("Backfill jobs", 4, "Doing", 14, 10, 4),
            ("Logo files", 5, "Done", 4, -30, 2), ("Pen test fixes", 7, "Done", 12, -8, 1),
        ]
        for t in taskRows {
            record(tasks.id, [
                tasks.primary: .string(t.0),
                taskProject.id: links(projectIDs[t.1]),
                taskStatus.id: .string(taskStatus.choice[t.2]!),
                estimate: .number(t.3 * 3600),
                taskDue: day(t.4),
                assignee.id: links(personIDs[t.5]),
            ])
        }

        if let grid = doc.views(in: projects.id).first {
            doc.updateViewConfig(grid.id) {
                $0.sorts = [SortSpec(fieldID: due, ascending: true)]
                $0.summaries = [budget: .sum, progress: .average]
                $0.columnWidths = [projects.primary: 210, notes: 260, health: 130, owner.id: 150, progress: 100, budget: 120]
                $0.fieldOrder = [status.id, priority.id, owner.id, health, progress, due, budget, taskCount, totalEstimate, daysLeft, start, dependsOn, coverField, taskProject.inverse, notes]
            }
        }
        view(projects.id, "Board", .kanban) { $0.stackFieldID = status.id; $0.coverFieldID = coverField }
        view(projects.id, "Roadmap", .timeline) { $0.dateFieldID = start; $0.endDateFieldID = due; $0.colorFieldID = status.id }
        view(projects.id, "Delivery plan", .gantt) {
            $0.dateFieldID = start
            $0.endDateFieldID = due
            $0.dependencyFieldID = dependsOn
            $0.groups = [SortSpec(fieldID: priority.id)]
            $0.sorts = [SortSpec(fieldID: start)]
            $0.colorFieldID = status.id
        }
        view(projects.id, "Due dates", .calendar) { $0.dateFieldID = due; $0.colorFieldID = status.id }
        view(projects.id, "Gallery", .gallery) { $0.coverFieldID = coverField }
        view(projects.id, "Budget by status", .chart) {
            var chart = ChartConfig()
            chart.kind = .bar
            chart.categoryFieldID = status.id
            chart.aggregate = .sum
            chart.valueFieldID = budget
            $0.chart = chart
        }
        view(projects.id, "Overview", .dashboard) {
            var count = DashboardWidget(kind: .number, title: "Projects")
            count.aggregate = .count
            var active = DashboardWidget(kind: .number, title: "In flight")
            active.aggregate = .count
            active.filter = condition(status.id, .isAnyOf, .array([.string(status.choice["In progress"]!), .string(status.choice["Blocked"]!)]))
            var spend = DashboardWidget(kind: .number, title: "Total budget")
            spend.aggregate = .sum
            spend.fieldID = budget
            var done = DashboardWidget(kind: .progress, title: "Completed")
            done.filter = condition(status.id, .is, .array([.string(status.choice["Done"]!)]))
            var byStatus = DashboardWidget(kind: .chart, title: "Projects by status")
            var statusChart = ChartConfig()
            statusChart.kind = .donut
            statusChart.categoryFieldID = status.id
            statusChart.aggregate = .count
            byStatus.chart = statusChart
            var budgetByPriority = DashboardWidget(kind: .chart, title: "Budget by priority", span: 2)
            var priorityChart = ChartConfig()
            priorityChart.kind = .bar
            priorityChart.categoryFieldID = priority.id
            priorityChart.aggregate = .sum
            priorityChart.valueFieldID = budget
            budgetByPriority.chart = priorityChart
            var dueSoon = DashboardWidget(kind: .list, title: "Due next", span: 2)
            dueSoon.filter = condition(status.id, .isNot, .array([.string(status.choice["Done"]!)]))
            dueSoon.sort = SortSpec(fieldID: due)
            dueSoon.fieldIDs = [status.id, owner.id, due]
            dueSoon.limit = 5
            $0.dashboard = DashboardConfig(widgets: [count, active, done, byStatus, budgetByPriority, dueSoon, spend])
        }
        let formView = view(projects.id, "Project request", .form) {
            var form = FormConfig()
            form.title = "Request a new project"
            form.description = "Tell us what you need and we'll get it on the roadmap."
            form.fieldIDs = [projects.primary, priority.id, due, budget, notes]
            form.requiredFieldIDs = [projects.primary]
            form.submitLabel = "Submit request"
            form.successMessage = "Thanks! Your request has been added to Projects."
            $0.form = form
        }
        if let grid = doc.views(in: tasks.id).first {
            doc.updateViewConfig(grid.id) { $0.groups = [SortSpec(fieldID: taskProject.id)] ; $0.summaries = [estimate: .sum] }
        }
        if var statusOptions = doc.field(taskStatus.id)?.options {
            statusOptions.defaultValue = .string(taskStatus.choice["Todo"]!)
            doc.updateField(taskStatus.id, options: statusOptions)
        }
        view(tasks.id, "By status", .kanban) { $0.stackFieldID = taskStatus.id }

        var blocked = AutomationTrigger(kind: .recordMatchesConditions, tableID: projects.id)
        blocked.filter = condition(status.id, .is, .array([.string(status.choice["Blocked"]!)]))
        var notify = AutomationAction(kind: .sendNotification)
        notify.title = "🚧 {{trigger.record.Project}} is blocked"
        notify.body = "Owner: {{trigger.record.Owner}} · Due {{trigger.record.Due}}"
        doc.createAutomation(name: "Alert when a project is blocked", trigger: blocked, actions: [notify], enabled: true)

        var doneTrigger = AutomationTrigger(kind: .recordUpdated, tableID: projects.id)
        doneTrigger.watchedFieldIDs = [status.id]
        var setProgress = AutomationAction(kind: .updateRecord)
        setProgress.tableID = projects.id
        setProgress.recordIDTemplate = "{{trigger.record.id}}"
        setProgress.fieldValues = [progress: "100"]
        setProgress.condition = condition(status.id, .is, .array([.string(status.choice["Done"]!)]))
        doc.createAutomation(name: "Set progress to 100% when done", trigger: doneTrigger, actions: [setProgress], enabled: true)

        var formTrigger = AutomationTrigger(kind: .formSubmitted, tableID: projects.id)
        formTrigger.viewID = formView
        var triage = AutomationAction(kind: .updateRecord)
        triage.tableID = projects.id
        triage.fieldValues = [status.id: "Planning", start: "{{today}}"]
        var formNote = AutomationAction(kind: .sendNotification)
        formNote.title = "New project request"
        formNote.body = "{{trigger.record.Project}} ({{trigger.record.Priority}} priority)"
        doc.createAutomation(name: "Triage project requests", trigger: formTrigger, actions: [triage, formNote], enabled: true)

        var weekly = AutomationTrigger(kind: .scheduled)
        weekly.schedule = Schedule(frequency: .weekly, hour: 9, minute: 0, weekday: 2)
        var script = AutomationAction(kind: .runScript)
        script.label = "Summarise projects"
        script.script = """
        const table = base.getTable("Projects");
        const query = await table.selectRecordsAsync();
        const counts = {};
        for (const record of query.records) {
          const status = record.getCellValueAsString("Status") || "No status";
          counts[status] = (counts[status] || 0) + 1;
        }
        const summary = Object.entries(counts).map(([s, n]) => `${n} ${s.toLowerCase()}`).join(", ");
        console.log(summary);
        output.set("summary", summary);
        """
        var weeklyNote = AutomationAction(kind: .sendNotification)
        weeklyNote.title = "Weekly project summary"
        weeklyNote.body = "{{steps.1.summary}}"
        doc.createAutomation(name: "Monday summary", trigger: weekly, actions: [script, weeklyNote], enabled: false)
    }

    func crm() {
        let companies = table("Companies", primary: "Company", description: "Accounts you sell to.")
        let industry = select(companies.id, "Industry", [("Software", .blue), ("Retail", .orange), ("Healthcare", .green), ("Finance", .purple), ("Education", .cyan)])
        let website = field(companies.id, "Website", .url)
        let size = select(companies.id, "Size", [("1–10", .gray), ("11–50", .cyan), ("51–200", .blue), ("200+", .purple)])

        let contacts = table("Contacts", primary: "Name", description: "People at your accounts.")
        let contactCompany = link(contacts.id, to: companies.id, name: "Company", inverseName: "Contacts", single: true)
        let title = field(contacts.id, "Title", .singleLineText)
        let email = field(contacts.id, "Email", .email)
        let phone = field(contacts.id, "Phone", .phoneNumber)

        let deals = table("Deals", primary: "Deal", description: "Your sales pipeline.")
        let stage = select(deals.id, "Stage", [("Lead", .gray), ("Qualified", .cyan), ("Proposal", .blue), ("Negotiation", .purple), ("Won", .green), ("Lost", .red)])
        let dealCompany = link(deals.id, to: companies.id, name: "Company", inverseName: "Deals", single: true)
        let value = field(deals.id, "Value", .currency) { $0.precision = 0 }
        let probability = field(deals.id, "Probability", .percent)
        let close = field(deals.id, "Close date", .date)
        let owner = field(deals.id, "Owner", .singleLineText)
        field(deals.id, "Weighted value", .formula) {
            $0.formula = "{Value} * {Probability}"
            $0.resultFormat = .currency
            $0.precision = 0
        }
        field(companies.id, "Pipeline", .rollup) {
            $0.linkFieldID = dealCompany.inverse
            $0.targetFieldID = value
            $0.rollupFormula = "SUM(values)"
            $0.resultFormat = .currency
            $0.precision = 0
        }

        let companyRows: [(String, String, String, String)] = [
            ("Northwind", "Retail", "https://northwind.example.com", "200+"), ("Globex", "Software", "https://globex.example.com", "51–200"),
            ("Initech", "Finance", "https://initech.example.com", "200+"), ("Umbrella Health", "Healthcare", "https://umbrella.example.com", "51–200"),
            ("Brightside Learning", "Education", "https://brightside.example.com", "11–50"), ("Acme Robotics", "Software", "https://acme.example.com", "11–50"),
        ]
        var companyIDs: [String] = []
        for c in companyRows {
            companyIDs.append(record(companies.id, [companies.primary: .string(c.0), industry.id: .string(industry.choice[c.1]!), website: .string(c.2), size.id: .string(size.choice[c.3]!)]))
        }
        let contactRows: [(String, Int, String)] = [
            ("Olivia Brooks", 0, "Head of Operations"), ("Noah Kim", 1, "CTO"), ("Emma Wilson", 2, "VP Finance"),
            ("Liam Nguyen", 3, "IT Director"), ("Mia Rossi", 4, "Founder"), ("Ethan Clarke", 5, "Engineering Manager"),
        ]
        for c in contactRows {
            let handle = c.0.lowercased().replacingOccurrences(of: " ", with: ".")
            record(contacts.id, [contacts.primary: .string(c.0), contactCompany.id: links(companyIDs[c.1]), title: .string(c.2),
                                 email: .string("\(handle)@example.com"), phone: .string("+1 555 01\(10 + c.1)")])
        }
        let dealRows: [(String, Int, String, Double, Double, Int, String)] = [
            ("Northwind POS rollout", 0, "Negotiation", 84_000, 0.7, 14, "Jordan"), ("Globex platform licence", 1, "Proposal", 56_000, 0.5, 21, "Casey"),
            ("Initech analytics", 2, "Qualified", 38_000, 0.3, 40, "Jordan"), ("Umbrella patient app", 3, "Won", 120_000, 1, -6, "Riley"),
            ("Brightside LMS", 4, "Lead", 12_000, 0.1, 60, "Casey"), ("Acme fleet dashboard", 5, "Proposal", 27_500, 0.5, 18, "Riley"),
            ("Northwind loyalty", 0, "Lost", 22_000, 0, -12, "Jordan"), ("Globex support tier", 1, "Won", 18_000, 1, -20, "Casey"),
        ]
        for d in dealRows {
            record(deals.id, [deals.primary: .string(d.0), dealCompany.id: links(companyIDs[d.1]), stage.id: .string(stage.choice[d.2]!),
                              value: .number(d.3), probability: .number(d.4), close: day(d.5), owner: .string(d.6)])
        }
        if let grid = doc.views(in: deals.id).first {
            doc.updateViewConfig(grid.id) { $0.summaries = [value: .sum]; $0.sorts = [SortSpec(fieldID: close)] }
        }
        view(deals.id, "Pipeline", .kanban) { $0.stackFieldID = stage.id }
        view(deals.id, "Value by stage", .chart) {
            var chart = ChartConfig()
            chart.kind = .donut
            chart.categoryFieldID = stage.id
            chart.aggregate = .sum
            chart.valueFieldID = value
            $0.chart = chart
        }
        view(deals.id, "Close dates", .calendar) { $0.dateFieldID = close; $0.colorFieldID = stage.id }

        var won = AutomationTrigger(kind: .recordMatchesConditions, tableID: deals.id)
        won.filter = condition(stage.id, .is, .array([.string(stage.choice["Won"]!)]))
        var note = AutomationAction(kind: .sendNotification)
        note.title = "🎉 Deal won: {{trigger.record.Deal}}"
        note.body = "{{trigger.record.Value}} with {{trigger.record.Company}}"
        doc.createAutomation(name: "Celebrate won deals", trigger: won, actions: [note], enabled: true)
    }

    func contentCalendar() {
        let posts = table("Posts", primary: "Title", description: "Everything you're publishing.")
        let status = select(posts.id, "Status", [("Idea", .gray), ("Drafting", .yellow), ("In review", .purple), ("Scheduled", .blue), ("Published", .green)])
        let channel = select(posts.id, "Channels", [("Blog", .blue), ("Newsletter", .orange), ("LinkedIn", .cyan), ("Instagram", .pink), ("YouTube", .red)], multi: true)
        let publish = field(posts.id, "Publish date", .date)
        let author = field(posts.id, "Author", .singleLineText)
        let coverField = field(posts.id, "Cover", .attachment)
        let copy = field(posts.id, "Copy", .multilineText)
        field(posts.id, "Words", .formula) { $0.formula = "IF({Copy}, LEN(TRIM({Copy})) - LEN(SUBSTITUTE({Copy}, \" \", \"\")) + 1, 0)" }

        let rows: [(String, String, [String], Int, String, String)] = [
            ("10 tips for remote teams", "Published", ["Blog", "LinkedIn"], -9, "Ava", "Remote work is here to stay. Here are ten habits that keep distributed teams in sync."),
            ("Product update: September", "Scheduled", ["Newsletter", "Blog"], 2, "Marcus", "New automations, faster sync and a refreshed calendar view."),
            ("Behind the scenes at our studio", "Drafting", ["Instagram", "YouTube"], 6, "Priya", "A day in the life of the design team."),
            ("How we cut build times in half", "In review", ["Blog"], 4, "Sam", "Caching, parallelism and a few surprising wins."),
            ("Customer story: Northwind", "Idea", ["Blog", "LinkedIn"], 15, "Diego", ""),
            ("Year in review", "Idea", ["Newsletter", "YouTube"], 28, "Ava", ""),
            ("Hiring: senior engineer", "Published", ["LinkedIn"], -3, "Marcus", "We're growing the platform team."),
            ("Tutorial: formulas 101", "Drafting", ["YouTube", "Blog"], 10, "Priya", "Everything you need to know about formula fields."),
        ]
        for (i, r) in rows.enumerated() {
            record(posts.id, [posts.primary: .string(r.0), status.id: .string(status.choice[r.1]!),
                              channel.id: .array(r.2.map { .string(channel.choice[$0]!) }), publish: day(r.3), author: .string(r.4),
                              coverField: cover(i + 20, name: "post-\(i + 1)"), copy: r.5.isEmpty ? .null : .string(r.5)])
        }
        view(posts.id, "Calendar", .calendar) { $0.dateFieldID = publish; $0.colorFieldID = status.id }
        view(posts.id, "Covers", .gallery) { $0.coverFieldID = coverField }
        view(posts.id, "Workflow", .kanban) { $0.stackFieldID = status.id; $0.coverFieldID = coverField }

        var daily = AutomationTrigger(kind: .scheduled)
        daily.schedule = Schedule(frequency: .daily, hour: 8, minute: 30)
        var find = AutomationAction(kind: .findRecords)
        find.tableID = posts.id
        find.filter = FilterGroup(conditions: [
            FilterCondition(fieldID: publish, op: .is, value: .object(["mode": .string("today")])),
            FilterCondition(fieldID: status.id, op: .isNot, value: .array([.string(status.choice["Published"]!)])),
        ])
        var remind = AutomationAction(kind: .sendNotification)
        remind.title = "Publishing today"
        remind.body = "{{steps.1.titles}}"
        remind.condition = nil
        doc.createAutomation(name: "Morning publishing reminder", trigger: daily, actions: [find, remind], enabled: false)
    }

    func inventory() {
        let suppliers = table("Suppliers", primary: "Supplier", description: "Where stock comes from.")
        let supplierEmail = field(suppliers.id, "Email", .email)
        let lead = field(suppliers.id, "Lead time (days)", .number) { $0.precision = 0 }

        let products = table("Products", primary: "Product", description: "Everything you stock.")
        let sku = field(products.id, "SKU", .singleLineText)
        let category = select(products.id, "Category", [("Apparel", .pink), ("Accessories", .purple), ("Home", .teal), ("Stationery", .orange)])
        let price = field(products.id, "Price", .currency)
        let cost = field(products.id, "Unit cost", .currency)
        let stock = field(products.id, "In stock", .number) { $0.precision = 0 }
        let reorder = field(products.id, "Reorder at", .number) { $0.precision = 0 }
        let supplier = link(products.id, to: suppliers.id, name: "Supplier", inverseName: "Products", single: true)
        let photo = field(products.id, "Photo", .attachment)
        field(products.id, "Margin", .formula) {
            $0.formula = "IF({Price}, ({Price} - {Unit cost}) / {Price}, 0)"
            $0.resultFormat = .percent
        }
        let status = field(products.id, "Stock status", .formula) {
            $0.formula = "IF({In stock} <= {Reorder at}, \"⚠️ Reorder\", \"In stock\")"
        }
        field(suppliers.id, "Units on hand", .rollup) {
            $0.linkFieldID = supplier.inverse
            $0.targetFieldID = stock
            $0.rollupFormula = "SUM(values)"
            $0.precision = 0
        }

        let supplierRows: [(String, String, Double)] = [("Harbor Textiles", "orders@harbor.example.com", 14), ("Paper & Co", "hello@paperco.example.com", 7), ("Loom House", "sales@loom.example.com", 21)]
        var supplierIDs: [String] = []
        for s in supplierRows {
            supplierIDs.append(record(suppliers.id, [suppliers.primary: .string(s.0), supplierEmail: .string(s.1), lead: .number(s.2)]))
        }
        let rows: [(String, String, String, Double, Double, Double, Double, Int)] = [
            ("Canvas tote", "TOTE-01", "Accessories", 28, 9, 42, 20, 0), ("Linen apron", "APRN-02", "Home", 45, 16, 8, 10, 2),
            ("Dot-grid notebook", "NOTE-03", "Stationery", 18, 4.5, 120, 40, 1), ("Merino beanie", "BEAN-04", "Apparel", 35, 11, 15, 12, 2),
            ("Ceramic mug", "MUG-05", "Home", 24, 7, 6, 15, 0), ("Brass pen", "PEN-06", "Stationery", 42, 14, 33, 10, 1),
            ("Organic tee", "TEE-07", "Apparel", 32, 10, 64, 25, 0), ("Wool throw", "THRW-08", "Home", 120, 48, 4, 5, 2),
        ]
        for (i, r) in rows.enumerated() {
            record(products.id, [products.primary: .string(r.0), sku: .string(r.1), category.id: .string(category.choice[r.2]!),
                                 price: .number(r.3), cost: .number(r.4), stock: .number(r.5), reorder: .number(r.6),
                                 supplier.id: links(supplierIDs[r.7]), photo: cover(i + 40, name: r.1.lowercased())])
        }
        if let grid = doc.views(in: products.id).first {
            doc.updateViewConfig(grid.id) { $0.groups = [SortSpec(fieldID: category.id)]; $0.summaries = [stock: .sum] }
        }
        view(products.id, "Low stock", .grid) {
            $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: status, op: .contains, value: .string("Reorder"))])
        }
        view(products.id, "Catalogue", .gallery) { $0.coverFieldID = photo }
        view(products.id, "Stock by category", .chart) {
            var chart = ChartConfig()
            chart.kind = .bar
            chart.categoryFieldID = category.id
            chart.aggregate = .sum
            chart.valueFieldID = stock
            $0.chart = chart
        }

        var low = AutomationTrigger(kind: .recordMatchesConditions, tableID: products.id)
        low.filter = FilterGroup(conditions: [FilterCondition(fieldID: status, op: .contains, value: .string("Reorder"))])
        var note = AutomationAction(kind: .sendNotification)
        note.title = "Low stock: {{trigger.record.Product}}"
        note.body = "Only {{trigger.record.In stock}} left — reorder from {{trigger.record.Supplier}}."
        doc.createAutomation(name: "Low stock alert", trigger: low, actions: [note], enabled: true)
    }
}
