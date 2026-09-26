import AppKit
import RowHouseCore

/// Everything a grid cell needs to draw itself.
struct CellPresentation {
    var value: CellValue
    var field: FieldModel
    var text: String
    var lookupTarget: FieldModel?
    var attachmentURL: (AttachmentInfo) -> URL
    var rowHeight: CGFloat
}

/// A fast, custom-drawn grid cell. Drawing everything by hand (instead of nesting controls) keeps
/// scrolling smooth with tens of thousands of rows.
final class GridCellView: NSView {
    var presentation: CellPresentation? { didSet { needsDisplay = true } }
    var isCursor = false { didSet { if oldValue != isCursor { needsDisplay = true } } }
    var inRange = false { didSet { if oldValue != inRange { needsDisplay = true } } }
    var rowSelected = false { didSet { if oldValue != rowSelected { needsDisplay = true } } }
    var isPrimary = false
    var onRedrawRequest: (() -> Void)?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    static let font = NSFont.systemFont(ofSize: 13)
    static let chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    static let padding: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        if rowSelected || inRange {
            Theme.selectionFill.setFill()
            bounds.fill()
        }
        if let p = presentation {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 0)).addClip()
            drawContent(p, in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        if isCursor {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private var multiline: Bool { (presentation?.rowHeight ?? 32) > 40 }

    private func drawContent(_ p: CellPresentation, in bounds: NSRect) {
        let content = bounds.insetBy(dx: Self.padding, dy: 0)
        switch p.field.type {
        case .checkbox:
            if case .bool(true) = p.value { drawSymbol("checkmark.square.fill", color: .systemGreen, in: content, size: 15, centered: true) }
        case .rating:
            drawRating(p, in: content)
        case .singleSelect, .multipleSelects:
            let chips: [(String, NSColor, NSColor)]
            switch p.value {
            case .choice(let c): chips = [(c.name, Theme.chipBackground(c.color), Theme.chipText(c.color))]
            case .choices(let cs): chips = cs.map { ($0.name, Theme.chipBackground($0.color), Theme.chipText($0.color)) }
            default: chips = []
            }
            drawChips(chips, in: content, capsule: true)
        case .link:
            if case .links(let refs) = p.value {
                drawChips(refs.map { ($0.title, Theme.linkChipBackground, Theme.linkChipText) }, in: content, capsule: false)
            }
        case .attachment:
            if case .attachments(let atts) = p.value { drawAttachments(atts, p, in: content) }
        case .lookup:
            drawLookup(p, in: content)
        case .collaborator, .createdBy, .lastModifiedBy:
            if case .collaborators(let people) = p.value { drawPeople(people, in: content) }
        case .button:
            drawButton(p.text, in: content)
        default:
            drawValueText(p, in: content)
        }
    }

    private func drawValueText(_ p: CellPresentation, in rect: NSRect) {
        if case .error = p.value {
            drawText("#ERROR!", color: .systemRed, font: Self.font, in: rect, alignment: .left)
            return
        }
        if case .list = p.value, p.field.type == .rollup || p.field.type == .formula {
            drawChips(p.text.isEmpty ? [] : p.text.components(separatedBy: ", ").map { ($0, Theme.lookupChipBackground, NSColor.labelColor) }, in: rect, capsule: false)
            return
        }
        guard !p.text.isEmpty else { return }
        let numeric: Bool = {
            switch p.field.type {
            case .number, .currency, .percent, .duration, .count, .autoNumber: return true
            case .formula, .rollup: if case .number = p.value { return true } else { return false }
            default: return false
            }
        }()
        let isLink = p.field.type == .url || p.field.type == .email
        let color: NSColor = isLink ? .linkColor : .labelColor
        let font = numeric ? Self.numberFont : (isPrimary ? NSFont.systemFont(ofSize: 13, weight: .medium) : Self.font)
        drawText(p.text, color: color, font: font, in: rect, alignment: numeric ? .right : .left, underline: isLink)
    }

    private func drawText(_ text: String, color: NSColor, font: NSFont, in rect: NSRect, alignment: NSTextAlignment, underline: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; attrs[.underlineColor] = color.withAlphaComponent(0.35) }
        let str = NSAttributedString(string: multiline ? text : text.replacingOccurrences(of: "\n", with: " "), attributes: attrs)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        if multiline {
            let r = NSRect(x: rect.minX, y: rect.minY + 7, width: rect.width, height: rect.height - 12)
            str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            let r = NSRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight)
            str.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawChips(_ chips: [(String, NSColor, NSColor)], in rect: NSRect, capsule: Bool) {
        guard !chips.isEmpty else { return }
        let height: CGFloat = 20
        var x = rect.minX
        var y = multiline ? rect.minY + 6 : rect.midY - height / 2
        for (text, bg, fg) in chips {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.chipFont, .foregroundColor: fg]
            let str = NSAttributedString(string: text, attributes: attrs)
            let w = min(ceil(str.size().width) + 16, max(40, rect.maxX - rect.minX))
            if x + w > rect.maxX && x > rect.minX {
                if multiline && y + height * 2 + 4 < rect.maxY {
                    x = rect.minX
                    y += height + 4
                } else {
                    break
                }
            }
            let chip = NSRect(x: x, y: y, width: min(w, rect.maxX - x), height: height)
            bg.setFill()
            NSBezierPath(roundedRect: chip, xRadius: capsule ? height / 2 : 4, yRadius: capsule ? height / 2 : 4).fill()
            let textRect = chip.insetBy(dx: 8, dy: 0)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var a = attrs
            a[.paragraphStyle] = style
            NSAttributedString(string: text, attributes: a).draw(with: NSRect(x: textRect.minX, y: chip.minY + 3, width: textRect.width, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += chip.width + 4
        }
    }

    private func drawPeople(_ people: [Person], in rect: NSRect) {
        guard !people.isEmpty else { return }
        let height = PersonChipDrawing.height
        var x = rect.minX
        var y = multiline ? rect.minY + 6 : rect.midY - height / 2
        for person in people {
            let w = min(PersonChipDrawing.width(of: person, font: Self.chipFont), max(40, rect.width))
            if x + w > rect.maxX && x > rect.minX {
                if multiline && y + height * 2 + 4 < rect.maxY {
                    x = rect.minX
                    y += height + 4
                } else {
                    break
                }
            }
            let chip = NSRect(x: x, y: y, width: min(w, rect.maxX - x), height: height)
            PersonChipDrawing.draw(person, in: chip, font: Self.chipFont)
            x += chip.width + 4
        }
    }

    private func drawRating(_ p: CellPresentation, in rect: NSRect) {
        let max = Swift.min(10, Swift.max(1, p.field.options.ratingMax ?? 5))
        let value = Int(clampedRating(p.value.numberValue, max: max))
        let size: CGFloat = 13
        let y = multiline ? rect.minY + 9 : rect.midY - size / 2
        for i in 0..<max {
            let r = NSRect(x: rect.minX + CGFloat(i) * (size + 3), y: y, width: size, height: size)
            let filled = i < value
            if !filled && !(isCursor || rowSelected) { continue }
            drawSymbol(filled ? "star.fill" : "star", color: filled ? Theme.star : .tertiaryLabelColor, in: r, size: size, centered: false)
        }
    }

    private func drawAttachments(_ atts: [AttachmentInfo], _ p: CellPresentation, in rect: NSRect) {
        let size = max(22, min(p.rowHeight - 10, 110))
        var x = rect.minX
        let y = multiline ? rect.minY + 5 : rect.midY - size / 2
        for att in atts {
            let box = NSRect(x: x, y: y, width: size * (att.isImage ? 1 : 0.8), height: size)
            if box.maxX > rect.maxX { break }
            let url = p.attachmentURL(att)
            if let image = ThumbnailCache.shared.cached(url, size: size) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).addClip()
                let aspect = image.size.width / max(1, image.size.height)
                var drawRect = box
                if aspect > box.width / box.height {
                    let w = box.height * aspect
                    drawRect = NSRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
                } else {
                    let h = box.width / aspect
                    drawRect = NSRect(x: box.minX, y: box.midY - h / 2, width: box.width, height: h)
                }
                image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.separatorColor.setStroke()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).stroke()
            } else {
                Theme.lookupChipBackground.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                ThumbnailCache.shared.load(url, size: size) { [weak self] _ in self?.needsDisplay = true }
            }
            x = box.maxX + 4
        }
    }

    private func drawLookup(_ p: CellPresentation, in rect: NSRect) {
        guard case .list(let items) = p.value else { return }
        if let target = p.lookupTarget {
            switch target.type {
            case .singleSelect, .multipleSelects:
                let chips: [(String, NSColor, NSColor)] = items.compactMap {
                    if case .choice(let c) = $0 { return (c.name, Theme.chipBackground(c.color), Theme.chipText(c.color)) }
                    return nil
                }
                drawChips(chips, in: rect, capsule: true)
                return
            case .attachment:
                let atts = items.flatMap { v -> [AttachmentInfo] in if case .attachments(let a) = v { return a } else { return [] } }
                drawAttachments(atts, p, in: rect)
                return
            case .collaborator, .createdBy, .lastModifiedBy:
                drawPeople(items.flatMap { v -> [Person] in if case .collaborators(let people) = v { return people } else { return [] } }, in: rect)
                return
            default:
                break
            }
        }
        let texts = items.map { CellFormatter.string($0, field: p.lookupTarget) }.filter { !$0.isEmpty }
        drawChips(texts.map { ($0, Theme.lookupChipBackground, NSColor.labelColor) }, in: rect, capsule: false)
    }

    private func drawButton(_ label: String, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.controlAccentColor]
        let str = NSAttributedString(string: label, attributes: attrs)
        let w = min(ceil(str.size().width) + 20, rect.width)
        let box = NSRect(x: rect.minX, y: rect.midY - 11, width: w, height: 22)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        str.draw(with: NSRect(x: box.minX + 10, y: box.minY + 4, width: box.width - 20, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawSymbol(_ name: String, color: NSColor, in rect: NSRect, size: CGFloat, centered: Bool) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color])))
        else { return }
        let s = image.size
        let origin = centered
            ? NSPoint(x: rect.midX - s.width / 2, y: (multiline ? rect.minY + 8 : rect.midY - s.height / 2))
            : NSPoint(x: rect.minX, y: rect.minY)
        image.draw(in: NSRect(origin: origin, size: s), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Where a click toggles a checkbox or sets a rating, in cell coordinates.
    func ratingValue(at point: NSPoint) -> Int? {
        guard let p = presentation, p.field.type == .rating else { return nil }
        let size: CGFloat = 13
        let x = point.x - Self.padding
        guard x >= 0 else { return nil }
        let index = Int(x / (size + 3)) + 1
        return index <= (p.field.options.ratingMax ?? 5) ? index : nil
    }
}

