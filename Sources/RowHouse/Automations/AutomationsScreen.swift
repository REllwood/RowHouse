import RowHouseCore
import SwiftUI

struct AutomationsScreen: View {
    let session: BaseSession
    let engine: AutomationEngine
    var state: WindowState
    @State private var selection: String?

    private var document: BaseDocument { session.document }

    var body: some View {
        HStack(spacing: 0) {
            AutomationList(session: session, engine: engine, selection: $selection)
                .frame(width: 290)
            Divider()
            if let id = selection, document.automation(id) != nil {
                AutomationEditor(session: session, engine: engine, automationID: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("Automations", systemImage: "bolt.fill")
                } description: {
                    Text("Automations run actions when records change, forms are submitted, buttons are clicked or on a schedule. Create one to get started.")
                } actions: {
                    Button("Create automation") { selection = createDefault() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Automations")
        .navigationSubtitle(document.info.name)
        .onAppear {
            if selection == nil { selection = document.automations.first?.id }
        }
    }

    private func createDefault() -> String {
        var trigger = AutomationTrigger(kind: .recordCreated, tableID: document.tables.first?.id)
        trigger.tableID = document.tables.first?.id
        var action = AutomationAction(kind: .sendNotification)
        action.title = "New record"
        action.body = "{{trigger.record.title}}"
        return document.createAutomation(name: "Untitled automation", trigger: trigger, actions: [action], enabled: false)
    }
}

private struct AutomationList: View {
    let session: BaseSession
    let engine: AutomationEngine
    @Binding var selection: String?

    var body: some View {
        let document = session.document
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(document.automations) { automation in
                    HStack(spacing: 10) {
                        Image(systemName: automation.trigger.kind.symbolName)
                            .foregroundStyle(automation.enabled ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(automation.name).lineLimit(1)
                            Text(automation.trigger.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { automation.enabled }, set: { on in
                            document.updateAutomation(automation.id, actionName: on ? "Turn On Automation" : "Turn Off Automation") { $0.enabled = on }
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .padding(.vertical, 3)
                    .tag(automation.id)
                    .contextMenu {
                        Button("Duplicate") { selection = document.duplicateAutomation(automation.id) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            if selection == automation.id { selection = nil }
                            document.deleteAutomation(automation.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(TriggerKind.allCases, id: \.self) { kind in
                        Button {
                            var trigger = AutomationTrigger(kind: kind, tableID: kind.providesRecord ? document.tables.first?.id : nil)
                            if kind == .scheduled { trigger.schedule = Schedule() }
                            if kind == .recordEntersView { trigger.viewID = TriggerCard.firstRecordView(document, tableID: trigger.tableID) }
                            selection = document.createAutomation(name: "Untitled automation", trigger: trigger)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("New automation", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                HostInfo(document: document)
            }
            .padding(12)
        }
    }
}

private struct HostInfo: View {
    let document: BaseDocument

    var body: some View {
        let isHost = document.effectiveAutomationHost == document.deviceID
        VStack(alignment: .leading, spacing: 4) {
            Label(isHost ? "Scheduled automations run on this Mac" : "Scheduled automations run on \(document.deviceName(for: document.effectiveAutomationHost))",
                  systemImage: isHost ? "desktopcomputer" : "desktopcomputer.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isHost {
                Button("Run them on this Mac instead") { document.setAutomationHost(document.deviceID) }
                    .controlSize(.small)
            }
            Text("Record automations run on the Mac where the change was made, so nothing runs twice.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Edits one automation. Edits go to a local draft that's saved shortly after typing stops.
struct AutomationEditor: View {
    let session: BaseSession
    let engine: AutomationEngine
    let automationID: String
    @State private var draft: AutomationModel?
    @State private var saveTask: Task<Void, Never>?
    @State private var tab = 0
    @State private var testing = false
    @State private var testResult: AutomationRun?
    @State private var confirmDelete = false

    private var document: BaseDocument { session.document }

    var body: some View {
        VStack(spacing: 0) {
            if let binding = Binding($draft) {
                header(binding)
                Divider()
                if tab == 0 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            TriggerCard(document: document, engine: engine, automation: binding)
                            ForEach(Array(binding.actions.wrappedValue.enumerated()), id: \.element.id) { index, _ in
                                Connector()
                                ActionCard(session: session, engine: engine, automation: binding, index: index)
                            }
                            Connector()
                            AddActionMenu(automation: binding)
                            if let testResult {
                                RunDetail(run: testResult)
                                    .padding(.top, 20)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    RunHistory(runs: session.runs.filter { $0.automationID == automationID })
                }
            }
        }
        .onAppear { draft = document.automation(automationID) }
        .onChange(of: document.automationRevision) { _, _ in
            // Pick up edits from other Macs when nothing is waiting to be saved here.
            if saveTask == nil, let fresh = document.automation(automationID), fresh != draft { draft = fresh }
        }
        .onChange(of: draft) { _, new in
            guard let new, new != document.automation(automationID) else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                save(new)
            }
        }
        .onDisappear {
            if let draft, draft != document.automation(automationID) { save(draft) }
        }
        .confirmationDialog("Delete this automation?", isPresented: $confirmDelete) {
            Button("Delete Automation", role: .destructive) { document.deleteAutomation(automationID) }
        }
    }

    private func save(_ model: AutomationModel) {
        saveTask = nil
        document.updateAutomation(automationID) { $0 = model }
    }

    private func header(_ automation: Binding<AutomationModel>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Automation name", text: automation.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                TextField("Add a description", text: automation.description)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("Configure").tag(0)
                Text("Run history").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Button {
                test()
            } label: {
                if testing { ProgressView().controlSize(.small) } else { Label("Test", systemImage: "play.fill") }
            }
            .disabled(testing)
            .help("Run the automation now using the first matching record")
            Toggle(isOn: automation.enabled) { Text(automation.enabled.wrappedValue ? "On" : "Off") }
                .toggleStyle(.switch)
            Menu {
                Button("Duplicate") { _ = document.duplicateAutomation(automationID) }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func test() {
        if let draft { save(draft) }
        testing = true
        testResult = nil
        Task {
            testResult = await engine.runNow(automationID)
            testing = false
        }
    }
}

private struct Connector: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2, height: 22)
            .padding(.leading, 28)
    }
}

struct StepCard<Content: View>: View {
    let number: String
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var trailing: () -> AnyView
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(number).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                }
                Spacer()
                trailing()
            }
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct TriggerCard: View {
    let document: BaseDocument
    let engine: AutomationEngine
    @Binding var automation: AutomationModel

    /// The view a new "enters view" trigger starts with: the table's first view that can hold records.
    static func firstRecordView(_ document: BaseDocument, tableID: String?) -> String? {
        guard let tableID else { return nil }
        return document.views(in: tableID).first { $0.type != .form }?.id
    }

    var body: some View {
        StepCard(number: "TRIGGER", title: automation.trigger.kind.displayName, symbol: automation.trigger.kind.symbolName, tint: .blue, trailing: {
            AnyView(Menu("Change") {
                ForEach(TriggerKind.allCases, id: \.self) { kind in
                    Button {
                        var t = AutomationTrigger(kind: kind, tableID: kind.providesRecord ? (automation.trigger.tableID ?? document.tables.first?.id) : nil)
                        if kind == .scheduled { t.schedule = automation.trigger.schedule ?? Schedule() }
                        if kind == .recordEntersView { t.viewID = Self.firstRecordView(document, tableID: t.tableID) }
                        // Keep a working webhook URL when the webhook trigger is picked again.
                        if kind == .webhookReceived, let token = automation.trigger.webhookToken { t.webhookToken = token }
                        automation.trigger = t
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                    }
                }
            }
            .fixedSize())
        }) {
            triggerOptions
        }
    }

    @ViewBuilder
    private var triggerOptions: some View {
        let kind = automation.trigger.kind
        if kind.providesRecord {
            Picker("Table", selection: Binding(get: { automation.trigger.tableID ?? "" }, set: { id in
                guard id != (automation.trigger.tableID ?? "") else { return }
                automation.trigger.tableID = id.isEmpty ? nil : id
                // Views belong to one table, so a form or "enters view" choice can't carry over.
                automation.trigger.viewID = kind == .recordEntersView ? Self.firstRecordView(document, tableID: automation.trigger.tableID) : nil
            })) {
                ForEach(document.tables) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 360)
        }
        switch kind {
        case .recordUpdated:
            if let tableID = automation.trigger.tableID {
                FieldMultiPicker(title: "Watch", document: document, tableID: tableID, selection: Binding(get: { Set(automation.trigger.watchedFieldIDs ?? []) }, set: { automation.trigger.watchedFieldIDs = $0.isEmpty ? nil : Array($0) }))
                    .frame(maxWidth: 420, alignment: .leading)
            }
        case .recordMatchesConditions:
            if let tableID = automation.trigger.tableID {
                Text("Runs when a record starts matching these conditions.").font(.caption).foregroundStyle(.secondary)
                FilterEditor(document: document, tableID: tableID, filter: automation.trigger.filter ?? FilterGroup(), title: "") { automation.trigger.filter = $0 }
                    .id(tableID)
            }
        case .formSubmitted:
            if let tableID = automation.trigger.tableID {
                let forms = document.views(in: tableID).filter { $0.type == .form }
                Picker("Form", selection: Binding(get: { automation.trigger.viewID ?? "" }, set: { automation.trigger.viewID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose a form…").tag("")
                    ForEach(forms) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 360)
                if forms.isEmpty {
                    Text("This table has no form views yet. Create one from the views list.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .recordEntersView:
            if let tableID = automation.trigger.tableID {
                let views = document.views(in: tableID).filter { $0.type != .form }
                Picker("View", selection: Binding(get: {
                    views.contains { $0.id == automation.trigger.viewID } ? automation.trigger.viewID ?? "" : ""
                }, set: { automation.trigger.viewID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose a view…").tag("")
                    ForEach(views) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 360)
                Text("Runs when a record starts appearing in this view because of the view's filters. Records already in the view when the automation is turned on don't count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .webhookReceived:
            WebhookTriggerOptions(engine: engine, automation: $automation)
        case .scheduled:
            ScheduleEditor(schedule: Binding(get: { automation.trigger.schedule ?? Schedule() }, set: { automation.trigger.schedule = $0 }))
        case .buttonClicked:
            Text("Add a Button field set to “Run automation” and choose this automation. Clicking it runs these actions for that record.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .manual:
            Text("Runs only when you click Test.").font(.caption).foregroundStyle(.secondary)
        case .recordCreated:
            Text("Runs each time a record is added to this table on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct WebhookTriggerOptions: View {
    let engine: AutomationEngine
    @Binding var automation: AutomationModel
    @AppStorage(WebhookServer.enabledKey) private var serverEnabled = false
    @AppStorage(WebhookServer.portKey) private var storedPort = Webhooks.defaultPort
    @State private var confirmRegenerate = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let token = automation.trigger.webhookToken, !token.isEmpty {
                let url = Webhooks.url(automationID: automation.id, token: token, port: WebhookServer.port)
                HStack(spacing: 8) {
                    Text(url)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 480, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("Regenerate Token…") { confirmRegenerate = true }
                }
                .onChange(of: url) { _, _ in copied = false }
            } else {
                Button("Create Webhook URL") { automation.trigger.webhookToken = Webhooks.makeToken() }
            }
            Text("POST a JSON, form or text body (up to 1 MB), or GET with a query string. Later steps can use {{trigger.body.name}}, {{trigger.query.name}} and {{trigger.headers.x-name}}. Keep the URL secret: anyone with it can run this automation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !serverEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Webhooks are turned off on this Mac.").font(.callout)
                    SettingsLink { Text("Open Settings…") }
                        .controlSize(.small)
                }
            } else if case .failed(let message) = WebhookServer.shared.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let sample = engine.lastWebhookRequests[automation.id] {
                Text("Last request: \(sample.method) with \(summary(sample)). Test runs use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Regenerate the webhook token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { automation.trigger.webhookToken = Webhooks.makeToken() }
        } message: {
            Text("The current URL stops working. Update anything that calls it.")
        }
    }

    private func summary(_ request: WebhookRequest) -> String {
        switch request.body {
        case .object(let fields): return fields.isEmpty ? "an empty body" : "fields " + fields.keys.sorted().joined(separator: ", ")
        case .array(let items): return "a list of \(items.count)"
        case .string: return "a text body"
        case .null: return request.query.isEmpty ? "no body" : "query " + request.query.keys.sorted().joined(separator: ", ")
        default: return "a body"
        }
    }
}

private struct ScheduleEditor: View {
    @Binding var schedule: Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Repeat", selection: $schedule.frequency) {
                ForEach(ScheduleFrequency.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .frame(maxWidth: 300)
            HStack {
                switch schedule.frequency {
                case .minutes:
                    Stepper("Every \(max(5, schedule.interval)) minutes", value: $schedule.interval, in: 5...720, step: 5)
                case .hourly:
                    Stepper("Every \(max(1, schedule.interval)) hour\(schedule.interval > 1 ? "s" : "")", value: $schedule.interval, in: 1...24)
                    Stepper("at :\(String(format: "%02d", schedule.minute))", value: $schedule.minute, in: 0...59, step: 5)
                case .daily:
                    Stepper("Every \(max(1, schedule.interval)) day\(schedule.interval > 1 ? "s" : "")", value: $schedule.interval, in: 1...30)
                    timePicker
                case .weekly:
                    Picker("On", selection: $schedule.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                    .frame(width: 180)
                    timePicker
                case .monthly:
                    Stepper("On day \(schedule.dayOfMonth)", value: $schedule.dayOfMonth, in: 1...28)
                    timePicker
                }
            }
            Text(schedule.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timePicker: some View {
        DatePicker("at", selection: Binding(get: {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            schedule.hour = Calendar.current.component(.hour, from: d)
            schedule.minute = Calendar.current.component(.minute, from: d)
        }), displayedComponents: .hourAndMinute)
        .fixedSize()
    }
}

private struct AddActionMenu: View {
    @Binding var automation: AutomationModel

    var body: some View {
        Menu {
            ForEach(ActionKind.allCases, id: \.self) { kind in
                Button {
                    var action = AutomationAction(kind: kind)
                    switch kind {
                    case .createRecord, .findRecords:
                        action.tableID = automation.trigger.tableID
                    case .updateRecord, .deleteRecord:
                        action.tableID = automation.trigger.tableID
                        action.recordIDTemplate = "{{trigger.record.id}}"
                    case .httpRequest:
                        action.method = "POST"
                        action.body = "{\n  \"name\": {{trigger.record.title | json}}\n}"
                    case .runScript:
                        action.script = "// The trigger record is available through input.config()\nconst { recordId } = input.config();\nconst table = base.getTable(\"\(automation.trigger.tableID ?? "")\");\nconsole.log(`Running for ${recordId}`);\noutput.set(\"done\", true);\n"
                        action.inputs = ["recordId": "{{trigger.record.id}}"]
                    case .sendNotification:
                        action.title = "{{trigger.record.title}}"
                    case .sendEmail:
                        action.subject = automation.trigger.kind.providesRecord ? "{{trigger.record.title}}" : automation.name
                    default:
                        break
                    }
                    automation.actions.append(action)
                } label: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
        } label: {
            Label("Add action", systemImage: "plus.circle.fill")
                .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.leading, 12)
    }
}
