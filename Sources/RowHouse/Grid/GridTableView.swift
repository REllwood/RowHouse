import AppKit
import RowHouseCore

struct GridPosition: Equatable, Hashable {
    var row: Int
    /// Index into the controller's visible `fields`.
    var column: Int
}

/// NSTableView subclass that forwards input to the grid controller so the grid behaves like a
/// spreadsheet (cell cursor, range selection, type-to-edit) instead of a row list.
final class GridTableView: NSTableView {
    weak var controller: GridController?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if controller?.handleMouseDown(event) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(for: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hover(at: nil)
    }

    @objc func copy(_ sender: Any?) { controller?.copySelection() }
    @objc func paste(_ sender: Any?) { controller?.pasteClipboard() }
    @objc func cut(_ sender: Any?) {
        controller?.copySelection()
        controller?.clearSelectedCells()
    }
    override func selectAll(_ sender: Any?) { controller?.selectAllRecords() }
    @objc func delete(_ sender: Any?) { controller?.deleteOrClear() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return controller?.hasSelection ?? false
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil && controller?.hasSelection == true
        case #selector(selectAll(_:)): return true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func drawGrid(inClipRect clipRect: NSRect) {
        // Horizontal lines everywhere; vertical lines only across record rows (not group headers).
        Theme.gridLine.setFill()
        let rows = self.rows(in: clipRect)
        for row in rows.location..<(rows.location + rows.length) {
            let r = rect(ofRow: row)
            NSRect(x: clipRect.minX, y: r.maxY - 1, width: clipRect.width, height: 1).fill()
            if controller?.isGroupRow(row) == true { continue }
            for (i, _) in tableColumns.enumerated() {
                let c = rect(ofColumn: i)
                guard c.maxX >= clipRect.minX && c.minX <= clipRect.maxX else { continue }
                NSRect(x: c.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            }
        }
    }
}

/// Row background that washes the row in its record's colour when the view colours records.
final class GridRowView: NSTableRowView {
    var tint: NSColor? { didSet { if oldValue != tint { needsDisplay = true } } }

    static func tint(for color: ChoiceColor) -> NSColor {
        let solid = Theme.solid(color)
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            return solid.withAlphaComponent(dark ? 0.075 : 0.055)
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint else { return }
        tint.setFill()
        dirtyRect.intersection(bounds).fill(using: .sourceOver)
    }
}

final class GridHeaderView: NSTableHeaderView {
    weak var controller: GridController?

    override var frame: NSRect {
        get { super.frame }
        set {
            var f = newValue
            f.size.height = 34
            super.frame = f
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let column = self.column(at: convert(event.locationInWindow, from: nil))
        return controller?.headerMenu(forColumn: column)
    }
}

final class FieldHeaderCell: NSTableHeaderCell {
    var field: FieldModel?
    var isAddColumn = false
    var sortIndicator: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.headerBackground.setFill()
        cellFrame.fill()
        Theme.gridLine.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if isAddColumn {
            if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add field")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium).applying(.init(paletteColors: [.secondaryLabelColor]))) {
                let s = img.size
                img.draw(in: NSRect(x: cellFrame.midX - s.width / 2, y: cellFrame.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        guard let field else { return }
        var x = cellFrame.minX + 9
        if let img = NSImage(systemSymbolName: field.type.symbolName, accessibilityDescription: field.type.displayName)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            let s = img.size
            img.draw(in: NSRect(x: x, y: cellFrame.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 20
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let right = cellFrame.maxX - 22
        NSAttributedString(string: field.name, attributes: attrs)
            .draw(with: NSRect(x: x, y: cellFrame.midY - 8, width: max(0, right - x), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [.tertiaryLabelColor]))) {
            let s = chevron.size
            chevron.draw(in: NSRect(x: cellFrame.maxX - 16, y: cellFrame.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// Footer with per-column summaries (sum, average, filled…), scrolled in sync with the grid.
final class SummaryBar: NSView {
    weak var controller: GridController?
    weak var tableView: NSTableView?
    weak var clipView: NSClipView?
    var summaries: [String: String] = [:] { didSet { needsDisplay = true } }
    var recordCountText = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.headerBackground.setFill()
        bounds.fill()
        Theme.gridLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard let tableView else { return }
        let offset = clipView?.bounds.origin.x ?? 0
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let columns = tableView.tableColumns
        for (i, column) in columns.enumerated() {
            var r = tableView.rect(ofColumn: i).offsetBy(dx: -offset, dy: 0)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let text: String
            if column.identifier.rawValue == GridController.rowColumnID {
                text = recordCountText
                // The count borrows the primary column's space unless that column shows a summary.
                if columns.count > 1, (summaries[columns[1].identifier.rawValue] ?? "").isEmpty {
                    r = r.union(tableView.rect(ofColumn: 1).offsetBy(dx: -offset, dy: 0))
                }
            } else if let s = summaries[column.identifier.rawValue], !s.isEmpty {
                text = s
            } else {
                continue
            }
            let style = NSMutableParagraphStyle()
            style.alignment = column.identifier.rawValue == GridController.rowColumnID ? .left : .right
            style.lineBreakMode = .byTruncatingTail
            var a = attrs
            a[.paragraphStyle] = style
            NSAttributedString(string: text, attributes: a).draw(with: NSRect(x: r.minX + 8, y: 7, width: max(0, r.width - 16), height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tableView else { return }
        let offset = clipView?.bounds.origin.x ?? 0
        let p = convert(event.locationInWindow, from: nil)
        for (i, column) in tableView.tableColumns.enumerated() {
            let r = tableView.rect(ofColumn: i).offsetBy(dx: -offset, dy: 0)
            if p.x >= r.minX && p.x < r.maxX, let menu = controller?.summaryMenu(forFieldID: column.identifier.rawValue) {
                menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: bounds.maxY), in: self)
                return
            }
        }
    }
}