/// Row-number cell (with an expand button on hover).
final class RowNumberCellView: NSView {
    var number = 0 { didSet { needsDisplay = true } }
    var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    var rowSelected = false { didSet { if oldValue != rowSelected { needsDisplay = true } } }
    var commentCount = 0
    /// The record's colour (from the view's colour field), drawn as a bar on the leading edge.
    var accent: NSColor? { didSet { if oldValue != accent { needsDisplay = true } } }
    /// Shows a grip instead of the number on hover when rows can be dragged to reorder.
    var draggable = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if rowSelected {
            Theme.selectionFill.setFill()
            bounds.fill()
        }
        if let accent {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 4, height: max(0, bounds.height - 7)), xRadius: 2, yRadius: 2).fill()
        }
        if hovering && draggable,
           let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.tertiaryLabelColor]))) {
            let s = grip.size
            grip.draw(in: NSRect(x: 11, y: min(bounds.midY - s.height / 2, 16 - s.height / 2), width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let str = NSAttributedString(string: "\(number)", attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: 10, y: min(bounds.midY - size.height / 2, 9)))
        }
        if hovering || rowSelected {
            if let img = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand record")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.controlAccentColor]))) {
                img.draw(in: expandRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else if commentCount > 0 {
            if let img = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comments")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [.tertiaryLabelColor]))) {
                img.draw(in: expandRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    var expandRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: min(bounds.midY - 7, 9), width: 14, height: 14)
    }
}

/// Group header row.
final class GroupHeaderView: NSView {
    var header: GroupHeader?
    var fieldValue: CellValue = .empty
    var collapsed = false
    var fieldName = ""
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.groupBackground.setFill()
        bounds.fill()
        guard let header else { return }
        let indent = CGFloat(header.depth) * 16 + 10
        if let chevron = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            chevron.draw(in: NSRect(x: indent, y: bounds.midY - 6, width: 10, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var x = indent + 20
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let label = NSAttributedString(string: fieldName.uppercased(), attributes: small)
        label.draw(at: NSPoint(x: x, y: bounds.midY - 13))
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        if case .choice(let c) = fieldValue {
            let str = NSAttributedString(string: c.name, attributes: [.font: GridCellView.chipFont, .foregroundColor: Theme.chipText(c.color)])
            let w = str.size().width + 16
            let chip = NSRect(x: x, y: bounds.midY - 1, width: w, height: 19)
            Theme.chipBackground(c.color).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 9.5, yRadius: 9.5).fill()
            str.draw(at: NSPoint(x: chip.minX + 8, y: chip.minY + 2))
            x = chip.maxX + 10
        } else {
            let t = NSAttributedString(string: header.title, attributes: titleAttrs)
            t.draw(at: NSPoint(x: x, y: bounds.midY))
            x += t.size().width + 10
        }
        let count = NSAttributedString(string: "\(header.count) record\(header.count == 1 ? "" : "s")", attributes: small)
        count.draw(at: NSPoint(x: x, y: bounds.midY + 3))
    }
}
