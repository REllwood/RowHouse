import AppKit
import RowHouseCore
import SwiftUI

/// Drives the spreadsheet grid: data source, delegate, cell cursor, editing, clipboard and menus.
@MainActor
final class GridController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let rowColumnID = "__row"
    static let addColumnID = "__add"

    let tableView = GridTableView()
    let scrollView = NSScrollView()
    let summaryBar = SummaryBar()
    let container = NSView()

    private(set) var session: BaseSession
    private(set) var view: ViewModel
    private(set) var fields: [FieldModel] = []
    private(set) var rows: [ViewRow] = []
    private var recordIDs: [String] = []
    private var ordinals: [Int: Int] = [:]
    private var rowHeight: CGFloat = 32
    private var lastRevision = -1
    private var columnSignature = ""
    private var rebuildingColumns = false
    private var widthSaveTask: Task<Void, Never>?

    var callbacks = Callbacks()
    struct Callbacks {
        var expand: (String, [String]) -> Void = { _, _ in }
        var toggleGroup: (String) -> Void = { _ in }
        var collapsedGroups: () -> Set<String> = { [] }
        var runButton: (String, String) -> Void = { _, _ in }
    }

    // Selection
    private(set) var cursor: GridPosition?
    private var anchor: GridPosition?
    private var selectedRows = IndexSet()
    private var hoverRow = -1

    // Editing
    private var editor: NSTextField?
    private var editingPosition: GridPosition?
    /// The cell being edited, by identity, so rows moving underneath (e.g. edits synced from
    /// another Mac) can't redirect the edit to a different record or field.
    private var editingTarget: (recordID: String, fieldID: String)?
    private var editCancelled = false
    private var pendingReload = false
    private var popover: NSPopover?

    var document: BaseDocument { session.document }

    init(session: BaseSession, view: ViewModel) {
        self.session = session
        self.view = view
        super.init()
        configure()
    }

    private func configure() {
        tableView.controller = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.backgroundColor = Theme.gridBackground
        tableView.rowSizeStyle = .custom
        tableView.floatsGroupRows = true
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        let header = GridHeaderView()
        header.controller = self
        tableView.headerView = header
        tableView.setAccessibilityLabel("Records")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.gridBackground

        summaryBar.controller = self
        summaryBar.tableView = tableView
        summaryBar.clipView = scrollView.contentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        container.addSubview(scrollView)
        container.addSubview(summaryBar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: summaryBar.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            summaryBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func clipBoundsChanged() {
        summaryBar.needsDisplay = true
    }

    // MARK: - Updates from SwiftUI

    func update(session: BaseSession, view: ViewModel, fields: [FieldModel], result: ViewResult, revision: Int) {
        self.session = session
        let previousCursorKey = cursorKey()
        self.view = view
        let newHeight = CGFloat(view.config.rowHeight?.points ?? RowHeight.short.points)
        let signature = columnsSignature(fields: fields, view: view)
        let heightChanged = newHeight != rowHeight
        rowHeight = newHeight
        let rowsChanged = result.rows != rows
        self.fields = fields
        rows = result.rows
        recordIDs = result.recordIDs
        var ordinal = 0
        ordinals.removeAll(keepingCapacity: true)
        for (i, row) in rows.enumerated() where row.recordID != nil {
            ordinal += 1
            ordinals[i] = ordinal
        }
        if signature != columnSignature {
            rebuildColumns()
            columnSignature = signature
        }
        tableView.allowsColumnReordering = !view.config.isLocked
        let revisionChanged = revision != lastRevision
        lastRevision = revision
        if editor != nil {
            // Keep the cursor pointing at the same record and field while rows move underneath.
            pendingReload = true
            remapCursor(previousCursorKey)
        } else if rowsChanged || revisionChanged || heightChanged {
            tableView.reloadData()
            if heightChanged { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows)) }
            restoreCursor(previousCursorKey)
        }
        updateSummaries()
    }

    private func columnsSignature(fields: [FieldModel], view: ViewModel) -> String {
        fields.map { f in "\(f.id):\(f.name):\(f.type.rawValue):\(Int(view.config.columnWidths?[f.id] ?? 0))" }.joined(separator: "|")
            + (view.config.isLocked ? "|locked" : "")
    }

    private func defaultWidth(_ field: FieldModel, isPrimary: Bool) -> CGFloat {
        if isPrimary { return 220 }
        switch field.type {
        case .checkbox: return 96
        case .rating: return 120
        case .number, .currency, .percent, .duration, .count, .autoNumber: return 130
        case .multilineText: return 260
        case .date, .createdTime, .lastModifiedTime: return 150
        default: return 170
        }
    }

    private func rebuildColumns() {
        rebuildingColumns = true
        defer { rebuildingColumns = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        let rowColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.rowColumnID))
        rowColumn.width = 58
        rowColumn.minWidth = 58
        rowColumn.maxWidth = 58
        rowColumn.resizingMask = []
        let rowHeader = FieldHeaderCell(textCell: "")
        rowColumn.headerCell = rowHeader
        tableView.addTableColumn(rowColumn)

        let primaryID = document.primaryField(of: view.tableID)?.id
        for field in fields {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.id))
            column.width = CGFloat(view.config.columnWidths?[field.id] ?? Double(defaultWidth(field, isPrimary: field.id == primaryID)))
            column.minWidth = 60
            column.maxWidth = 1200
            column.resizingMask = view.config.isLocked ? [] : .userResizingMask
            let header = FieldHeaderCell(textCell: field.name)
            header.field = field
            column.headerCell = header
            column.headerToolTip = field.description.isEmpty ? "\(field.name) · \(field.type.displayName)" : field.description
            tableView.addTableColumn(column)
        }
        let add = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.addColumnID))
        add.width = 48
        add.minWidth = 48
        add.maxWidth = 48
        add.resizingMask = []
        let addHeader = FieldHeaderCell(textCell: "")
        addHeader.isAddColumn = true
        add.headerCell = addHeader
        add.headerToolTip = "Add a field"
        tableView.addTableColumn(add)
        tableView.reloadData()
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count + 1
    }

    var addRowIndex: Int { rows.count }

    func isGroupRow(_ row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row >= rows.count { return 34 }
        if case .group(let g) = rows[row] { return g.depth == 0 ? 44 : 38 }
        return rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row >= rows.count {
            return addRowView(for: tableColumn)
        }
        switch rows[row] {
        case .group(let header):
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("group"), owner: nil) as? GroupHeaderView) ?? GroupHeaderView()
            v.identifier = NSUserInterfaceItemIdentifier("group")
            v.header = header
            v.fieldValue = header.value
            v.fieldName = document.field(header.fieldID)?.name ?? ""
            v.collapsed = callbacks.collapsedGroups().contains(header.id)
            v.needsDisplay = true
            return v
        case .record(let recordID):
            guard let tableColumn, let record = document.record(recordID) else { return nil }
            let id = tableColumn.identifier.rawValue
            if id == Self.rowColumnID {
                let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("rownum"), owner: nil) as? RowNumberCellView) ?? RowNumberCellView()
                v.identifier = NSUserInterfaceItemIdentifier("rownum")
                v.number = ordinals[row] ?? 0
                v.hovering = row == hoverRow
                v.rowSelected = selectedRows.contains(row)
                v.commentCount = document.commentCount(for: recordID)
                return v
            }
            if id == Self.addColumnID { return nil }
            guard let fieldIndex = fields.firstIndex(where: { $0.id == id }) else { return nil }
            let field = fields[fieldIndex]
            let v = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? GridCellView) ?? GridCellView()
            v.identifier = NSUserInterfaceItemIdentifier("cell")
            v.isPrimary = fieldIndex == 0
            let storage = session.storage
            v.presentation = CellPresentation(
                value: document.value(record, field),
                field: field,
                text: document.displayString(record, field),
                lookupTarget: field.type == .lookup ? document.field(field.options.targetFieldID) : nil,
                attachmentURL: { storage.url(for: $0) },
                rowHeight: rowHeight
            )
            applySelection(to: v, row: row, column: fieldIndex)
            return v
        }
    }

    private func addRowView(for column: NSTableColumn?) -> NSView? {
        guard let column else { return nil }
        let id = column.identifier.rawValue
        if id == Self.rowColumnID {
            let image = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add record")!)
            image.contentTintColor = .secondaryLabelColor
            image.imageAlignment = .alignCenter
            return image
        }
        if let first = fields.first, id == first.id {
            let label = NSTextField(labelWithString: "Add record")
            label.textColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 12)
            let wrapper = NSView()
            wrapper.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            ])
            return wrapper
        }
        return nil
    }

    // MARK: - Columns

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let last = tableView.tableColumns.count - 1
        if columnIndex <= 1 || columnIndex == last { return false }
        if newColumnIndex == -1 { return true }
        return newColumnIndex >= 2 && newColumnIndex < last
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard !rebuildingColumns else { return }
        let visibleOrder = tableView.tableColumns.map(\.identifier.rawValue).filter { $0 != Self.rowColumnID && $0 != Self.addColumnID }
        let all = document.orderedFields(for: view).map(\.id)
        let hidden = all.filter { !visibleOrder.contains($0) }
        let viewID = view.id
        columnSignature = ""
        document.updateViewConfig(viewID, actionName: "Move Field") { $0.fieldOrder = visibleOrder + hidden }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !rebuildingColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        let id = column.identifier.rawValue
        guard id != Self.rowColumnID && id != Self.addColumnID else { return }
        summaryBar.needsDisplay = true
        widthSaveTask?.cancel()
        let viewID = view.id
        widthSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            var widths: [String: Double] = [:]
            for c in self.tableView.tableColumns where c.identifier.rawValue != Self.rowColumnID && c.identifier.rawValue != Self.addColumnID {
                widths[c.identifier.rawValue] = Double(c.width.rounded())
            }
            self.document.updateViewConfig(viewID, actionName: "Resize Field") { config in
                var merged = config.columnWidths ?? [:]
                merged.merge(widths) { _, new in new }
                config.columnWidths = merged
            }
        }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        guard let index = tableView.tableColumns.firstIndex(of: tableColumn), let header = tableView.headerView else { return }
        let rect = header.headerRect(ofColumn: index)
        if id == Self.addColumnID {
            showFieldConfig(fieldID: nil, relativeTo: rect, of: header)
        } else if id != Self.rowColumnID, let menu = headerMenu(forColumn: index) {
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: header)
        }
    }

    func headerMenu(forColumn column: Int) -> NSMenu? {
        guard column >= 0, column < tableView.tableColumns.count else { return nil }
        let id = tableView.tableColumns[column].identifier.rawValue
        guard let field = document.field(id), let header = tableView.headerView else { return nil }
        let rect = header.headerRect(ofColumn: column)
        let isPrimary = document.primaryField(of: view.tableID)?.id == field.id
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Edit field", image: "pencil") { [weak self] in
            self?.showFieldConfig(fieldID: field.id, relativeTo: rect, of: header)
        })
        menu.addItem(ActionMenuItem("Duplicate field", image: "plus.square.on.square") { [weak self] in
            _ = self?.document.duplicateField(field.id, includeValues: true)
        })
        menu.addItem(ActionMenuItem("Insert left", image: "arrow.left.to.line") { [weak self] in
            self?.showFieldConfig(fieldID: nil, insertAfter: self?.fieldBefore(field.id), relativeTo: rect, of: header)
        })
        menu.addItem(ActionMenuItem("Insert right", image: "arrow.right.to.line") { [weak self] in
            self?.showFieldConfig(fieldID: nil, insertAfter: field.id, relativeTo: rect, of: header)
        })
        let locked = view.config.isLocked
        menu.addItem(.separator())
        if !locked {
        menu.addItem(ActionMenuItem("Sort ascending", image: "arrow.up") { [weak self] in
            guard let self else { return }
            self.document.updateViewConfig(self.view.id, actionName: "Sort") { $0.sorts = [SortSpec(fieldID: field.id, ascending: true)] }
        })
        menu.addItem(ActionMenuItem("Sort descending", image: "arrow.down") { [weak self] in
            guard let self else { return }
            self.document.updateViewConfig(self.view.id, actionName: "Sort") { $0.sorts = [SortSpec(fieldID: field.id, ascending: false)] }
        })
        menu.addItem(ActionMenuItem("Group by this field", image: "rectangle.3.group") { [weak self] in
            guard let self else { return }
            self.document.updateViewConfig(self.view.id, actionName: "Group") { $0.groups = [SortSpec(fieldID: field.id)] }
        })
        menu.addItem(ActionMenuItem("Filter by this field", image: "line.3.horizontal.decrease") { [weak self] in
            guard let self else { return }
            self.document.updateViewConfig(self.view.id, actionName: "Filter") { config in
                var filter = config.filter ?? FilterGroup()
                let op = FilterOperator.available(for: field.type).first ?? .contains
                filter.conditions.append(FilterCondition(fieldID: field.id, op: op, value: field.type == .checkbox ? .bool(true) : nil))
                config.filter = filter
            }
        })
        }
        menu.addItem(.separator())
        if !isPrimary {
            if field.type.canBePrimary {
                menu.addItem(ActionMenuItem("Set as primary field", image: "star") { [weak self] in
                    guard let self else { return }
                    self.document.setPrimaryField(field.id, in: self.view.tableID)
                })
            }
            if !locked { menu.addItem(ActionMenuItem("Hide field", image: "eye.slash") { [weak self] in
                guard let self else { return }
                self.document.updateViewConfig(self.view.id, actionName: "Hide Field") { config in
                    var set = config.hidden
                    set.insert(field.id)
                    config.hiddenFieldIDs = Array(set)
                }
            }) }
            menu.addItem(.separator())
            let delete = ActionMenuItem("Delete field", image: "trash") { [weak self] in
                self?.confirmDeleteField(field)
            }
            menu.addItem(delete)
        }
        return menu
    }

    private func fieldBefore(_ id: String) -> String? {
        guard let i = fields.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return fields[i - 1].id
    }

    private func confirmDeleteField(_ field: FieldModel) {
        let alert = NSAlert()
        alert.messageText = "Delete the field “\(field.name)”?"
        alert.informativeText = "Its values are removed from every record. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Delete Field")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if let window = tableView.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.document.deleteField(field.id) }
            }
        }
    }

    func showFieldConfig(fieldID: String?, insertAfter: String? = nil, relativeTo rect: NSRect, of view: NSView) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        let tableID = self.view.tableID
        let after = insertAfter ?? (fieldID == nil ? fields.last?.id : nil)
        pop.contentViewController = NSHostingController(rootView: FieldConfigView(document: document, tableID: tableID, fieldID: fieldID, insertAfter: after) { [weak pop] in
            pop?.close()
        })
        pop.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = pop
    }

    func showAddField() {
        guard let header = tableView.headerView, let index = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == Self.addColumnID }) else { return }
        tableView.scrollColumnToVisible(index)
        showFieldConfig(fieldID: nil, relativeTo: header.headerRect(ofColumn: index), of: header)
    }

    // MARK: - Summaries

    private func updateSummaries() {
        var out: [String: String] = [:]
        for field in fields {
            guard let fn = view.config.summaries?[field.id], fn != .none else { continue }
            out[field.id] = document.summary(fn, field: field, recordIDs: recordIDs)
        }
        summaryBar.summaries = out
        summaryBar.recordCountText = "\(recordIDs.count) record\(recordIDs.count == 1 ? "" : "s")"
    }

    func summaryMenu(forFieldID fieldID: String) -> NSMenu? {
        guard let field = document.field(fieldID), !view.config.isLocked else { return nil }
        let menu = NSMenu()
        let current = view.config.summaries?[fieldID] ?? SummaryFunction.none
        for fn in SummaryFunction.available(for: field.type) {
            let item = ActionMenuItem(fn.displayName, image: nil) { [weak self] in
                guard let self else { return }
                self.document.updateViewConfig(self.view.id, actionName: "Change Summary") { config in
                    var s = config.summaries ?? [:]
                    s[fieldID] = fn == .none ? nil : fn
                    config.summaries = s.isEmpty ? nil : s
                }
            }
            item.state = fn == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Selection

    var hasSelection: Bool { cursor != nil || !selectedRows.isEmpty }

    private func cursorKey() -> (String, String)? {
        guard let c = cursor, c.row < rows.count, let rid = rows[c.row].recordID, c.column < fields.count else { return nil }
        return (rid, fields[c.column].id)
    }

    private func remapCursor(_ key: (String, String)?) {
        guard let key, let row = rows.firstIndex(where: { $0.recordID == key.0 }), let col = fields.firstIndex(where: { $0.id == key.1 }) else {
            cursor = nil
            anchor = nil
            return
        }
        cursor = GridPosition(row: row, column: col)
        anchor = cursor
    }

    /// The cursor, if it still points at a record row and a visible field.
    private var validCursor: GridPosition? {
        guard let c = cursor, c.row >= 0, c.row < rows.count, rows[c.row].recordID != nil, c.column >= 0, c.column < fields.count else { return nil }
        return c
    }

    private func restoreCursor(_ key: (String, String)?) {
        selectedRows = IndexSet()
        guard let key, let row = rows.firstIndex(where: { $0.recordID == key.0 }), let col = fields.firstIndex(where: { $0.id == key.1 }) else {
            if let c = cursor, c.row >= rows.count || c.column >= fields.count || isGroupRow(c.row) { cursor = nil; anchor = nil }
            return
        }
        cursor = GridPosition(row: row, column: col)
        anchor = cursor
        refreshSelection()
    }

    private var range: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        guard let c = cursor else { return nil }
        let a = anchor ?? c
        return (min(a.row, c.row)...max(a.row, c.row), min(a.column, c.column)...max(a.column, c.column))
    }

    private func applySelection(to cell: GridCellView, row: Int, column: Int) {
        cell.isCursor = cursor == GridPosition(row: row, column: column) && editingPosition == nil
        if let r = range, r.rows.count * r.cols.count > 1 {
            cell.inRange = r.rows.contains(row) && r.cols.contains(column)
        } else {
            cell.inRange = false
        }
        cell.rowSelected = selectedRows.contains(row)
    }

    private func refreshSelection() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            for (colIndex, column) in tableView.tableColumns.enumerated() {
                guard let v = tableView.view(atColumn: colIndex, row: row, makeIfNecessary: false) else { continue }
                if let cell = v as? GridCellView, let fi = fields.firstIndex(where: { $0.id == column.identifier.rawValue }) {
                    applySelection(to: cell, row: row, column: fi)
                } else if let num = v as? RowNumberCellView {
                    num.rowSelected = selectedRows.contains(row)
                    num.hovering = row == hoverRow
                }
            }
        }
    }

    private func setCursor(_ pos: GridPosition?, extend: Bool = false) {
        cursor = pos
        if !extend { anchor = pos }
        if pos != nil { selectedRows = IndexSet() }
        refreshSelection()
        if let pos {
            tableView.scrollRowToVisible(pos.row)
            if let colIndex = tableColumnIndex(forField: pos.column) { tableView.scrollColumnToVisible(colIndex) }
        }
    }

    private func tableColumnIndex(forField index: Int) -> Int? {
        guard index < fields.count else { return nil }
        return tableView.tableColumns.firstIndex { $0.identifier.rawValue == fields[index].id }
    }

    private func fieldIndex(forTableColumn index: Int) -> Int? {
        guard index >= 0, index < tableView.tableColumns.count else { return nil }
        let id = tableView.tableColumns[index].identifier.rawValue
        return fields.firstIndex { $0.id == id }
    }

    /// Field indexes in on-screen column order (columns can be dragged before the order is saved).
    private var visualFieldOrder: [Int] {
        tableView.tableColumns.compactMap { c in fields.firstIndex { $0.id == c.identifier.rawValue } }
    }

    private func nextRecordRow(from row: Int, step: Int) -> Int? {
        var r = row + step
        while r >= 0 && r < rows.count {
            if rows[r].recordID != nil { return r }
            r += step
        }
        return nil
    }

    func selectAllRecords() {
        selectedRows = IndexSet(rows.indices.filter { rows[$0].recordID != nil })
        cursor = nil
        anchor = nil
        refreshSelection()
    }

    func hover(at point: NSPoint?) {
        let row = point.map { tableView.row(at: $0) } ?? -1
        guard row != hoverRow else { return }
        let old = hoverRow
        hoverRow = row
        for r in [old, row] where r >= 0 && r < rows.count {
            if let v = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? RowNumberCellView {
                v.hovering = r == hoverRow
            }
        }
    }

    // MARK: - Mouse

    func handleMouseDown(_ event: NSEvent) -> Bool {
        // Finish any edit first: committing can reload the table and move rows.
        commitEditing()
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        let col = tableView.column(at: point)
        guard row >= 0, row <= rows.count else {
            setCursor(nil)
            return true
        }
        if row == addRowIndex {
            addRecord()
            return true
        }
        if case .group(let header) = rows[row] {
            callbacks.toggleGroup(header.id)
            return true
        }
        guard let recordID = rows[row].recordID, col >= 0, col < tableView.tableColumns.count else { return true }
        let columnID = tableView.tableColumns[col].identifier.rawValue
        if columnID == Self.rowColumnID {
            if let v = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? RowNumberCellView,
               v.expandRect.contains(v.convert(point, from: tableView)) {
                callbacks.expand(recordID, recordIDs)
                return true
            }
            if event.clickCount == 2 {
                callbacks.expand(recordID, recordIDs)
                return true
            }
            if event.modifierFlags.contains(.command) {
                if selectedRows.contains(row) { selectedRows.remove(row) } else { selectedRows.insert(row) }
            } else if event.modifierFlags.contains(.shift), let last = selectedRows.last ?? cursor?.row {
                selectedRows.insert(integersIn: min(last, row)...max(last, row))
                selectedRows = selectedRows.filteredIndexSet { rows.indices.contains($0) && rows[$0].recordID != nil }
            } else {
                selectedRows = [row]
            }
            cursor = nil
            anchor = nil
            refreshSelection()
            return true
        }
        guard let fi = fieldIndex(forTableColumn: col) else { return true }
        let pos = GridPosition(row: row, column: fi)
        let field = fields[fi]

        if event.modifierFlags.contains(.shift), cursor != nil {
            setCursor(pos, extend: true)
            return true
        }
        let wasCursor = cursor == pos
        setCursor(pos)

        // Direct manipulation for a few types.
        if let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? GridCellView {
            let local = cell.convert(point, from: tableView)
            switch field.type {
            case .checkbox where field.isEditable:
                if abs(local.x - cell.bounds.midX) < 16 || wasCursor { toggleCheckbox(recordID: recordID, field: field) }
                return true
            case .rating:
                if let value = cell.ratingValue(at: local) {
                    let current = Int(clampedRating(document.value(recordID: recordID, fieldID: field.id).numberValue, max: field.options.ratingMax ?? 5))
                    document.updateRecord(recordID, values: [field.id: value == current ? .null : .number(Double(value))], actionName: "Edit Cell")
                }
                return true
            case .button:
                callbacks.runButton(recordID, field.id)
                return true
            case .url, .email:
                if event.modifierFlags.contains(.command) { openLink(recordID: recordID, field: field) }
            default:
                break
            }
        }
        if event.clickCount == 2 {
            beginEditing(pos)
            return true
        }
        trackDragSelection(from: pos)
        return true
    }

    private func trackDragSelection(from start: GridPosition) {
        guard let window = tableView.window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = tableView.convert(next.locationInWindow, from: nil)
            tableView.autoscroll(with: next)
            let r = tableView.row(at: p)
            let c = tableView.column(at: p)
            guard r >= 0, r < rows.count, rows[r].recordID != nil, let fi = fieldIndex(forTableColumn: c) else { continue }
            let pos = GridPosition(row: r, column: fi)
            if pos != cursor {
                cursor = pos
                anchor = start
                refreshSelection()
            }
        }
    }

    private func openLink(recordID: String, field: FieldModel) {
        let text = document.displayString(document.record(recordID)!, field)
        let url = field.type == .email ? URL(string: "mailto:\(text)") : URL(string: text.hasPrefix("http") ? text : "https://\(text)")
        if let url { NSWorkspace.shared.open(url) }
    }

    private func toggleCheckbox(recordID: String, field: FieldModel) {
        let current: Bool = { if case .bool(true) = document.value(recordID: recordID, fieldID: field.id) { return true } else { return false } }()
        document.updateRecord(recordID, values: [field.id: .bool(!current)], actionName: "Edit Cell")
    }

    // MARK: - Keyboard

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard editor == nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        switch event.keyCode {
        case 123: move(dx: -1, dy: 0, extend: shift, jump: command); return true
        case 124: move(dx: 1, dy: 0, extend: shift, jump: command); return true
        case 125: move(dx: 0, dy: 1, extend: shift, jump: command); return true
        case 126: move(dx: 0, dy: -1, extend: shift, jump: command); return true
        case 48:
            move(dx: shift ? -1 : 1, dy: 0, extend: false, jump: false, wrap: true)
            return true
        case 36, 76:
            if shift { addRecord(after: validCursor.flatMap { rows[$0.row].recordID }); return true }
            if let c = validCursor { beginEditing(c) }
            return true
        case 53:
            if selectedRows.isEmpty && (anchor == cursor) { setCursor(nil) } else {
                selectedRows = IndexSet()
                anchor = cursor
                refreshSelection()
            }
            return true
        case 51, 117:
            deleteOrClear()
            return true
        case 49 where !command:
            expandSelection()
            return true
        default:
            break
        }
        if command || flags.contains(.control) { return false }
        guard let chars = event.characters, let scalar = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), let c = validCursor else { return false }
        let field = fields[c.column]
        if field.type == .rating, let n = Int(chars), n >= 0, let rid = rows[c.row].recordID {
            let clamped = min(n, field.options.ratingMax ?? 5)
            document.updateRecord(rid, values: [field.id: clamped == 0 ? .null : .number(Double(clamped))], actionName: "Edit Cell")
            return true
        }
        if field.type == .checkbox, chars == " " {
            if let rid = rows[c.row].recordID { toggleCheckbox(recordID: rid, field: field) }
            return true
        }
        beginEditing(c, initialText: chars)
        return true
    }

    private func move(dx: Int, dy: Int, extend: Bool, jump: Bool, wrap: Bool = false) {
        guard !fields.isEmpty else { return }
        guard var pos = validCursor else {
            if let first = rows.firstIndex(where: { $0.recordID != nil }) { setCursor(GridPosition(row: first, column: 0)) }
            return
        }
        let order = visualFieldOrder
        var visual = order.firstIndex(of: pos.column) ?? 0
        if dx != 0 {
            if jump {
                visual = dx < 0 ? 0 : order.count - 1
            } else {
                visual += dx
                if wrap {
                    if visual >= order.count, let next = nextRecordRow(from: pos.row, step: 1) {
                        visual = 0
                        pos.row = next
                    } else if visual < 0, let prev = nextRecordRow(from: pos.row, step: -1) {
                        visual = order.count - 1
                        pos.row = prev
                    }
                }
                visual = max(0, min(order.count - 1, visual))
            }
            pos.column = order[visual]
        }
        if dy != 0 {
            if jump {
                let recordRows = rows.indices.filter { rows[$0].recordID != nil }
                if let target = dy < 0 ? recordRows.first : recordRows.last { pos.row = target }
            } else if let next = nextRecordRow(from: pos.row, step: dy) {
                pos.row = next
            }
        }
        setCursor(pos, extend: extend)
    }

    func deleteOrClear() {
        if !selectedRows.isEmpty {
            let ids = selectedRows.compactMap { rows.indices.contains($0) ? rows[$0].recordID : nil }
            selectedRows = IndexSet()
            document.deleteRecords(ids)
        } else {
            clearSelectedCells()
        }
    }

    func clearSelectedCells() {
        guard let r = range else { return }
        var updates: [String: [String: JSONValue]] = [:]
        for row in r.rows {
            guard row < rows.count, let rid = rows[row].recordID else { continue }
            for col in r.cols where col < fields.count && fields[col].isEditable {
                updates[rid, default: [:]][fields[col].id] = fields[col].type == .checkbox ? .bool(false) : .null
            }
        }
        if !updates.isEmpty { document.updateRecords(updates, actionName: "Clear Cells") }
    }

    // MARK: - Records

    func addRecord(after afterID: String? = nil) {
        commitEditing()
        let id = document.createRecord(in: view.tableID, values: initialValuesFromFilter(), after: afterID)
        DispatchQueue.main.async { [weak self] in
            guard let self, let row = self.rows.firstIndex(where: { $0.recordID == id }) else { return }
            self.setCursor(GridPosition(row: row, column: 0))
            self.beginEditing(GridPosition(row: row, column: 0))
        }
    }

    /// New records pick up simple "is" filter values so they stay visible in the filtered view.
    private func initialValuesFromFilter() -> [String: JSONValue] {
        guard let filter = view.config.filter, filter.conjunction == .and else { return [:] }
        var values: [String: JSONValue] = [:]
        for c in filter.conditions {
            guard let f = document.field(c.fieldID), f.isEditable, let v = c.value else { continue }
            switch (f.type, c.op) {
            case (.singleSelect, .is), (.singleSelect, .isAnyOf):
                if let first = v.stringArray.first ?? v.stringValue { values[f.id] = .string(first) }
            case (.checkbox, .is):
                values[f.id] = .bool(v.boolValue ?? true)
            case (.multipleSelects, .hasAnyOf), (.multipleSelects, .hasAllOf), (.multipleSelects, .isExactly):
                values[f.id] = v
            case (let t, .is) where t.isTextual:
                if let s = v.stringValue { values[f.id] = .string(s) }
            default:
                break
            }
        }
        return values
    }

    func expandSelection() {
        if let c = validCursor, let rid = rows[c.row].recordID { callbacks.expand(rid, recordIDs) }
        else if let row = selectedRows.first, row < rows.count, let rid = rows[row].recordID { callbacks.expand(rid, recordIDs) }
    }

    func deleteSelection() {
        if !selectedRows.isEmpty {
            deleteOrClear()
        } else if let c = validCursor, let rid = rows[c.row].recordID {
            document.deleteRecords([rid])
        }
    }

    // MARK: - Editing

    private func rectForCell(_ pos: GridPosition) -> NSRect? {
        guard let col = tableColumnIndex(forField: pos.column) else { return nil }
        return tableView.frameOfCell(atColumn: col, row: pos.row)
    }

    private func editText(record: RecordModel, field: FieldModel) -> String {
        let v = document.value(record, field)
        switch field.type {
        case .number, .currency:
            return v.numberValue.map { ValueParsing.editableNumber($0) } ?? ""
        case .percent:
            return v.numberValue.map { ValueParsing.editableNumber($0 * 100) } ?? ""
        default:
            return document.displayString(record, field)
        }
    }

    func beginEditing(_ pos: GridPosition, initialText: String? = nil) {
        guard pos.row < rows.count, let rid = rows[pos.row].recordID, let record = document.record(rid), pos.column < fields.count else { return }
        let field = fields[pos.column]
        guard let rect = rectForCell(pos) else { return }
        tableView.scrollRowToVisible(pos.row)

        switch field.type {
        case .checkbox:
            toggleCheckbox(recordID: rid, field: field)
            return
        case .singleLineText, .email, .url, .phoneNumber, .number, .currency, .percent, .duration:
            startInlineEditor(pos: pos, rect: rect, text: initialText ?? editText(record: record, field: field), replacing: initialText != nil)
        case .date where initialText != nil:
            startInlineEditor(pos: pos, rect: rect, text: initialText ?? "", replacing: true)
        case .button:
            callbacks.runButton(rid, field.id)
        case _ where field.type.isComputed && field.type != .button:
            showPopover(for: pos, rect: rect, recordID: rid, field: field)
        default:
            showPopover(for: pos, rect: rect, recordID: rid, field: field, initialText: initialText)
        }
    }

    private func startInlineEditor(pos: GridPosition, rect: NSRect, text: String, replacing: Bool) {
        let field = NSTextField(frame: rect.insetBy(dx: 1, dy: 1))
        field.font = GridCellView.font
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 2
        field.layer?.cornerRadius = 2
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        tableView.addSubview(field)
        editor = field
        editingPosition = pos
        if pos.row < rows.count, let rid = rows[pos.row].recordID, pos.column < fields.count {
            editingTarget = (rid, fields[pos.column].id)
        }
        editCancelled = false
        refreshSelection()
        tableView.window?.makeFirstResponder(field)
        if let editorText = field.currentEditor() {
            if replacing {
                editorText.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            } else {
                editorText.selectAll(nil)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(move: (0, 1))
            return true
        case #selector(NSResponder.insertTab(_:)):
            finishEditing(move: (1, 0))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            finishEditing(move: (-1, 0))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            editCancelled = true
            finishEditing(move: nil)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editor != nil { finishEditing(move: nil) }
    }

    func commitEditing() {
        if editor != nil { finishEditing(move: nil) }
    }

    private func finishEditing(move delta: (Int, Int)?) {
        guard let field = editor, editingPosition != nil else { return }
        let text = field.stringValue
        let target = editingTarget
        editor = nil
        editingPosition = nil
        editingTarget = nil
        field.delegate = nil
        field.removeFromSuperview()
        if !editCancelled, let target, let record = document.record(target.recordID), let f = document.field(target.fieldID),
           f.isEditable, text != editText(record: record, field: f) {
            document.setCell(recordID: target.recordID, fieldID: f.id, text: text)
        }
        tableView.window?.makeFirstResponder(tableView)
        if pendingReload {
            pendingReload = false
            let key = cursorKey()
            tableView.reloadData()
            restoreCursor(key)
        }
        if let delta { move(dx: delta.0, dy: delta.1, extend: false, jump: false, wrap: delta.0 != 0) }
        refreshSelection()
    }

    private func showPopover(for pos: GridPosition, rect: NSRect, recordID: String, field: FieldModel, initialText: String? = nil) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        let root = CellEditorPopover(session: session, recordID: recordID, fieldID: field.id, initialText: initialText) { [weak pop] in
            pop?.close()
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        pop.show(relativeTo: rect, of: tableView, preferredEdge: .maxY)
        popover = pop
    }

    // MARK: - Clipboard

    static let cellsPasteboardType = NSPasteboard.PasteboardType("com.rellwood.rowhouse.cells")

    func copySelection() {
        var cells: [[(RecordModel, FieldModel)]] = []
        if !selectedRows.isEmpty {
            for row in selectedRows where row < rows.count {
                guard let rid = rows[row].recordID, let record = document.record(rid) else { continue }
                cells.append(visualFieldOrder.map { (record, fields[$0]) })
            }
        } else if let r = range {
            let order = visualFieldOrder.filter { r.cols.contains($0) }
            for row in r.rows {
                guard row < rows.count, let rid = rows[row].recordID, let record = document.record(rid) else { continue }
                cells.append(order.map { (record, fields[$0]) })
            }
        }
        guard !cells.isEmpty else { return }
        let text = cells.map { line in
            line.map { CSV.escape(document.displayString($0.0, $0.1), delimiter: "\t") }.joined(separator: "\t")
        }.joined(separator: "\n")
        // Alongside the text, keep the raw values so pasting inside RowHouse is lossless
        // (option and record names can contain commas).
        let raw: JSONValue = .array(cells.map { line in
            .array(line.map { record, field in
                .object(["type": .string(field.type.rawValue), "field": .string(field.id), "value": document.editableValue(record, field)])
            })
        })
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, Self.cellsPasteboardType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(raw.serialized(), forType: Self.cellsPasteboardType)
    }

    /// A raw value copied from RowHouse, usable as-is when pasted into a compatible field.
    private func rawPasteValue(_ cell: JSONValue?, into field: FieldModel) -> JSONValue? {
        guard let cell, cell["type"]?.stringValue == field.type.rawValue, let value = cell["value"] else { return nil }
        switch field.type {
        case .singleSelect, .multipleSelects:
            // Choice ids belong to one field; only reuse them within the same field.
            return cell["field"]?.stringValue == field.id ? value : nil
        case .link:
            let ids = value.stringArray
            return ids.allSatisfy({ document.record($0)?.tableID == field.options.linkedTableID }) ? value : nil
        default:
            return field.isEditable ? value : nil
        }
    }

    func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), let start = range.map({ GridPosition(row: $0.rows.lowerBound, column: $0.cols.lowerBound) }) ?? validCursor else { return }
        let grid = text.contains("\t") || text.contains("\n") ? CSV.parse(text, delimiter: "\t") : [[text]]
        let rawGrid = NSPasteboard.general.data(forType: Self.cellsPasteboardType).flatMap { try? JSONValue.parse($0) }?.arrayValue?.map { $0.arrayValue ?? [] }
        func raw(_ r: Int, _ c: Int) -> JSONValue? {
            guard let rawGrid, r < rawGrid.count, c < rawGrid[r].count else { return nil }
            return rawGrid[r][c]
        }
        guard !grid.isEmpty else { return }
        let order = visualFieldOrder
        guard let startVisual = order.firstIndex(of: start.column) else { return }
        // A single value pasted over a range fills the whole range.
        let fillRange = grid.count == 1 && grid[0].count == 1 ? range : nil
        document.batch("Paste") {
            if let fill = fillRange {
                for row in fill.rows {
                    guard row < rows.count, let rid = rows[row].recordID else { continue }
                    for col in fill.cols where col < fields.count && fields[col].isEditable {
                        if let value = rawPasteValue(raw(0, 0), into: fields[col]) {
                            document.updateRecord(rid, values: [fields[col].id: value], actionName: "Paste")
                        } else {
                            document.setCell(recordID: rid, fieldID: fields[col].id, text: grid[0][0])
                        }
                    }
                }
                return
            }
            var row: Int? = start.row
            var lastRecord: String?
            for (lineIndex, line) in grid.enumerated() {
                var recordID: String?
                if let r = row, r < rows.count { recordID = rows[r].recordID }
                if recordID == nil { recordID = document.createRecord(in: view.tableID, after: lastRecord) }
                guard let rid = recordID else { continue }
                lastRecord = rid
                for (i, value) in line.enumerated() {
                    let visual = startVisual + i
                    guard visual < order.count else { break }
                    let f = fields[order[visual]]
                    guard f.isEditable else { continue }
                    if let rawValue = rawPasteValue(raw(lineIndex, i), into: f) {
                        document.updateRecord(rid, values: [f.id: rawValue], actionName: "Paste")
                    } else {
                        document.setCell(recordID: rid, fieldID: f.id, text: value)
                    }
                }
                row = row.flatMap { nextRecordRow(from: $0, step: 1) }
            }
        }
    }

    // MARK: - Context menu

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, row < rows.count, let rid = rows[row].recordID else { return nil }
        let col = tableView.column(at: point)
        if !selectedRows.contains(row) {
            if let fi = fieldIndex(forTableColumn: col) {
                let pos = GridPosition(row: row, column: fi)
                if let r = range, r.rows.contains(row), r.cols.contains(fi) {} else { setCursor(pos) }
            } else {
                selectedRows = [row]
                cursor = nil
                refreshSelection()
            }
        }
        let targets = selectedRows.isEmpty ? [rid] : selectedRows.compactMap { rows[$0].recordID }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Expand record", image: "arrow.up.left.and.arrow.down.right") { [weak self] in
            guard let self else { return }
            self.callbacks.expand(rid, self.recordIDs)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Insert record above", image: "arrow.up.to.line") { [weak self] in
            guard let self else { return }
            let prev = self.nextRecordRow(from: row, step: -1).flatMap { self.rows[$0].recordID }
            let id = self.document.createRecord(in: self.view.tableID, after: prev)
            if prev == nil { self.document.moveRecord(id, before: rid) }
        })
        menu.addItem(ActionMenuItem("Insert record below", image: "arrow.down.to.line") { [weak self] in
            self?.addRecord(after: rid)
        })
        menu.addItem(ActionMenuItem(targets.count > 1 ? "Duplicate \(targets.count) records" : "Duplicate record", image: "plus.square.on.square") { [weak self] in
            _ = self?.document.duplicateRecords(targets)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy", image: "doc.on.doc") { [weak self] in self?.copySelection() })
        menu.addItem(ActionMenuItem("Paste", image: "doc.on.clipboard") { [weak self] in self?.pasteClipboard() })
        menu.addItem(ActionMenuItem("Copy record link", image: "link") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("rowhouse://record?base=\(self.document.baseID)&table=\(self.view.tableID)&record=\(rid)", forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(targets.count > 1 ? "Delete \(targets.count) records" : "Delete record", image: "trash") { [weak self] in
            self?.document.deleteRecords(targets)
        })
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: String?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Ratings from other devices or scripts may be out of range; never trap on them.
func clampedRating(_ value: Double?, max: Int) -> Double {
    guard let value, value.isFinite else { return 0 }
    return Swift.min(Swift.max(0, value.rounded()), Double(Swift.max(1, max)))
}
