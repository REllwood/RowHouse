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
    }

    private var includedFields: [FieldModel] {
        let all = document.fields(in: view.tableID).filter { $0.isEditable }
        guard let ids = form.fieldIDs else { return all }
        return ids.compactMap { id in all.first { $0.id == id } }
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
            ForEach(includedFields) { field in
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
        missing = Set(includedFields.filter { required.contains($0.id) && (draft[$0.id]?.isEmptyCell ?? true) && !(draft[$0.id]?.boolValue ?? false) }.map(\.id))
        guard missing.isEmpty else { return }
        let values = draft.filter { !$0.value.isNull }
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
