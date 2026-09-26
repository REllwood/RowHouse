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
        let hideEmpty = view.config.hideEmptyStacks == true
        let collapsed = Set(view.config.collapsedStacks ?? [])
        let stacks: [SelectChoice?] = ([nil] + stackField.choices.map { Optional($0) }).filter { choice in
            let count = buckets[choice?.id ?? ""]?.count ?? 0
            return count > 0 || (choice != nil && !hideEmpty)
        }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(stacks, id: \.?.id) { choice in
                    let key = choice?.id ?? ""
                    if collapsed.contains(key) {
                        CollapsedKanbanColumn(document: document, stackField: stackField, choice: choice, count: buckets[key]?.count ?? 0) {
                            setCollapsed(key, false)
                        }
                    } else {
                        KanbanColumn(
                            session: session,
                            view: view,
                            stackField: stackField,
                            choice: choice,
                            records: buckets[key] ?? [],
                            cardFields: cardFields,
                            state: state,
                            siblings: result.recordIDs,
                            collapse: { setCollapsed(key, true) }
                        )
                    }
                }
                AddStackButton(document: document, fieldID: stackField.id)
            }
            .padding(16)
            .animation(.snappy(duration: 0.2), value: collapsed)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func setCollapsed(_ key: String, _ collapse: Bool) {
        document.updateViewConfig(view.id, actionName: collapse ? "Collapse Stack" : "Expand Stack") { config in
            var keys = config.collapsedStacks ?? []
            keys.removeAll { $0 == key }
            if collapse { keys.append(key) }
            config.collapsedStacks = keys.isEmpty ? nil : keys
        }
    }
}

/// Moves dropped cards into a stack.
@MainActor
private func moveCards(_ ids: [String], to choice: SelectChoice?, stackField: FieldModel, document: BaseDocument) -> Bool {
    var updates: [String: [String: JSONValue]] = [:]
    for id in ids where document.record(id) != nil {
        updates[id] = [stackField.id: choice.map { .string($0.id) } ?? .null]
    }
    document.updateRecords(updates, actionName: "Move Card")
    return !updates.isEmpty
}

/// A collapsed stack: a thin strip with its name and count that still accepts dropped cards.
private struct CollapsedKanbanColumn: View {
    let document: BaseDocument
    let stackField: FieldModel
    let choice: SelectChoice?
    let count: Int
    let expand: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Group {
                if let choice {
                    ChoiceChip(name: choice.name, color: choice.color)
                } else {
                    Text("Uncategorized").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .rotationEffect(.degrees(90))
            .frame(width: 24, height: 140, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .frame(minHeight: 240, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)))
        .overlay(alignment: .top) {
            if let choice {
                Capsule().fill(choice.color.swiftUI).frame(width: 18, height: 3).padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .help("Expand \(choice?.name ?? "Uncategorized")")
        .dropDestination(for: String.self) { ids, _ in
            moveCards(ids, to: choice, stackField: stackField, document: document)
        } isTargeted: { targeted = $0 }
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
    let collapse: () -> Void
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
                Button(action: collapse) {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Collapse this stack")
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
            moveCards(ids, to: choice, stackField: stackField, document: document)
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
