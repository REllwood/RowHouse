import AppKit
import RowHouseCore
import SwiftUI

/// A coloured circle with a person's initials.
struct PersonAvatar: View {
    var person: Person
    var size: CGFloat = 18

    var body: some View {
        Circle()
            .fill(person.color.swiftUI)
            .frame(width: size, height: size)
            .overlay(
                Text(person.initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            )
            .accessibilityHidden(true)
    }
}

/// Avatar plus name, used wherever collaborators (or the Mac that made a change) are shown.
struct PersonChip: View {
    var person: Person
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            PersonAvatar(person: person, size: compact ? 14 : 18)
            Text(person.displayName)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 2)
        .padding(.trailing, compact ? 6 : 8)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color(nsColor: Theme.lookupChipBackground)))
        .help(person.email.isEmpty ? person.displayName : "\(person.displayName) — \(person.email)")
    }
}

/// Draws person chips in AppKit (the grid draws its cells by hand).
enum PersonChipDrawing {
    static let height: CGFloat = 20
    private static let initialsFont = NSFont.systemFont(ofSize: 8, weight: .semibold)

    static func width(of person: Person, font: NSFont) -> CGFloat {
        let name = NSAttributedString(string: person.displayName, attributes: [.font: font])
        return height + 4 + ceil(name.size().width) + 8
    }

    static func draw(_ person: Person, in chip: NSRect, font: NSFont) {
        Theme.lookupChipBackground.setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        let circle = NSRect(x: chip.minX + 2, y: chip.minY + 2, width: chip.height - 4, height: chip.height - 4)
        Theme.solid(person.color).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let initials = NSAttributedString(string: person.initials, attributes: [.font: initialsFont, .foregroundColor: NSColor.white])
        let size = initials.size()
        initials.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: person.displayName, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        let textX = circle.maxX + 4
        name.draw(with: NSRect(x: textX, y: chip.minY + 3, width: max(0, chip.maxX - textX - 6), height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
