import AppKit
import RowHouseCore
import SwiftUI

enum Theme {
    static let accent = Color(nsColor: .controlAccentColor)

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// Pastel chip backgrounds (light) and translucent saturated ones (dark), like Airtable's option colours.
    static func chipBackground(_ color: ChoiceColor) -> NSColor {
        switch color {
        case .blue: dynamic(light: hex(0xCFDFFF), dark: hex(0x2D7FF9, alpha: 0.42))
        case .cyan: dynamic(light: hex(0xD0F0FD), dark: hex(0x18BFFF, alpha: 0.38))
        case .teal: dynamic(light: hex(0xC2F5E9), dark: hex(0x20D9D2, alpha: 0.34))
        case .green: dynamic(light: hex(0xD1F7C4), dark: hex(0x20C933, alpha: 0.36))
        case .yellow: dynamic(light: hex(0xFFEAB6), dark: hex(0xFCB400, alpha: 0.38))
        case .orange: dynamic(light: hex(0xFEE2D5), dark: hex(0xFF6F2C, alpha: 0.40))
        case .red: dynamic(light: hex(0xFFDCE5), dark: hex(0xF82B60, alpha: 0.40))
        case .pink: dynamic(light: hex(0xFFDAF6), dark: hex(0xFF08C2, alpha: 0.34))
        case .purple: dynamic(light: hex(0xEDE2FE), dark: hex(0x8B46FF, alpha: 0.45))
        case .gray: dynamic(light: hex(0xEEEEEE), dark: hex(0x8E8E93, alpha: 0.35))
        }
    }

    static func chipText(_ color: ChoiceColor) -> NSColor {
        switch color {
        case .blue: dynamic(light: hex(0x102046), dark: hex(0xE6EEFF))
        case .cyan: dynamic(light: hex(0x04283F), dark: hex(0xE0F7FF))
        case .teal: dynamic(light: hex(0x012524), dark: hex(0xDDFBF4))
        case .green: dynamic(light: hex(0x0B1D05), dark: hex(0xE4FBDB))
        case .yellow: dynamic(light: hex(0x3B2501), dark: hex(0xFFF3D1))
        case .orange: dynamic(light: hex(0x6B2613), dark: hex(0xFFE8DE))
        case .red: dynamic(light: hex(0x4C0C1C), dark: hex(0xFFE4EB))
        case .pink: dynamic(light: hex(0x400832), dark: hex(0xFFE3F8))
        case .purple: dynamic(light: hex(0x280B42), dark: hex(0xF1E8FF))
        case .gray: dynamic(light: hex(0x2B2B2B), dark: hex(0xF2F2F2))
        }
    }

    /// Solid swatch colour (calendar bars, chart segments, base icons).
    static func solid(_ color: ChoiceColor) -> NSColor {
        switch color {
        case .blue: hex(0x2D7FF9)
        case .cyan: hex(0x18BFFF)
        case .teal: hex(0x20C9C2)
        case .green: hex(0x20C933)
        case .yellow: hex(0xFCB400)
        case .orange: hex(0xFF6F2C)
        case .red: hex(0xF82B60)
        case .pink: hex(0xFF08C2)
        case .purple: hex(0x8B46FF)
        case .gray: hex(0x8E8E93)
        }
    }

    static let linkChipBackground = dynamic(light: hex(0xE1ECFF), dark: hex(0x2D7FF9, alpha: 0.30))
    static let linkChipText = dynamic(light: hex(0x0F3D8C), dark: hex(0xDCE8FF))
    static let lookupChipBackground = dynamic(light: hex(0xEEF0F3), dark: hex(0xFFFFFF, alpha: 0.10))
    static let gridBackground = NSColor.controlBackgroundColor
    static let gridLine = dynamic(light: hex(0xE3E5E8), dark: hex(0xFFFFFF, alpha: 0.09))
    static let headerBackground = dynamic(light: hex(0xF5F6F8), dark: hex(0x2A2A2D))
    static let rowHover = dynamic(light: hex(0xF7F8FA), dark: hex(0xFFFFFF, alpha: 0.04))
    static let groupBackground = dynamic(light: hex(0xF1F3F6), dark: hex(0x323236))
    static let selectionFill = dynamic(light: hex(0x2D7FF9, alpha: 0.10), dark: hex(0x2D7FF9, alpha: 0.22))
    static let star = hex(0xFCB400)
}

extension ChoiceColor {
    var swiftUI: Color { Color(nsColor: Theme.solid(self)) }
    var chipBackground: Color { Color(nsColor: Theme.chipBackground(self)) }
    var chipText: Color { Color(nsColor: Theme.chipText(self)) }

    var displayName: String { rawValue.capitalized }
}

/// A rounded option chip, used anywhere select values are shown.
struct ChoiceChip: View {
    var name: String
    var color: ChoiceColor
    var compact = false

    var body: some View {
        Text(name.isEmpty ? " " : name)
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1 : 2)
            .foregroundStyle(color.chipText)
            .background(Capsule().fill(color.chipBackground))
    }
}

struct LinkChip: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Color(nsColor: Theme.linkChipText))
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: Theme.linkChipBackground)))
    }
}

/// Field-type icon + name, used in headers, forms and pickers.
struct FieldLabel: View {
    var field: FieldModel

    var body: some View {
        Label {
            Text(field.name)
        } icon: {
            Image(systemName: field.type.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Card chrome shared by kanban, gallery and calendar items.
    func cardStyle(selected: Bool = false) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
