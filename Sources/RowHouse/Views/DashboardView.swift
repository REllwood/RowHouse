import RowHouseCore
import SwiftUI

/// Dashboard view: numbers, charts, record lists and progress gauges over the view's records,
/// laid out in one to three columns. "Edit dashboard" adds, removes, reorders and configures widgets.
struct DashboardView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    @State private var editing = false
    @State private var autoEditID: String?

    private var document: BaseDocument { session.document }
    private var widgets: [DashboardWidget] { view.config.dashboard?.widgets ?? [] }
    static let spacing: CGFloat = 16

    var body: some View {
        let recordIDs = document.evaluate(view: view, search: state.search[view.tableID] ?? "").recordIDs
        VStack(spacing: 0) {
            header(recordCount: recordIDs.count)
            Divider()
            if widgets.isEmpty {
                ContentUnavailableView {
                    Label("No widgets yet", systemImage: "rectangle.3.group")
                } description: {
                    Text("Add numbers, charts, lists and progress gauges for this table.")
                } actions: {
                    addMenu.fixedSize()
                }
            } else {
                GeometryReader { geo in
                    let width = geo.size.width - 48
                    let columns = width >= 960 ? 3 : (width >= 600 ? 2 : 1)
                    let unit = (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Self.spacing) {
                            ForEach(Array(packed(columns: columns).enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: Self.spacing) {
                                    ForEach(row, id: \.widget.id) { item in
                                        DashboardTile(
                                            session: session,
                                            view: view,
                                            state: state,
                                            widget: item.widget,
                                            recordIDs: recordIDs,
                                            editing: editing,
                                            autoEditID: $autoEditID,
                                            isFirst: item.widget.id == widgets.first?.id,
                                            isLast: item.widget.id == widgets.last?.id,
                                            onChange: update,
                                            onMove: move,
                                            onDelete: delete
                                        )
                                        .frame(width: unit * CGFloat(item.span) + Self.spacing * CGFloat(item.span - 1))
                                        .frame(maxHeight: .infinity)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(24)
                        .animation(.snappy(duration: 0.25), value: widgets)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private func header(recordCount: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(view.name).font(.title2.weight(.semibold))
                Text("\(recordCount) record\(recordCount == 1 ? "" : "s") in \(document.table(view.tableID)?.name ?? "this table")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if editing {
                addMenu.fixedSize()
                Button("Done") {
                    withAnimation(.snappy(duration: 0.2)) { editing = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { editing = true }
                } label: {
                    Label("Edit dashboard", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var addMenu: some View {
        Menu {
            ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                Button {
                    add(kind)
                } label: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
        } label: {
            Label("Add widget", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
    }

    struct Placed {
        var widget: DashboardWidget
        var span: Int
    }

    /// Rows of widgets; when the next widget doesn't fit, the row's last widget widens to fill it.
    private func packed(columns: Int) -> [[Placed]] {
        var rows: [[Placed]] = []
        var current: [Placed] = []
        var used = 0
        for widget in widgets {
            let span = min(widget.columnSpan, columns)
            if used + span > columns, !current.isEmpty {
                current[current.count - 1].span += columns - used
                rows.append(current)
                current = []
                used = 0
            }
            current.append(Placed(widget: widget, span: span))
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    // MARK: Editing

    private func edit(_ change: (inout [DashboardWidget]) -> Void) {
        document.updateViewConfig(view.id, actionName: "Edit Dashboard") { config in
            var dashboard = config.dashboard ?? DashboardConfig()
            change(&dashboard.widgets)
            config.dashboard = dashboard
        }
    }

    private func update(_ widget: DashboardWidget) {
        edit { widgets in
            if let i = widgets.firstIndex(where: { $0.id == widget.id }) { widgets[i] = widget }
        }
    }

    private func move(_ id: String, by offset: Int) {
        edit { widgets in
            guard let i = widgets.firstIndex(where: { $0.id == id }) else { return }
            let j = max(0, min(widgets.count - 1, i + offset))
            guard i != j else { return }
            widgets.swapAt(i, j)
        }
    }

    private func delete(_ id: String) {
        edit { $0.removeAll { $0.id == id } }
    }

    private func add(_ kind: DashboardWidgetKind) {
        let widget = newWidget(kind)
        edit { $0.append(widget) }
        editing = true
        autoEditID = widget.id
    }

    private func newWidget(_ kind: DashboardWidgetKind) -> DashboardWidget {
        let fields = document.fields(in: view.tableID)
        let primary = document.primaryField(of: view.tableID)?.id
        var widget = DashboardWidget(kind: kind)
        switch kind {
        case .number:
            widget.aggregate = .count
        case .chart:
            var chart = ChartConfig()
            chart.kind = .bar
            chart.categoryFieldID = fields.first { $0.type == .singleSelect }?.id ?? fields.first?.id
            chart.aggregate = .count
            widget.chart = chart
            widget.span = 2
        case .list:
            if let date = fields.first(where: { $0.type.isDateLike }) { widget.sort = SortSpec(fieldID: date.id, ascending: false) }
            widget.fieldIDs = document.cardFields(for: view, excluding: [], limit: 3).map(\.id)
            widget.limit = 5
            widget.span = 2
        case .progress:
            let starter = DashboardConfig.starter(tableName: "", fields: fields, primaryFieldID: primary).widgets
            widget.filter = starter.first { $0.kind == .progress }?.filter
            widget.title = starter.first { $0.kind == .progress }?.title
        }
        return widget
    }
}

/// One widget's card.
private struct DashboardTile: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let widget: DashboardWidget
    let recordIDs: [String]
    let editing: Bool
    @Binding var autoEditID: String?
    let isFirst: Bool
    let isLast: Bool
    let onChange: (DashboardWidget) -> Void
    let onMove: (String, Int) -> Void
    let onDelete: (String) -> Void
    @State private var configuring = false

    private var document: BaseDocument { session.document }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: widget.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(document.widgetTitle(widget))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let filter = widget.filter, !filter.isEmpty, widget.kind != .progress {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Filtered by \(filter.conditionCount) condition\(filter.conditionCount == 1 ? "" : "s")")
                }
                Spacer(minLength: 4)
                if editing { editControls }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(editing ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: editing ? [5, 3] : []))
        )
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .contextMenu {
            Button("Configure Widget…") { configuring = true }
            Button("Move Earlier") { onMove(widget.id, -1) }.disabled(isFirst)
            Button("Move Later") { onMove(widget.id, 1) }.disabled(isLast)
            Divider()
            Button("Delete Widget", role: .destructive) { onDelete(widget.id) }
        }
        .popover(isPresented: $configuring, arrowEdge: .bottom) {
            WidgetEditor(document: document, tableID: view.tableID, widget: widget, onChange: onChange)
        }
        .onAppear {
            if autoEditID == widget.id {
                autoEditID = nil
                DispatchQueue.main.async { configuring = true }
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 2) {
            Button { onMove(widget.id, -1) } label: { Image(systemName: "arrow.left") }
                .disabled(isFirst)
                .help("Move earlier")
            Button { onMove(widget.id, 1) } label: { Image(systemName: "arrow.right") }
                .disabled(isLast)
                .help("Move later")
            Button { configuring = true } label: { Image(systemName: "slider.horizontal.3") }
                .help("Configure")
            Button(role: .destructive) { onDelete(widget.id) } label: { Image(systemName: "trash") }
                .help("Delete widget")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var content: some View {
        switch document.dashboardValue(widget, recordIDs: recordIDs) {
        case .number(_, let text):
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text(text)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                Text(numberCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 72)
        case .progress(let matching, let total):
            let fraction = total == 0 ? 0 : Double(matching) / Double(total)
            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ProgressBar(fraction: fraction)
                Text("\(matching) of \(total) record\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 72)
        case .chart(let data):
            let chart = widget.chart ?? ChartConfig()
            if data.isEmpty {
                Text(document.field(chart.categoryFieldID) == nil ? "Choose a field to group by." : "No data to chart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ChartPlot(data: data, kind: chart.kind ?? .bar, categoryName: document.field(chart.categoryFieldID)?.name ?? "", compact: true) { value in
                    document.formatAggregate(value, aggregate: chart.aggregate ?? .count, field: document.field(chart.valueFieldID))
                }
                .frame(height: 230)
            }
        case .list(let ids):
            DashboardRecordList(session: session, state: state, widget: widget, recordIDs: ids)
        }
    }

    private var numberCaption: String {
        let aggregate = widget.aggregate ?? .count
        let matching = document.widgetRecordIDs(widget, recordIDs: recordIDs).count
        let scope = matching == recordIDs.count ? "\(recordIDs.count) record\(recordIDs.count == 1 ? "" : "s")" : "\(matching) of \(recordIDs.count) records"
        guard aggregate != .count, let field = document.field(widget.fieldID) else { return scope }
        return "\(aggregate.displayName) of \(field.name) · \(scope)"
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(fraction > 0 ? 8 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .animation(.snappy, value: fraction)
    }
}

private struct DashboardRecordList: View {
    let session: BaseSession
    var state: WindowState
    let widget: DashboardWidget
    let recordIDs: [String]
    @State private var hovered: String?

    var body: some View {
        let document = session.document
        let fields = (widget.fieldIDs ?? []).compactMap { document.field($0) }.prefix(4)
        if recordIDs.isEmpty {
            Text("No records match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(recordIDs.enumerated()), id: \.element) { index, id in
                    if let record = document.record(id) {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            Text(document.primaryTitle(record))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(fields)) { field in
                                CompactValueView(session: session, record: record, field: field)
                                    .lineLimit(1)
                                    .frame(width: 118, alignment: .leading)
                                    .clipped()
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hovered == id ? Color(nsColor: Theme.rowHover) : Color.clear))
                        .overlay(alignment: .bottom) {
                            if index < recordIDs.count - 1 { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
                        }
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
                        .onTapGesture {
                            state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: recordIDs)
                        }
                    }
                }
            }
        }
    }
}

/// Popover for configuring one widget.
private struct WidgetEditor: View {
    let document: BaseDocument
    let tableID: String
    @State var widget: DashboardWidget
    let onChange: (DashboardWidget) -> Void
    @State private var title = ""

    var body: some View {
        let fields = document.fields(in: tableID)
        let numeric = fields.filter { $0.type.isNumeric || $0.type == .formula || $0.type == .rollup }
        let groupable = fields.filter { $0.type != .attachment && $0.type != .button }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Title", text: $title, prompt: Text(document.widgetTitle(untitled)))
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .onSubmit(commitTitle)
                Picker("", selection: Binding(get: { widget.columnSpan }, set: { widget.span = $0 })) {
                    Text("Narrow").tag(1)
                    Text("Wide").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Picker("Show", selection: Binding(get: { widget.kind }, set: { kind in
                widget.kind = kind
                if kind == .chart, widget.chart?.categoryFieldID == nil {
                    var chart = widget.chart ?? ChartConfig()
                    chart.kind = chart.kind ?? .bar
                    chart.categoryFieldID = fields.first { $0.type == .singleSelect }?.id ?? fields.first?.id
                    chart.aggregate = chart.aggregate ?? .count
                    widget.chart = chart
                }
            })) {
                ForEach(DashboardWidgetKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch widget.kind {
            case .number:
                Form {
                    Picker("Calculate", selection: Binding(get: { widget.aggregate ?? .count }, set: { widget.aggregate = $0 })) {
                        ForEach(ChartAggregate.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if (widget.aggregate ?? .count) != .count {
                        fieldPicker("Field", selection: $widget.fieldID, options: numeric)
                    }
                }
                .formStyle(.columns)
                filterSection("Only include records where…")
            case .chart:
                Form {
                    Picker("Chart", selection: chartBinding(\.kind, default: .bar)) {
                        ForEach(ChartKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    fieldPicker("Group by", selection: chartBinding(\.categoryFieldID), options: groupable)
                    Picker("Show", selection: chartBinding(\.aggregate, default: .count)) {
                        ForEach(ChartAggregate.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if (widget.chart?.aggregate ?? .count) != .count {
                        fieldPicker("Of", selection: chartBinding(\.valueFieldID), options: numeric)
                    }
                    Toggle("Sort by value", isOn: chartBinding(\.sortByValue, default: false))
                }
                .formStyle(.columns)
                filterSection("Only include records where…")
            case .list:
                Form {
                    fieldPicker("Sort by", selection: Binding(get: { widget.sort?.fieldID }, set: { id in
                        widget.sort = id.map { SortSpec(fieldID: $0, ascending: widget.sort?.ascending ?? true) }
                    }), options: groupable, noneLabel: "Table order")
                    if widget.sort != nil {
                        Picker("Order", selection: Binding(get: { widget.sort?.ascending ?? true }, set: { widget.sort?.ascending = $0 })) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                    }
                    Stepper("Show \(widget.recordLimit) records", value: Binding(get: { widget.recordLimit }, set: { widget.limit = $0 }), in: 1...20)
                }
                .formStyle(.columns)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fields").font(.subheadline.weight(.semibold))
                    let primary = document.primaryField(of: tableID)?.id
                    FlowLayout(spacing: 6) {
                        ForEach(fields.filter { $0.id != primary && $0.type != .button }) { field in
                            let on = widget.fieldIDs?.contains(field.id) ?? false
                            Button {
                                var ids = widget.fieldIDs ?? []
                                if on { ids.removeAll { $0 == field.id } } else if ids.count < 4 { ids.append(field.id) }
                                widget.fieldIDs = ids
                            } label: {
                                Label(field.name, systemImage: on ? "checkmark" : field.type.symbolName)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                                    .foregroundStyle(on ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!on && (widget.fieldIDs?.count ?? 0) >= 4)
                        }
                    }
                }
                filterSection("Only include records where…")
            case .progress:
                filterSection("Count records as complete when…")
            }
        }
        .padding(16)
        .frame(width: 600, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { title = widget.title ?? "" }
        .onDisappear(perform: commitTitle)
        .onChange(of: widget) { _, new in onChange(new) }
    }

    private var untitled: DashboardWidget {
        var copy = widget
        copy.title = nil
        return copy
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        if widget.title != value { widget.title = value }
    }

    private func filterSection(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.subheadline.weight(.semibold))
            FilterEditor(document: document, tableID: tableID, filter: widget.filter ?? FilterGroup(), title: "") { filter in
                widget.filter = filter.isEmpty ? nil : filter
            }
        }
    }

    private func fieldPicker(_ label: String, selection: Binding<String?>, options: [FieldModel], noneLabel: String = "Choose…") -> some View {
        Picker(label, selection: Binding(get: { selection.wrappedValue ?? "" }, set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text(noneLabel).tag("")
            ForEach(options) { f in
                Label(f.name, systemImage: f.type.symbolName).tag(f.id)
            }
        }
    }

    private func chartBinding<T>(_ keyPath: WritableKeyPath<ChartConfig, T?>, default value: T) -> Binding<T> {
        Binding(get: { widget.chart?[keyPath: keyPath] ?? value }, set: { v in
            var chart = widget.chart ?? ChartConfig()
            chart[keyPath: keyPath] = v
            widget.chart = chart
        })
    }

    private func chartBinding(_ keyPath: WritableKeyPath<ChartConfig, String?>) -> Binding<String?> {
        Binding(get: { widget.chart?[keyPath: keyPath] }, set: { v in
            var chart = widget.chart ?? ChartConfig()
            chart[keyPath: keyPath] = v
            widget.chart = chart
        })
    }
}
