import RowHouseCore
import SwiftUI

struct KanbanView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    private var document: BaseDocument { session.document }

    var body: some View {
        let stackField = document.field(view.config.stackFieldID).flatMap { $0.type == .singleSelect ? $0 : nil }
        Group {
            if let stackField {
                board(stackField)
            } else {
                ContentUnavailableView {
                    Label("Choose a field to stack by", systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Kanban stacks records by a single select field, like Status.")
                } actions: {
                    let selects = document.fields(in: view.tableID).filter { $0.type == .singleSelect }
                    if selects.isEmpty {
                        Button("Add a Status field") {
                            var o = FieldOptions()
                            o.choices = [SelectChoice(name: "Todo", color: .red), SelectChoice(name: "In progress", color: .yellow), SelectChoice(name: "Done", color: .green)]
                            let id = document.createField(in: view.tableID, name: "Status", type: .singleSelect, options: o)
                            document.updateViewConfig(view.id) { $0.stackFieldID = id }
                        }
                    } else {
                        ForEach(selects) { f in
                            Button("Stack by \(f.name)") { document.updateViewConfig(view.id) { $0.stackFieldID = f.id } }
                        }
                    }
                }
            }
        }
        .onAppear {
            commandTarget.addRecord = {
                let id = document.createRecord(in: view.tableID)
                state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
            }
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    private func board(_ stackField: FieldModel) -> some View {
        let result = document.evaluate(view: view, search: state.search[view.tableID] ?? "")
        var buckets: [String: [RecordModel]] = [:]
        for id in result.recordIDs {
            guard let r = document.record(id) else { continue }
            let key: String = { if case .choice(let c) = document.value(r, stackField) { return c.id } else { return "" } }()
            buckets[key, default: []].append(r)
        }
        let cardFields = document.cardFields(for: view, excluding: [stackField.id, view.config.coverFieldID ?? ""], limit: 4)
        let stacks: [SelectChoice?] = [nil] + stackField.choices.map { Optional($0) }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(stacks.filter { $0 != nil || !(buckets[""] ?? []).isEmpty }, id: \.?.id) { choice in
                    KanbanColumn(
                        session: session,
                        view: view,
                        stackField: stackField,
                        choice: choice,
                        records: buckets[choice?.id ?? ""] ?? [],
                        cardFields: cardFields,
                        state: state,
                        siblings: result.recordIDs
                    )
                }
                AddStackButton(document: document, fieldID: stackField.id)
            }
            .padding(16)
        }
        .background(Color.primary.opacity(0.025))
    }
}

private struct KanbanColumn: View {
    let session: BaseSession
    let view: ViewModel
    let stackField: FieldModel
    let choice: SelectChoice?
    let records: [RecordModel]
    let cardFields: [FieldModel]
    var state: WindowState
    let siblings: [String]
    @State private var targeted = false

    var body: some View {
        let document = session.document
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let choice {
                    ChoiceChip(name: choice.name, color: choice.color)
                } else {
                    Text("Uncategorized").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text("\(records.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    let values: [String: JSONValue] = choice.map { [stackField.id: .string($0.id)] } ?? [:]
                    let id = document.createRecord(in: view.tableID, values: values)
                    state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: siblings)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a record to this stack")
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        RecordCard(session: session, record: record, fields: cardFields, coverFieldID: view.config.coverFieldID, coverHeight: 110, accent: document.recordColor(record, view: view))
                            .onTapGesture { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: record.id, siblings: siblings) }
                            .draggable(record.id)
                            .contextMenu {
                                Button("Expand Record") { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: record.id, siblings: siblings) }
                                Button("Duplicate Record") { _ = document.duplicateRecords([record.id]) }
                                Divider()
                                Button("Delete Record", role: .destructive) { document.deleteRecords([record.id]) }
                            }
                    }
                    if records.isEmpty {
                        Text("Drop cards here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035)))
        .dropDestination(for: String.self) { ids, _ in
            var updates: [String: [String: JSONValue]] = [:]
            for id in ids where document.record(id) != nil {
                updates[id] = [stackField.id: choice.map { .string($0.id) } ?? .null]
            }
            document.updateRecords(updates, actionName: "Move Card")
            return !updates.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

private struct AddStackButton: View {
    let document: BaseDocument
    let fieldID: String
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        Button {
            adding = true
        } label: {
            Label("Add stack", systemImage: "plus")
                .frame(width: 180, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .popover(isPresented: $adding) {
            HStack {
                TextField("Option name", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(add)
                Button("Add", action: add)
            }
            .padding(12)
        }
    }

    private func add() {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { document.addChoice(named: name, to: fieldID) }
        name = ""
        adding = false
    }
}
