import RowHouseCore
import SwiftUI

/// The strip under the toolbar with the view's controls: hide fields, filter, group, sort, row height
/// and view-type settings.
struct ViewBar: View {
    let document: BaseDocument
    let view: ViewModel
    var state: WindowState
    @State private var renaming = false
    @State private var nameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
            Menu {
                Button("Rename View…") {
                    nameText = view.name
                    renaming = true
                }
                Button("Duplicate View") {
                    if let id = document.duplicateView(view.id) { state.viewForTable[view.tableID] = id }
                }
                Divider()
                Button("Delete View", role: .destructive) { document.deleteView(view.id) }
                    .disabled(document.views(in: view.tableID).count <= 1)
            } label: {
                Label(view.name, systemImage: view.type.symbolName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 6)

            Divider().frame(height: 16)

            if view.type != .form {
                if view.type != .chart && view.type != .dashboard {
                    BarButton(title: hiddenTitle, systemImage: "eye.slash", active: !(view.config.hiddenFieldIDs ?? []).isEmpty) {
                        HideFieldsEditor(document: document, view: view)
                    }
                }
                BarButton(title: filterTitle, systemImage: "line.3.horizontal.decrease", active: (view.config.filter?.conditionCount ?? 0) > 0, tint: .blue) {
                    FilterEditor(document: document, tableID: view.tableID, filter: view.config.filter ?? FilterGroup()) { newFilter in
                        document.updateViewConfig(view.id, actionName: "Change Filter") { $0.filter = newFilter.isEmpty ? nil : newFilter }
                    }
                }
                if view.type.supportsGrouping {
                    BarButton(title: groupTitle, systemImage: "rectangle.3.group", active: !(view.config.groups ?? []).isEmpty, tint: .purple) {
                        SortEditor(document: document, tableID: view.tableID, specs: view.config.groups ?? [], mode: .group) { specs in
                            document.updateViewConfig(view.id, actionName: "Change Grouping") { $0.groups = specs.isEmpty ? nil : specs }
                        }
                    }
                }
                if view.type != .chart && view.type != .dashboard {
                    BarButton(title: sortTitle, systemImage: "arrow.up.arrow.down", active: !(view.config.sorts ?? []).isEmpty, tint: .orange) {
                        SortEditor(document: document, tableID: view.tableID, specs: view.config.sorts ?? [], mode: .sort) { specs in
                            document.updateViewConfig(view.id, actionName: "Change Sort") { $0.sorts = specs.isEmpty ? nil : specs }
                        }
                    }
                }
                if [.grid, .list, .calendar, .timeline, .gantt, .kanban, .gallery].contains(view.type) {
                    BarButton(title: "Colour", systemImage: "paintpalette", active: view.config.colorFieldID != nil, tint: .pink) {
                        ColorEditor(document: document, view: view)
                    }
                }
                if view.type == .grid {
                    Menu {
                        Picker("Row height", selection: Binding(get: { view.config.rowHeight ?? .short }, set: { h in
                            document.updateViewConfig(view.id, actionName: "Change Row Height") { $0.rowHeight = h == .short ? nil : h }
                        })) {
                            ForEach(RowHeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Row height", systemImage: "arrow.up.and.down.text.horizontal")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Row height")
                }
                ViewTypeSettings(document: document, view: view)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Rename View", isPresented: $renaming) {
            TextField("Name", text: $nameText)
            Button("Rename") { document.renameView(view.id, to: nameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var hiddenTitle: String {
        let n = view.config.hiddenFieldIDs?.count ?? 0
        return n == 0 ? "Hide fields" : "\(n) hidden field\(n == 1 ? "" : "s")"
    }

    private var filterTitle: String {
        let n = view.config.filter?.conditionCount ?? 0
        return n == 0 ? "Filter" : "Filtered by \(n) field\(n == 1 ? "" : "s")"
    }

    private var groupTitle: String {
        let n = view.config.groups?.count ?? 0
        return n == 0 ? "Group" : "Grouped by \(n) field\(n == 1 ? "" : "s")"
    }

    private var sortTitle: String {
        let n = view.config.sorts?.count ?? 0
        return n == 0 ? "Sort" : "Sorted by \(n) field\(n == 1 ? "" : "s")"
    }
}

/// A toolbar-strip button that opens a popover and tints itself when its setting is active.
struct BarButton<Content: View>: View {
    let title: String
    let systemImage: String
    var active = false
    var tint: Color = .gray
    @ViewBuilder var content: () -> Content
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? tint.opacity(0.16) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? tint : .primary)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            content()
        }
    }
}

struct HideFieldsEditor: View {
    let document: BaseDocument
    let view: ViewModel
    @State private var search = ""

    var body: some View {
        let primary = document.primaryField(of: view.tableID)?.id
        let fields = document.orderedFields(for: view).filter { $0.id != primary }
        let hidden = view.config.hidden
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find a field", text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(fields.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { field in
                    Toggle(isOn: Binding(get: { !hidden.contains(field.id) }, set: { visible in
                        document.updateViewConfig(view.id, actionName: visible ? "Show Field" : "Hide Field") { config in
                            var set = config.hidden
                            if visible { set.remove(field.id) } else { set.insert(field.id) }
                            config.hiddenFieldIDs = set.isEmpty ? nil : Array(set)
                        }
                    })) {
                        FieldLabel(field: field)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .onMove(perform: search.isEmpty ? { indices, destination in
                    var ids = fields.map(\.id)
                    ids.move(fromOffsets: indices, toOffset: destination)
                    document.updateViewConfig(view.id, actionName: "Reorder Fields") { $0.fieldOrder = ids }
                } : nil)
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(fields.count) * 28 + 10, 360))
            HStack {
                Button("Hide all") {
                    document.updateViewConfig(view.id, actionName: "Hide Fields") { $0.hiddenFieldIDs = fields.map(\.id) }
                }
                Button("Show all") {
                    document.updateViewConfig(view.id, actionName: "Show Fields") { $0.hiddenFieldIDs = nil }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}

struct SortEditor: View {
    enum Mode { case sort, group }
    let document: BaseDocument
    let tableID: String
    @State var specs: [SortSpec]
    let mode: Mode
    let onChange: ([SortSpec]) -> Void

    var body: some View {
        let fields = document.fields(in: tableID).filter { $0.type != .button && $0.type != .attachment }
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .sort ? "Sort by" : "Group by").font(.headline)
            if specs.isEmpty {
                Text(mode == .sort ? "No sorts applied — records appear in the order you added them." : "Group records that share a value.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($specs) { $spec in
                HStack {
                    Picker("", selection: $spec.fieldID) {
                        ForEach(fields) { f in
                            Label(f.name, systemImage: f.type.symbolName).tag(f.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Picker("", selection: $spec.ascending) {
                        Text(ascendingLabel(spec.fieldID, true)).tag(true)
                        Text(ascendingLabel(spec.fieldID, false)).tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button {
                        specs.removeAll { $0.id == spec.id }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if mode == .sort || specs.count < 3 {
                Menu {
                    ForEach(fields.filter { f in !specs.contains { $0.fieldID == f.id } }) { f in
                        Button {
                            specs.append(SortSpec(fieldID: f.id))
                        } label: {
                            Label(f.name, systemImage: f.type.symbolName)
                        }
                    }
                } label: {
                    Label(mode == .sort ? "Add sort" : "Add group", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(minWidth: 360)
        .onChange(of: specs) { _, new in onChange(new) }
    }

    private func ascendingLabel(_ fieldID: String, _ asc: Bool) -> String {
        let type = document.field(fieldID)?.type
        switch type {
        case .number?, .currency?, .percent?, .duration?, .rating?, .count?, .autoNumber?: return asc ? "1 → 9" : "9 → 1"
        case .date?, .createdTime?, .lastModifiedTime?: return asc ? "Oldest first" : "Newest first"
        case .checkbox?: return asc ? "☐ → ☑" : "☑ → ☐"
        case .singleSelect?: return asc ? "First → Last" : "Last → First"
        default: return asc ? "A → Z" : "Z → A"
        }
    }
}

struct ColorEditor: View {
    let document: BaseDocument
    let view: ViewModel

    var body: some View {
        let selects = document.fields(in: view.tableID).filter { $0.type == .singleSelect }
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour records").font(.headline)
            Picker("Use the colours of", selection: Binding(get: { view.config.colorFieldID ?? "" }, set: { id in
                document.updateViewConfig(view.id, actionName: "Change Colours") { $0.colorFieldID = id.isEmpty ? nil : id }
            })) {
                Text("None").tag("")
                ForEach(selects) { f in Text(f.name).tag(f.id) }
            }
            if selects.isEmpty {
                Text("Add a single select field to colour records by its options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// Per-view-type settings (kanban stacks, list nesting, calendar dates, gallery covers, timeline
/// and Gantt ranges and dependencies).
struct ViewTypeSettings: View {
    let document: BaseDocument
    let view: ViewModel

    var body: some View {
        let fields = document.fields(in: view.tableID)
        switch view.type {
        case .kanban:
            fieldMenu("Stacked by", icon: "rectangle.split.3x1", current: view.config.stackFieldID, options: fields.filter { $0.type == .singleSelect }) { id in
                document.updateViewConfig(view.id, actionName: "Change Stack Field") { $0.stackFieldID = id }
            }
            fieldMenu("Cover", icon: "photo", current: view.config.coverFieldID, options: fields.filter { $0.type == .attachment }, allowNone: true) { id in
                document.updateViewConfig(view.id, actionName: "Change Cover") { $0.coverFieldID = id }
            }
            Toggle(isOn: Binding(get: { view.config.hideEmptyStacks ?? false }, set: { hide in
                document.updateViewConfig(view.id, actionName: hide ? "Hide Empty Stacks" : "Show Empty Stacks") { $0.hideEmptyStacks = hide ? true : nil }
            })) {
                Text("Hide empty stacks").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .padding(.horizontal, 4)
        case .list:
            fieldMenu("Nest by", icon: "list.bullet.indent", current: view.config.listChildLinkFieldID, options: fields.filter { $0.type == .link }, allowNone: true, newSelfLink: fields.contains { $0.name.lowercased() == "subtasks" } ? nil : "Subtasks") { id in
                document.updateViewConfig(view.id, actionName: "Change Nesting") { $0.listChildLinkFieldID = id }
            }
        case .gallery:
            fieldMenu("Cover", icon: "photo", current: view.config.coverFieldID, options: fields.filter { $0.type == .attachment }, allowNone: true) { id in
                document.updateViewConfig(view.id, actionName: "Change Cover") { $0.coverFieldID = id }
            }
        case .calendar:
            fieldMenu("Date field", icon: "calendar", current: view.config.dateFieldID, options: fields.filter { $0.type.isDateLike || $0.type == .formula }) { id in
                document.updateViewConfig(view.id, actionName: "Change Date Field") { $0.dateFieldID = id }
            }
        case .timeline, .gantt:
            fieldMenu("Start", icon: "calendar", current: view.config.dateFieldID, options: fields.filter { $0.type.isDateLike || $0.type == .formula }) { id in
                document.updateViewConfig(view.id, actionName: "Change Start Field") { $0.dateFieldID = id }
            }
            fieldMenu("End", icon: "calendar.badge.clock", current: view.config.endDateFieldID, options: fields.filter { $0.type.isDateLike || $0.type == .formula }, allowNone: true) { id in
                document.updateViewConfig(view.id, actionName: "Change End Field") { $0.endDateFieldID = id }
            }
            if view.type == .gantt {
                fieldMenu("Depends on", icon: "arrow.triangle.branch", current: view.config.dependencyFieldID, options: fields.filter { $0.type == .link && $0.options.linkedTableID == view.tableID }, allowNone: true, newSelfLink: fields.contains { $0.name.lowercased() == "depends on" } ? nil : "Depends on") { id in
                    document.updateViewConfig(view.id, actionName: "Change Dependencies") { $0.dependencyFieldID = id }
                }
            }
            Picker("", selection: Binding(get: { view.config.timelineScale ?? .month }, set: { s in
                document.updateViewConfig(view.id, actionName: "Change Scale") { $0.timelineScale = s }
            })) {
                ForEach(TimelineScale.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func fieldMenu(_ title: String, icon: String, current: String?, options: [FieldModel], allowNone: Bool = false, newSelfLink: String? = nil, set: @escaping (String?) -> Void) -> some View {
        Menu {
            if allowNone { Button("None") { set(nil) } }
            ForEach(options) { f in
                Button {
                    set(f.id)
                } label: {
                    Label(f.name, systemImage: f.type.symbolName)
                }
            }
            if options.isEmpty && newSelfLink == nil { Text("No suitable fields") }
            if let newSelfLink {
                Divider()
                Button {
                    var linkOptions = FieldOptions()
                    linkOptions.linkedTableID = view.tableID
                    document.batch("Add Field") {
                        set(document.createField(in: view.tableID, name: newSelfLink, type: .link, options: linkOptions))
                    }
                } label: {
                    Label("New “\(newSelfLink)” field", systemImage: "plus")
                }
            }
        } label: {
            Label("\(title): \(document.field(current)?.name ?? "None")", systemImage: icon)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 4)
    }
}
