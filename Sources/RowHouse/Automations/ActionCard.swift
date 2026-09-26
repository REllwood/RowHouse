import RowHouseCore
import SwiftUI

struct ActionCard: View {
    let session: BaseSession
    let engine: AutomationEngine
    @Binding var automation: AutomationModel
    let index: Int
    @State private var showCondition = false

    private var document: BaseDocument { session.document }

    var body: some View {
        if index < automation.actions.count {
            let action = $automation.actions[index]
            let tokens = engine.availableTokens(for: automation, stepIndex: index)
            StepCard(number: "STEP \(index + 1)", title: action.wrappedValue.label?.isEmpty == false ? action.wrappedValue.label! : action.wrappedValue.kind.displayName, symbol: action.wrappedValue.kind.symbolName, tint: tint(action.wrappedValue.kind), trailing: {
                AnyView(HStack(spacing: 2) {
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(index == automation.actions.count - 1)
                    Button { remove() } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless))
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Step label (optional)", text: Binding(get: { action.wrappedValue.label ?? "" }, set: { action.wrappedValue.label = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    RepeatOptions(engine: engine, automation: $automation, index: index)
                    ActionOptions(session: session, action: action, tokens: tokens, triggerTableID: automation.trigger.tableID,
                                  defaultRecordID: action.wrappedValue.repeatFrom == nil ? "{{trigger.record.id}}" : (itemTableID != nil ? "{{item.id}}" : "{{item}}"))
                    if let tableID = conditionTableID {
                        DisclosureGroup(isExpanded: Binding(get: { showCondition || !(action.wrappedValue.condition?.isEmpty ?? true) }, set: { showCondition = $0 })) {
                            FilterEditor(document: document, tableID: tableID, filter: action.wrappedValue.condition ?? FilterGroup(), title: "") { action.wrappedValue.condition = $0.isEmpty ? nil : $0 }
                                .id(tableID)
                                .padding(.top, 6)
                        } label: {
                            Text(itemTableID != nil ? "Only run for items whose record matches conditions" : "Only run this step if the trigger record matches conditions")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Table of the records this step repeats over, when it repeats over records.
    private var itemTableID: String? {
        engine.repeatItemTableID(for: automation, stepIndex: index)
    }

    /// The table step conditions are written against: the repeated records' table, else the trigger's.
    private var conditionTableID: String? {
        itemTableID ?? (automation.trigger.kind.providesRecord ? automation.trigger.tableID : nil)
    }

    private func move(_ delta: Int) {
        let j = index + delta
        guard j >= 0, j < automation.actions.count else { return }
        automation.actions.swapAt(index, j)
        // Keep "repeat for each" pointing at the same steps under their new numbers.
        let a = index + 1, b = j + 1
        for i in automation.actions.indices {
            if automation.actions[i].repeatFrom == a {
                automation.actions[i].repeatFrom = b
            } else if automation.actions[i].repeatFrom == b {
                automation.actions[i].repeatFrom = a
            }
        }
    }

    private func remove() {
        let removed = index + 1
        automation.actions.remove(at: index)
        for i in automation.actions.indices {
            guard let from = automation.actions[i].repeatFrom else { continue }
            if from == removed {
                automation.actions[i].repeatFrom = nil
                automation.actions[i].repeatPath = nil
            } else if from > removed {
                automation.actions[i].repeatFrom = from - 1
            }
        }
    }

    private func tint(_ kind: ActionKind) -> Color {
        switch kind {
        case .createRecord, .updateRecord: .green
        case .deleteRecord: .red
        case .findRecords: .teal
        case .sendNotification: .orange
        case .httpRequest: .purple
        case .runScript: .indigo
        case .runShortcut: .pink
        case .sendEmail: .cyan
        }
    }
}

/// "Repeat for each item in…": runs a step once per item of an earlier step's list.
private struct RepeatOptions: View {
    let engine: AutomationEngine
    @Binding var automation: AutomationModel
    let index: Int

    var body: some View {
        let sources = engine.repeatSources(for: automation, before: index)
        if index < automation.actions.count, !sources.isEmpty || automation.actions[index].repeatFrom != nil {
            let action = automation.actions[index]
            let current = action.repeatFrom.flatMap { from in sources.first { $0.step == from } }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Repeat for each item in", selection: Binding(get: { action.repeatFrom ?? 0 }, set: { choose($0, sources: sources) })) {
                    Text("Don't repeat").tag(0)
                    ForEach(sources, id: \.step) { source in
                        Text(source.path == "records" ? "\(source.title) › Records" : source.title).tag(source.step)
                    }
                    if let from = action.repeatFrom, current == nil {
                        Text("Step \(from) (unavailable)").tag(from)
                    }
                }
                .frame(maxWidth: 460)
                if let from = action.repeatFrom {
                    if current == nil {
                        Label("Step \(from) doesn't come before this step or has no list. Choose another list.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if current?.path == nil {
                        HStack {
                            Text("List in its output").font(.callout)
                            TextField("", text: Binding(get: { action.repeatPath ?? "" }, set: { automation.actions[index].repeatPath = $0.isEmpty ? nil : $0 }),
                                      prompt: Text(automation.actions[from - 1].kind == .httpRequest ? "json.items" : "items"))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 200)
                        }
                    }
                    Text("Runs this step once per item, up to \(AutomationEngine.maxRepeatItems) per run. Use {{item}} values and {{index}} in its settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func choose(_ step: Int, sources: [AutomationEngine.RepeatSource]) {
        var action = automation.actions[index]
        let oldConditionTable = engine.repeatItemTableID(for: automation, stepIndex: index) ?? triggerRecordTable
        if step == 0 {
            action.repeatFrom = nil
            action.repeatPath = nil
            if Self.automaticRecordIDs.contains(action.recordIDTemplate ?? "") {
                action.recordIDTemplate = triggerRecordTable == nil ? nil : "{{trigger.record.id}}"
            }
        } else {
            let source = sources.first { $0.step == step }
            action.repeatFrom = step
            action.repeatPath = source?.path
            if action.kind == .updateRecord || action.kind == .deleteRecord {
                // Point the step at each item rather than the trigger record, unless it was customised.
                if Self.automaticRecordIDs.contains(action.recordIDTemplate ?? "") {
                    action.recordIDTemplate = source?.tableID != nil ? "{{item.id}}" : "{{item}}"
                }
                if action.kind == .updateRecord, let tableID = source?.tableID, action.tableID != tableID, action.fieldValues?.isEmpty ?? true {
                    action.tableID = tableID
                }
            }
        }
        automation.actions[index] = action
        // Conditions name fields of one table; drop them when they'd now apply to another table's records.
        let newConditionTable = engine.repeatItemTableID(for: automation, stepIndex: index) ?? triggerRecordTable
        if newConditionTable != oldConditionTable { automation.actions[index].condition = nil }
    }

    private var triggerRecordTable: String? {
        automation.trigger.kind.providesRecord ? automation.trigger.tableID : nil
    }

    /// Record ID settings that just follow the trigger or the item, which switching lists may replace.
    private static let automaticRecordIDs: Set<String> = ["", "{{trigger.record.id}}", "{{item.id}}", "{{item}}"]
}

private struct ActionOptions: View {
    let session: BaseSession
    @Binding var action: AutomationAction
    let tokens: [TemplateRenderer.Token]
    let triggerTableID: String?
    let defaultRecordID: String
    @State private var shortcuts: [String] = []

    private var document: BaseDocument { session.document }

    var body: some View {
        switch action.kind {
        case .createRecord, .updateRecord:
            tablePicker
            if action.kind == .updateRecord {
                TemplateField(title: "Record ID", text: Binding(get: { action.recordIDTemplate ?? defaultRecordID }, set: { action.recordIDTemplate = $0 }), tokens: tokens)
            }
            if let tableID = action.tableID {
                FieldValuesEditor(document: document, tableID: tableID, values: Binding(get: { action.fieldValues ?? [:] }, set: { action.fieldValues = $0.isEmpty ? nil : $0 }), tokens: tokens)
            }
        case .deleteRecord:
            TemplateField(title: "Record ID", text: Binding(get: { action.recordIDTemplate ?? defaultRecordID }, set: { action.recordIDTemplate = $0 }), tokens: tokens)
        case .findRecords:
            tablePicker
            if let tableID = action.tableID {
                FilterEditor(document: document, tableID: tableID, filter: action.filter ?? FilterGroup(), title: "") { action.filter = $0.isEmpty ? nil : $0 }
                    .id(tableID)
                Stepper("Return at most \(action.limit ?? 100) records", value: Binding(get: { action.limit ?? 100 }, set: { action.limit = $0 }), in: 1...1000, step: 10)
                    .frame(maxWidth: 320)
            }
        case .sendNotification:
            TemplateField(title: "Title", text: Binding(get: { action.title ?? "" }, set: { action.title = $0 }), tokens: tokens)
            TemplateField(title: "Message", text: Binding(get: { action.body ?? "" }, set: { action.body = $0 }), tokens: tokens, multiline: true)
        case .httpRequest:
            HStack {
                Picker("", selection: Binding(get: { action.method ?? "POST" }, set: { action.method = $0 })) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                TemplateField(title: "", text: Binding(get: { action.url ?? "" }, set: { action.url = $0 }), tokens: tokens, prompt: "https://example.com/webhook")
            }
            KeyValueEditor(title: "Headers", pairs: Binding(get: { action.headers ?? [:] }, set: { action.headers = $0.isEmpty ? nil : $0 }), tokens: tokens)
            if (action.method ?? "POST") != "GET" {
                TemplateField(title: "Body", text: Binding(get: { action.body ?? "" }, set: { action.body = $0 }), tokens: tokens, multiline: true, monospaced: true)
                Text("Use {{…| json}} to insert values safely inside JSON.").font(.caption).foregroundStyle(.secondary)
            }
        case .runScript:
            KeyValueEditor(title: "Input variables (input.config())", pairs: Binding(get: { action.inputs ?? [:] }, set: { action.inputs = $0.isEmpty ? nil : $0 }), tokens: tokens)
            VStack(alignment: .leading, spacing: 4) {
                Text("JavaScript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { action.script ?? "" }, set: { action.script = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                Text("Airtable-style API: base.getTable(name), table.selectRecordsAsync(), record.getCellValue(field), table.createRecordAsync(fields), table.updateRecordAsync(id, fields), fetch(url), output.set(key, value). Scripts stop after 30 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .runShortcut:
            HStack {
                TemplateField(title: "Shortcut", text: Binding(get: { action.shortcutName ?? "" }, set: { action.shortcutName = $0 }), tokens: [], prompt: "Shortcut name")
                if !shortcuts.isEmpty {
                    Menu("Choose") {
                        ForEach(shortcuts, id: \.self) { name in Button(name) { action.shortcutName = name } }
                    }
                    .fixedSize()
                }
            }
            TemplateField(title: "Input", text: Binding(get: { action.body ?? "" }, set: { action.body = $0 }), tokens: tokens, multiline: true)
            Text("Runs a shortcut from the Shortcuts app with this text as its input. Its output is available to later steps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .task { shortcuts = await SystemAutomationServices.shortcutNames() }
        case .sendEmail:
            TemplateField(title: "To", text: Binding(get: { action.to ?? "" }, set: { action.to = $0 }), tokens: tokens, prompt: "name@example.com, another@example.com")
            HStack(alignment: .top) {
                TemplateField(title: "Cc", text: Binding(get: { action.cc ?? "" }, set: { action.cc = $0.isEmpty ? nil : $0 }), tokens: tokens)
                TemplateField(title: "Bcc", text: Binding(get: { action.bcc ?? "" }, set: { action.bcc = $0.isEmpty ? nil : $0 }), tokens: tokens)
            }
            TemplateField(title: "Subject", text: Binding(get: { action.subject ?? "" }, set: { action.subject = $0 }), tokens: tokens)
            TemplateField(title: "Message", text: Binding(get: { action.body ?? "" }, set: { action.body = $0 }), tokens: tokens, multiline: true)
            Text("Sent from your default account in the Mail app. Separate addresses with commas. The first time, macOS asks whether RowHouse may control Mail.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tablePicker: some View {
        Picker("Table", selection: Binding(get: { action.tableID ?? "" }, set: {
            action.tableID = $0.isEmpty ? nil : $0
            action.fieldValues = nil
            action.filter = nil
        })) {
            Text("Choose a table…").tag("")
            ForEach(document.tables) { Text($0.name).tag($0.id) }
        }
        .frame(maxWidth: 360)
    }
}

/// A text field whose value can contain {{placeholders}}, with an "Insert value" menu.
struct TemplateField: View {
    let title: String
    @Binding var text: String
    let tokens: [TemplateRenderer.Token]
    var multiline = false
    var monospaced = false
    var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                if multiline {
                    TextEditor(text: $text)
                        .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                } else {
                    TextField("", text: $text, prompt: Text(prompt))
                        .textFieldStyle(.roundedBorder)
                        .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                }
                if !tokens.isEmpty {
                    Menu {
                        ForEach(tokens, id: \.path) { token in
                            Button(token.label) { text += "{{\(token.path)}}" }
                        }
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Insert a value from the trigger or an earlier step")
                }
            }
        }
    }
}

private struct FieldValuesEditor: View {
    let document: BaseDocument
    let tableID: String
    @Binding var values: [String: String]
    let tokens: [TemplateRenderer.Token]

    var body: some View {
        let fields = document.fields(in: tableID).filter { $0.isEditable }
        VStack(alignment: .leading, spacing: 8) {
            Text("Set fields").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(fields.filter { values[$0.id] != nil }) { field in
                HStack(alignment: .top) {
                    FieldLabel(field: field)
                        .frame(width: 150, alignment: .leading)
                        .padding(.top, 4)
                    TemplateField(title: "", text: Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 }), tokens: tokens, prompt: hint(field))
                    Button { values[field.id] = nil } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                }
            }
            Menu {
                ForEach(fields.filter { values[$0.id] == nil }) { f in
                    Button { values[f.id] = "" } label: { Label(f.name, systemImage: f.type.symbolName) }
                }
            } label: {
                Label("Choose field", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func hint(_ field: FieldModel) -> String {
        switch field.type {
        case .singleSelect: "Option name, e.g. \(field.choices.first?.name ?? "Done")"
        case .multipleSelects: "Comma-separated option names"
        case .checkbox: "true or false"
        case .date: "Date, e.g. {{today}}"
        case .link: "Record ID or name, e.g. {{trigger.record.id}}"
        case .number, .currency, .percent, .rating: "Number"
        default: "Text or {{value}}"
        }
    }
}

private struct KeyValueEditor: View {
    let title: String
    @Binding var pairs: [String: String]
    let tokens: [TemplateRenderer.Token]
    @State private var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach($rows) { $row in
                HStack {
                    TextField("Name", text: $row.key).textFieldStyle(.roundedBorder).frame(width: 150)
                    TemplateField(title: "", text: $row.value, tokens: tokens)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button {
                rows.append(Row(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .onAppear { rows = pairs.sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) } }
        .onChange(of: rows) { _, new in
            var dict: [String: String] = [:]
            for r in new where !r.key.trimmingCharacters(in: .whitespaces).isEmpty { dict[r.key.trimmingCharacters(in: .whitespaces)] = r.value }
            if dict != pairs { pairs = dict }
        }
    }
}

struct RunHistory: View {
    let runs: [AutomationRun]

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath", description: Text("Runs from every Mac that shares this base appear here."))
        } else {
            List(runs) { run in
                DisclosureGroup {
                    RunDetail(run: run)
                } label: {
                    HStack(spacing: 10) {
                        StatusIcon(status: run.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.trigger).lineLimit(1)
                            Text("\(run.startedAt.formatted(date: .abbreviated, time: .standard)) · \(run.deviceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let finished = run.finishedAt {
                            Text(String(format: "%.1fs", finished.timeIntervalSince(run.startedAt)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct RunDetail: View {
    let run: AutomationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusIcon(status: run.status)
                Text(run.status == .succeeded ? "Run succeeded" : (run.status == .failed ? "Run failed" : run.status.rawValue.capitalized))
                    .font(.headline)
            }
            ForEach(run.steps) { step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusIcon(status: step.status).font(.caption)
                        Text(step.name).font(.callout.weight(.semibold))
                    }
                    if !step.message.isEmpty {
                        Text(step.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !step.logs.isEmpty {
                        Text(step.logs.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }
}

struct StatusIcon: View {
    let status: RunStatus

    var body: some View {
        switch status {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .running: Image(systemName: "hourglass").foregroundStyle(.orange)
        }
    }
}
