import RowHouseCore
import SwiftUI

/// Form view: a builder on the left and a live, fillable form on the right. Submitting creates a
/// record and fires "When a form is submitted" automations.
struct FormView: View {
    @Environment(AppModel.self) private var app
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    @State private var draft: [String: JSONValue] = [:]
    @State private var submitted = false
    @State private var missing: Set<String> = []
    @State private var showBuilder = true

    private var document: BaseDocument { session.document }
    private var form: FormConfig { view.config.form ?? FormConfig() }

    var body: some View {
        HStack(spacing: 0) {
            if showBuilder {
                FormBuilder(document: document, view: view)
                    .frame(width: 300)
                Divider()
            }
            ScrollView {
                VStack(spacing: 0) {
                    if submitted {
                        successCard
                    } else {
                        formCard
                    }
                }
                .frame(maxWidth: 640)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .topTrailing) {
                Toggle(isOn: $showBuilder) { Label("Edit form", systemImage: "slider.horizontal.3") }
                    .toggleStyle(.button)
                    .padding(12)
            }
        }
        .onAppear(perform: applyPrefill)
        .onChange(of: state.formPrefill[view.id]) { _, _ in applyPrefill() }
    }

    private var includedFields: [FieldModel] {
        let all = document.fields(in: view.tableID).filter { $0.isEditable }
        guard let ids = form.fieldIDs else { return all }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    /// Fields whose "show only if" conditions hold for the answers so far.
    private var visibleFields: [FieldModel] {
        includedFields.filter { f in
            guard let condition = form.fieldConditions?[f.id], !condition.isEmpty else { return true }
            return document.matches(draft: draft, tableID: view.tableID, filter: condition)
        }
    }

    private func applyPrefill() {
        guard let prefill = state.formPrefill[view.id] else { return }
        state.formPrefill[view.id] = nil
        for (name, text) in prefill {
            guard let field = document.field(named: name, in: view.tableID) ?? document.field(name), field.tableID == view.tableID, field.isEditable else { continue }
            let value = document.parseValue(text, for: field, createMissingChoices: false)
            if !value.isNull { draft[field.id] = value }
        }
        submitted = false
    }

    private var formCard: some View {
        let required = Set(form.requiredFieldIDs ?? [])
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(form.title?.isEmpty == false ? form.title! : (document.table(view.tableID)?.name ?? "Form"))
                    .font(.largeTitle.bold())
                if let d = form.description, !d.isEmpty {
                    Text(d).font(.title3).foregroundStyle(.secondary)
                }
            }
            ForEach(visibleFields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) {
                        Text(field.name).font(.headline)
                        if required.contains(field.id) { Text("*").foregroundStyle(.red).font(.headline) }
                    }
                    if !field.description.isEmpty {
                        Text(field.description).font(.callout).foregroundStyle(.secondary)
                    }
                    FieldValueEditor(session: session, field: field, value: Binding(get: { draft[field.id] ?? .null }, set: {
                        draft[field.id] = $0
                        missing.remove(field.id)
                    }), style: .form)
                    if missing.contains(field.id) {
                        Text("This field is required").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Button {
                submit()
            } label: {
                Text(form.submitLabel?.isEmpty == false ? form.submitLabel! : "Submit")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var successCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text(form.successMessage?.isEmpty == false ? form.successMessage! : "Thanks for submitting the form!")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Button("Submit another response") {
                draft = [:]
                submitted = false
            }
            .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func submit() {
        let required = Set(form.requiredFieldIDs ?? [])
        let shown = visibleFields
        let shownIDs = Set(shown.map(\.id))
        missing = Set(shown.filter { required.contains($0.id) && (draft[$0.id]?.isEmptyCell ?? true) && !(draft[$0.id]?.boolValue ?? false) }.map(\.id))
        guard missing.isEmpty else { return }
        // Answers to questions that ended up hidden aren't saved.
        let values = draft.filter { !$0.value.isNull && shownIDs.contains($0.key) }
        let id = document.createRecord(in: view.tableID, values: values)
        app.engine(session.id)?.formSubmitted(viewID: view.id, recordID: id)
        submitted = true
    }
}

private struct FormBuilder: View {
    let document: BaseDocument
    let view: ViewModel

    var body: some View {
        let form = view.config.form ?? FormConfig()
        let editable = document.fields(in: view.tableID).filter { $0.isEditable }
        let included = form.fieldIDs ?? editable.map(\.id)
        let required = Set(form.requiredFieldIDs ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Form settings").font(.headline)
                labeled("Title") {
                    CommitTextField(text: form.title ?? "") { v in update { $0.title = v } }
                }
                labeled("Description") {
                    CommitTextEditor(text: form.description ?? "", minHeight: 60) { v in update { $0.description = v } }
                }
                labeled("Submit button") {
                    CommitTextField(text: form.submitLabel ?? "", prompt: "Submit") { v in update { $0.submitLabel = v } }
                }
                labeled("After submitting") {
                    CommitTextField(text: form.successMessage ?? "", prompt: "Thanks for submitting the form!") { v in update { $0.successMessage = v } }
                }
                Divider()
                Text("Fields").font(.headline)
                ForEach(included, id: \.self) { id in
                    if let f = editable.first(where: { $0.id == id }) {
                        HStack {
                            Image(systemName: f.type.symbolName).frame(width: 16).foregroundStyle(.secondary)
                            Text(f.name).lineLimit(1)
                            Spacer()
                            FieldConditionButton(document: document, view: view, fieldID: id)
                            Toggle("Required", isOn: Binding(get: { required.contains(id) }, set: { on in
                                update { form in
                                    var set = Set(form.requiredFieldIDs ?? [])
                                    if on { set.insert(id) } else { set.remove(id) }
                                    form.requiredFieldIDs = Array(set)
                                }
                            }))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            Button { move(id, -1, included) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                            Button { move(id, 1, included) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            Button {
                                update { $0.fieldIDs = included.filter { $0 != id } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                let excluded = editable.filter { !included.contains($0.id) }
                if !excluded.isEmpty {
                    Menu {
                        ForEach(excluded) { f in
                            Button(f.name) { update { $0.fieldIDs = included + [f.id] } }
                        }
                    } label: {
                        Label("Add a field", systemImage: "plus")
                    }
                    .fixedSize()
                }
                Text("Submissions create records in \(document.table(view.tableID)?.name ?? "this table") and can trigger automations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("rowhouse://form?base=\(document.baseID)&view=\(view.id)", forType: .string)
                } label: {
                    Label("Copy form link", systemImage: "link")
                }
                .controlSize(.small)
                Text("Add prefill_<Field name>=value to the link to pre-fill answers, e.g. &prefill_Priority=High.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func update(_ change: (inout FormConfig) -> Void) {
        document.updateViewConfig(view.id, actionName: "Edit Form") { config in
            var form = config.form ?? FormConfig()
            change(&form)
            config.form = form
        }
    }

    private func move(_ id: String, _ delta: Int, _ ids: [String]) {
        var ids = ids
        guard let i = ids.firstIndex(of: id), i + delta >= 0, i + delta < ids.count else { return }
        ids.swapAt(i, i + delta)
        update { $0.fieldIDs = ids }
    }
}

/// "Show only if…" conditions for one form field.
private struct FieldConditionButton: View {
    let document: BaseDocument
    let view: ViewModel
    let fieldID: String
    @State private var editing = false

    var body: some View {
        let condition = view.config.form?.fieldConditions?[fieldID]
        let active = !(condition?.isEmpty ?? true)
        Button {
            editing = true
        } label: {
            Image(systemName: active ? "eye.circle.fill" : "eye.circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(active ? "Shown only when conditions are met" : "Show this field only when…")
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Show this field only when").font(.headline)
                FilterEditor(document: document, tableID: view.tableID, filter: condition ?? FilterGroup(), title: "") { group in
                    document.updateViewConfig(view.id, actionName: "Edit Form") { config in
                        var form = config.form ?? FormConfig()
                        var conditions = form.fieldConditions ?? [:]
                        conditions[fieldID] = group.isEmpty ? nil : group
                        form.fieldConditions = conditions.isEmpty ? nil : conditions
                        config.form = form
                    }
                }
            }
            .padding(14)
        }
    }
}
