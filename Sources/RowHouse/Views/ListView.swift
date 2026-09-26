import RowHouseCore
import SwiftUI

/// List view: an outline of records, optionally grouped, with linked records nested beneath
/// each record through the view's "Nest by" link field.
struct ListView: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    private var document: BaseDocument { session.document }
    static let titleMinWidth: CGFloat = 260
    static let columnWidth: CGFloat = 150

    private var childField: FieldModel? {
        document.field(view.config.listChildLinkFieldID).flatMap { $0.type == .link && $0.tableID == view.tableID ? $0 : nil }
    }

    /// Nested records start expanded so the hierarchy is visible straight away.
    private var expansion: ListExpansion { state.listExpansion[view.id] ?? ListExpansion(expandedByDefault: true) }

    /// Where top-level titles start, so the column header lines up with them.
    private var titleInset: CGFloat {
        let groupLevels = (view.config.groups ?? []).filter { document.field($0.fieldID) != nil }.count
        return 12 + CGFloat(groupLevels) * 22 + 24 + (document.field(view.config.colorFieldID) != nil ? 13 : 0)
    }

    var body: some View {
        let rows = document.listOutline(
            view: view,
            search: state.search[view.tableID] ?? "",
            collapsedGroups: state.collapsedGroups[view.id] ?? [],
            expansion: expansion
        )
        var seen = Set<String>()
        let siblings = rows.compactMap(\.recordID).filter { document.record($0)?.tableID == view.tableID && seen.insert($0).inserted }
        GeometryReader { geo in
            let columns = Array(document.cardFields(for: view, excluding: [], limit: 4)
                .prefix(max(0, Int((geo.size.width - Self.titleMinWidth - 40) / Self.columnWidth))))
            VStack(spacing: 0) {
                header(recordCount: document.evaluate(view: view, search: state.search[view.tableID] ?? "").recordIDs.count)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(rows) { row in
                                switch row.kind {
                                case .group(let header):
                                    groupRow(header, row: row)
                                case .record(let id):
                                    recordRow(id, row: row, columns: columns, siblings: siblings)
                                }
                            }
                            addRow
                        } header: {
                            columnHeader(columns)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .overlay {
                    if rows.isEmpty && !(state.search[view.tableID] ?? "").isEmpty {
                        ContentUnavailableView.search(text: state.search[view.tableID] ?? "")
                    }
                }
            }
        }
        .background(Color(nsColor: Theme.gridBackground))
        .onAppear {
            commandTarget.addRecord = { addRecord() }
            commandTarget.expandSelection = {}
            commandTarget.deleteSelection = {}
        }
    }

    // MARK: Header

    private func header(recordCount: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(recordCount) record\(recordCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let childField {
                Label("Nested by \(childField.name)", systemImage: "list.bullet.indent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    setAll(expanded: true)
                } label: {
                    Label("Expand all", systemImage: "chevron.down.2")
                }
                Button {
                    setAll(expanded: false)
                } label: {
                    Label("Collapse all", systemImage: "chevron.up.2")
                }
            } else {
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func columnHeader(_ columns: [FieldModel]) -> some View {
        HStack(spacing: 0) {
            Text(document.primaryField(of: view.tableID)?.name ?? "Name")
                .padding(.leading, titleInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { field in
                HStack(spacing: 4) {
                    Image(systemName: field.type.symbolName)
                    Text(field.name).lineLimit(1)
                }
                .padding(.trailing, 10)
                .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.trailing, 16)
        .frame(height: 28)
        .background(Color(nsColor: Theme.headerBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
    }

    // MARK: Rows

    private func indent(_ row: ListOutlineRow) -> CGFloat {
        12 + CGFloat(row.groupDepth + row.level) * 22
    }

    private func groupRow(_ header: GroupHeader, row: ListOutlineRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 14)
            Text(document.field(header.fieldID)?.name.uppercased() ?? "")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if case .choice(let c) = header.value {
                ChoiceChip(name: c.name, color: c.color)
            } else {
                Text(header.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Text("\(header.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 12 + CGFloat(header.depth) * 22)
        .frame(height: header.depth == 0 ? 40 : 34)
        .background(Color(nsColor: Theme.groupBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            var set = state.collapsedGroups[view.id] ?? []
            if set.contains(header.id) { set.remove(header.id) } else { set.insert(header.id) }
            withAnimation(.snappy(duration: 0.2)) { state.collapsedGroups[view.id] = set }
        }
    }

    @ViewBuilder
    private func recordRow(_ id: String, row: ListOutlineRow, columns: [FieldModel], siblings: [String]) -> some View {
        if let record = document.record(id) {
            let nested = record.tableID != view.tableID
            let childField = nested ? nil : self.childField
            ListRecordRow(
                session: session,
                view: view,
                record: record,
                row: row,
                columns: columns,
                indent: indent(row),
                childField: childField,
                open: { state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id, siblings: nested ? [] : siblings) },
                toggle: { toggle(row.id) },
                addChild: { if let childField { addChild(to: id, rowID: row.id, field: childField) } }
            )
        }
    }

    private var addRow: some View {
        Button {
            addRecord()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Add record")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func toggle(_ rowID: String) {
        var e = expansion
        e.toggle(rowID)
        withAnimation(.snappy(duration: 0.2)) { state.listExpansion[view.id] = e }
    }

    private func setAll(expanded: Bool) {
        var e = expansion
        e.setAll(expanded: expanded)
        withAnimation(.snappy(duration: 0.2)) { state.listExpansion[view.id] = e }
    }

    private func addRecord() {
        let id = document.createRecord(in: view.tableID)
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
    }

    private func addChild(to parentID: String, rowID: String, field: FieldModel) {
        guard let id = document.createChildRecord(parentID: parentID, linkFieldID: field.id) else { return }
        var e = expansion
        if !e.isExpanded(rowID) { e.toggle(rowID) }
        state.listExpansion[view.id] = e
        state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: id)
    }
}

/// One record in the outline, with its own hover state so pointer movement doesn't rebuild the list.
private struct ListRecordRow: View {
    let session: BaseSession
    let view: ViewModel
    let record: RecordModel
    let row: ListOutlineRow
    let columns: [FieldModel]
    let indent: CGFloat
    let childField: FieldModel?
    let open: () -> Void
    let toggle: () -> Void
    let addChild: () -> Void
    @State private var hovered = false

    var body: some View {
        let document = session.document
        let nested = record.tableID != view.tableID
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                disclosure
                if nested {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else if let color = document.recordColor(record, view: view) {
                    Circle().fill(color.swiftUI).frame(width: 7, height: 7)
                } else if document.field(view.config.colorFieldID) != nil {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1).frame(width: 7, height: 7)
                }
                Text(document.primaryTitle(record))
                    .font(.system(size: 13, weight: row.level == 0 ? .medium : .regular))
                    .lineLimit(1)
                if row.hasChildren && !row.isExpanded {
                    Text("\(row.childCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .help("\(row.childCount) nested record\(row.childCount == 1 ? "" : "s")")
                }
                if nested, let table = document.table(record.tableID) {
                    Text(table.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if hovered, let childField {
                    Button(action: addChild) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Add a record under \(document.primaryTitle(record)) (\(childField.name))")
                }
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            if nested {
                NestedSummary(session: session, record: record)
                    .frame(width: ListView.columnWidth * CGFloat(columns.count), alignment: .leading)
            } else {
                ForEach(columns) { field in
                    CompactValueView(session: session, record: record, field: field)
                        .lineLimit(1)
                        .frame(width: ListView.columnWidth - 10, height: 38, alignment: .leading)
                        .clipped()
                        .padding(.trailing, 10)
                }
            }
        }
        .padding(.trailing, 16)
        .frame(height: 38)
        .background(hovered ? Color(nsColor: Theme.rowHover) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: Theme.gridLine)).frame(height: 1).padding(.leading, indent)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Expand Record", action: open)
            if childField != nil {
                Button("Add Nested Record", action: addChild)
            }
            if row.hasChildren {
                Button(row.isExpanded ? "Collapse" : "Expand", action: toggle)
            }
            Divider()
            Button("Duplicate Record") { _ = document.duplicateRecords([record.id]) }
            Button("Delete Record", role: .destructive) { document.deleteRecords([record.id]) }
        }
    }

    private var disclosure: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.hasChildren ? 1 : 0)
        .disabled(!row.hasChildren)
        .help(row.isExpanded ? "Collapse" : "Expand")
    }
}

/// A record from another table nested in a list: a few of its own fields, labelled.
private struct NestedSummary: View {
    let session: BaseSession
    let record: RecordModel

    var body: some View {
        let document = session.document
        let primary = document.primaryField(of: record.tableID)?.id
        let fields = document.fields(in: record.tableID)
            .filter { $0.id != primary && $0.type != .button && $0.type != .attachment && !document.value(record, $0).isEmpty }
            .prefix(3)
        HStack(spacing: 12) {
            ForEach(Array(fields)) { field in
                HStack(spacing: 5) {
                    Text(field.name.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    CompactValueView(session: session, record: record, field: field)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
        .frame(height: 38)
        .clipped()
    }
}
