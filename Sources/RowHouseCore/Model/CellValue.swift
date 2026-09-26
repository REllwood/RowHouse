import Foundation
import RowHouseFormula

public struct LinkedRecordRef: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
}

/// A fully-resolved cell value: stored JSON interpreted through its field type, or a computed result.
/// This is what the UI renders and what filters, sorts, groups and formulas operate on.
public indirect enum CellValue: Hashable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(Date, includesTime: Bool)
    case choice(SelectChoice)
    case choices([SelectChoice])
    case attachments([AttachmentInfo])
    case links([LinkedRecordRef])
    case list([CellValue])
    case error(String)

    public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .text(let s): return s.isEmpty
        case .bool(let b): return !b
        case .choices(let c): return c.isEmpty
        case .attachments(let a): return a.isEmpty
        case .links(let l): return l.isEmpty
        case .list(let items): return items.allSatisfy(\.isEmpty)
        default: return false
        }
    }

    public var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .text(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .list(let items) where items.count == 1: return items[0].numberValue
        default: return nil
        }
    }

    public var dateValue: Date? {
        switch self {
        case .date(let d, _): return d
        case .list(let items) where items.count == 1: return items[0].dateValue
        default: return nil
        }
    }

    public var flattened: [CellValue] {
        switch self {
        case .list(let items): return items.flatMap(\.flattened)
        case .choices(let c): return c.map { .choice($0) }
        case .empty: return []
        default: return [self]
        }
    }

    public var formulaValue: FormulaValue {
        switch self {
        case .empty: return .blank
        case .text(let s): return .text(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .date(let d, _): return .date(d)
        case .choice(let c): return .text(c.name)
        case .choices(let c): return .array(c.map { .text($0.name) })
        case .attachments(let a): return .array(a.map { .text($0.filename) })
        case .links(let l): return .array(l.map { .text($0.title) })
        case .list(let items): return .array(items.map(\.formulaValue))
        case .error(let m): return .error(FormulaError(m))
        }
    }

    public init(formula value: FormulaValue, includesTime: Bool = true) {
        switch value {
        case .blank: self = .empty
        case .number(let n): self = .number(n)
        case .text(let s): self = .text(s)
        case .bool(let b): self = .bool(b)
        case .date(let d): self = .date(d, includesTime: includesTime)
        case .array(let items): self = .list(items.map { CellValue(formula: $0, includesTime: includesTime) })
        case .error(let e): self = .error(e.message)
        }
    }
}
