import RowHouseCore
import SwiftUI

/// Edits a filter group (conditions plus one level of nested groups). Used by views, automation
/// triggers, step conditions and "find records".
struct FilterEditor: View {
    let document: BaseDocument
    let tableID: String
    @State var filter: FilterGroup
    var title: String = "Filter"
    /// Report every edit straight away instead of after a pause in typing.
    var immediate = false
    let onChange: (FilterGroup) -> Void
    @State private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.headline) }
            FilterGroupEditor(document: document, tableID: tableID, group: $filter, depth: 0)
        }
        .padding(title.isEmpty ? 0 : 14)
        .frame(minWidth: 560, alignment: .leading)
        .onChange(of: filter) { _, new in
            pending?.cancel()
            if immediate {
                onChange(new)
                return
            }
            pending = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                onChange(new)
            }
        }
        .onDisappear {
            if pending != nil {
                pending?.cancel()
                onChange(filter)
            }
        }
    }
}

private struct FilterGroupEditor: View {
    let document: BaseDocument
    let tableID: String
    @Binding var group: FilterGroup
    let depth: Int

    var body: some View {
        let fields = document.fields(in: tableID).filter { !FilterOperator.available(for: $0.type).isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            if group.conditions.isEmpty && group.groups.isEmpty {
                Text(depth == 0 ? "No filter conditions are applied." : "Empty group")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(group.conditions.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 6) {
                    conjunctionLabel(index)
                    ConditionRow(document: document, fields: fields, condition: $group.conditions[index]) {
                        group.conditions.remove(at: index)
                    }
                }
            }
            ForEach(Array(group.groups.enumerated()), id: \.element.id) { index, _ in
                HStack(alignment: .top, spacing: 6) {
                    conjunctionLabel(group.conditions.count + index)
                    VStack(alignment: .leading) {
                        FilterGroupEditor(document: document, tableID: tableID, group: $group.groups[index], depth: depth + 1)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    Button {
                        group.groups.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 14) {
                Button {
                    if let f = fields.first {
                        let op = FilterOperator.available(for: f).first ?? .contains
                        group.conditions.append(FilterCondition(fieldID: f.id, op: op, value: f.type == .checkbox ? .bool(true) : nil))
                    }
                } label: {
                    Label("Add condition", systemImage: "plus")
                }
                if depth == 0 {
                    Button {
                        group.groups.append(FilterGroup(conjunction: group.conjunction == .and ? .or : .and))
                    } label: {
                        Label("Add condition group", systemImage: "plus.square.on.square")
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func conjunctionLabel(_ index: Int) -> some View {
        if index == 0 {
            Text("Where").frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
        } else if index == 1 {
            Picker("", selection: $group.conjunction) {
                Text("and").tag(FilterConjunction.and)
                Text("or").tag(FilterConjunction.or)
            }
            .labelsHidden()
            .frame(width: 56)
        } else {
            Text(group.conjunction.displayName).frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
        }
    }
}

private struct ConditionRow: View {
    let document: BaseDocument
    let fields: [FieldModel]
    @Binding var condition: FilterCondition
    let remove: () -> Void

    var body: some View {
        let field = document.field(condition.fieldID)
        let ops = field.map { FilterOperator.available(for: $0) } ?? FilterOperator.available(for: .singleLineText)
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { condition.fieldID }, set: { id in
                condition.fieldID = id
                let type = document.field(id)?.type ?? .singleLineText
                let available = document.field(id).map { FilterOperator.available(for: $0) } ?? FilterOperator.available(for: type)
                if !available.contains(condition.op) { condition.op = available.first ?? .contains }
                condition.value = type == .checkbox ? .bool(true) : nil
            })) {
                ForEach(fields) { f in Label(f.name, systemImage: f.type.symbolName).tag(f.id) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("", selection: $condition.op) {
                ForEach(ops, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            if let field, condition.op.needsValue || field.type == .checkbox {
                ConditionValueEditor(document: document, field: field, op: condition.op, value: $condition.value)
                    .frame(minWidth: 160)
            } else {
                Spacer().frame(minWidth: 160)
            }
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ConditionValueEditor: View {
    let document: BaseDocument
    let field: FieldModel
    let op: FilterOperator
    @Binding var value: JSONValue?

    var body: some View {
        switch field.type {
        case .checkbox:
            Picker("", selection: Binding(get: { value?.boolValue ?? true }, set: { value = .bool($0) })) {
                Text("checked").tag(true)
                Text("unchecked").tag(false)
            }
            .labelsHidden()
        case .singleSelect, .multipleSelects:
            ChoicePickerMenu(field: field, selected: Binding(get: {
                Set(value?.stringArray ?? (value?.stringValue.map { [$0] } ?? []))
            }, set: { ids in
                value = ids.isEmpty ? nil : .array(field.choices.map(\.id).filter { ids.contains($0) }.map(JSONValue.string))
            }), allowsMultiple: op != .is && op != .isNot || field.type == .multipleSelects)
        case .date, .createdTime, .lastModifiedTime:
            DateConditionEditor(op: op, value: $value)
        case .collaborator:
            PeoplePickerMenu(document: document, selected: Binding(get: {
                value?.collaboratorIDs ?? []
            }, set: { ids in
                value = ids.isEmpty ? nil : .array(ids.map(JSONValue.string))
            }), allowsMultiple: op != .is && op != .isNot, includesMe: true)
        default:
            TextField("Enter a value", text: Binding(get: {
                value?.stringValue ?? value?.numberValue.map { CellFormatter.number($0, precision: nil) } ?? ""
            }, set: { value = $0.isEmpty ? nil : .string($0) }))
            .textFieldStyle(.roundedBorder)
        }
    }
}

struct ChoicePickerMenu: View {
    let field: FieldModel
    @Binding var selected: Set<String>
    var allowsMultiple = true

    var body: some View {
        Menu {
            ForEach(field.choices) { choice in
                Button {
                    if allowsMultiple {
                        if selected.contains(choice.id) { selected.remove(choice.id) } else { selected.insert(choice.id) }
                    } else {
                        selected = [choice.id]
                    }
                } label: {
                    if selected.contains(choice.id) {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            let names = field.choices.filter { selected.contains($0.id) }.map(\.name)
            Text(names.isEmpty ? "Select an option" : names.joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DateConditionEditor: View {
    let op: FilterOperator
    @Binding var value: JSONValue?

    var body: some View {
        if op == .isWithin {
            let mode = value?["mode"]?.stringValue.flatMap(WithinMode.init(rawValue:)) ?? .pastWeek
            HStack {
                Picker("", selection: Binding(get: { mode }, set: { set(mode: $0.rawValue) })) {
                    ForEach(WithinMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                if mode == .pastNumberOfDays || mode == .nextNumberOfDays {
                    daysField
                }
            }
        } else {
            let mode = value?["mode"]?.stringValue.flatMap(RelativeDateMode.init(rawValue:)) ?? .exactDate
            HStack {
                Picker("", selection: Binding(get: { mode }, set: { set(mode: $0.rawValue) })) {
                    ForEach(RelativeDateMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                if mode == .exactDate {
                    DatePicker("", selection: Binding(get: {
                        value?["date"]?.stringValue.flatMap { DateCoding.decode($0) } ?? Calendar.current.startOfDay(for: Date())
                    }, set: { d in
                        value = .object(["mode": .string("exactDate"), "date": .string(DateCoding.encode(d, includeTime: false))])
                    }), displayedComponents: .date)
                    .labelsHidden()
                } else if mode == .daysAgo || mode == .daysFromNow {
                    daysField
                }
            }
        }
    }

    private var daysField: some View {
        TextField("Days", value: Binding(get: { Int(value?["days"]?.numberValue ?? 7) }, set: { n in
            var obj = value?.objectValue ?? [:]
            obj["days"] = .number(Double(n))
            value = .object(obj)
        }), format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 60)
    }

    private func set(mode: String) {
        var obj = value?.objectValue ?? [:]
        obj["mode"] = .string(mode)
        if mode == "exactDate" && obj["date"] == nil {
            obj["date"] = .string(DateCoding.encode(Date(), includeTime: false))
        }
        if obj["days"] == nil { obj["days"] = .number(7) }
        value = .object(obj)
    }
}
