import Foundation

public struct BaseInfo: Equatable, Sendable {
    public var name: String = "Untitled Base"
    public var icon: String = "square.grid.3x3.fill"
    public var color: ChoiceColor = .blue
    public var description: String = ""
    /// The device that runs scheduled automations for this base.
    public var automationHostDeviceID: String?
    /// People who can be chosen in collaborator fields.
    public var people: [Person] = []

    public init() {}
}

public struct TableModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var order: Double
    public var primaryFieldID: String?
    public var description: String
    public var icon: String?
    public var recordTemplates: [RecordTemplate] = []
}

/// Preset values for new records ("record templates").
public struct RecordTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Field id → stored value.
    public var values: [String: JSONValue]

    public init(id: String = RowID.make("rtp"), name: String, values: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.values = values
    }
}

public struct FieldModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var tableID: String
    public var name: String
    public var type: FieldType
    public var options: FieldOptions
    public var order: Double
    public var description: String

    public init(id: String, tableID: String, name: String, type: FieldType, options: FieldOptions = FieldOptions(), order: Double = 0, description: String = "") {
        self.id = id
        self.tableID = tableID
        self.name = name
        self.type = type
        self.options = options
        self.order = order
        self.description = description
    }

    public var choices: [SelectChoice] { options.choices ?? [] }

    public func choice(id: String) -> SelectChoice? {
        options.choices?.first { $0.id == id }
    }

    public func choice(named name: String) -> SelectChoice? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.choices?.first { $0.name == needle }
            ?? options.choices?.first { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
    }

    public var includesTime: Bool { options.includeTime ?? false }
    public var isInverseLink: Bool { type == .link && (options.isInverseLink ?? false) }
    public var isEditable: Bool { !type.isComputed }
}

public struct RecordModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var tableID: String
    public var order: Double
    public var createdTime: Date
    public var createdStamp: HLC
    /// Stored cell values keyed by field id (computed fields are not stored).
    public var cells: [String: JSONValue]
    /// Timestamp of the latest edit to each cell.
    public var cellStamps: [String: HLC]

    public subscript(fieldID: String) -> JSONValue {
        cells[fieldID] ?? .null
    }

    public var lastModifiedStamp: HLC {
        cellStamps.values.max() ?? createdStamp
    }

    public var lastModifiedTime: Date { lastModifiedStamp.date }
}

public struct CommentModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var recordID: String
    public var text: String
    public var authorDeviceID: String
    public var authorName: String
    public var createdTime: Date
    /// People @mentioned in the text (person ids).
    public var mentions: [String] = []
}

public struct DeviceInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lastSeen: Date
}

public struct AttachmentInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var filename: String
    /// SHA-256 of the file contents; the file lives at attachments/<hash>.<ext> inside the base package.
    public var hash: String
    public var size: Int
    public var mimeType: String
    public var width: Int?
    public var height: Int?

    public init(id: String = RowID.attachment(), filename: String, hash: String, size: Int, mimeType: String, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.filename = filename
        self.hash = hash
        self.size = size
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }

    public var fileExtension: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "bin" : ext
    }

    public var storedFileName: String { "\(hash).\(fileExtension)" }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

// MARK: - Views

public enum ViewType: String, Codable, CaseIterable, Sendable, Identifiable {
    case grid, kanban, calendar, gallery, timeline, form, chart

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .grid: "Grid"
        case .kanban: "Kanban"
        case .calendar: "Calendar"
        case .gallery: "Gallery"
        case .timeline: "Timeline"
        case .form: "Form"
        case .chart: "Chart"
        }
    }

    public var symbolName: String {
        switch self {
        case .grid: "tablecells"
        case .kanban: "rectangle.split.3x1"
        case .calendar: "calendar"
        case .gallery: "square.grid.2x2"
        case .timeline: "chart.bar.xaxis"
        case .form: "list.bullet.rectangle"
        case .chart: "chart.pie"
        }
    }
}

public enum RowHeight: String, Codable, CaseIterable, Sendable {
    case short, medium, tall, extraTall

    public var points: Double {
        switch self {
        case .short: 32
        case .medium: 56
        case .tall: 88
        case .extraTall: 128
        }
    }

    public var displayName: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .tall: "Tall"
        case .extraTall: "Extra tall"
        }
    }
}

public struct SortSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fieldID: String
    public var ascending: Bool

    public init(id: String = RowID.condition(), fieldID: String, ascending: Bool = true) {
        self.id = id
        self.fieldID = fieldID
        self.ascending = ascending
    }
}

public enum SummaryFunction: String, Codable, CaseIterable, Sendable {
    case none, filled, empty, percentFilled, percentEmpty, unique, sum, average, median, min, max, range, checked, unchecked, earliest, latest

    public var displayName: String {
        switch self {
        case .none: "None"
        case .filled: "Filled"
        case .empty: "Empty"
        case .percentFilled: "Percent filled"
        case .percentEmpty: "Percent empty"
        case .unique: "Unique"
        case .sum: "Sum"
        case .average: "Average"
        case .median: "Median"
        case .min: "Min"
        case .max: "Max"
        case .range: "Range"
        case .checked: "Checked"
        case .unchecked: "Unchecked"
        case .earliest: "Earliest"
        case .latest: "Latest"
        }
    }

    public static func available(for type: FieldType) -> [SummaryFunction] {
        var base: [SummaryFunction] = [.none, .filled, .empty, .percentFilled, .percentEmpty]
        if type.isNumeric || type == .formula || type == .rollup {
            base += [.sum, .average, .median, .min, .max, .range]
        }
        if type == .checkbox { base = [.none, .checked, .unchecked, .percentFilled, .percentEmpty] }
        if type.isDateLike { base += [.earliest, .latest, .range] }
        if type.isTextual || type.isPeople || type == .singleSelect || type == .barcode { base.append(.unique) }
        return base
    }
}

public struct FormConfig: Codable, Hashable, Sendable {
    public var title: String?
    public var description: String?
    public var fieldIDs: [String]?
    public var requiredFieldIDs: [String]?
    public var submitLabel: String?
    public var successMessage: String?
    /// Field id → conditions on earlier answers that must hold for the field to be shown.
    public var fieldConditions: [String: FilterGroup]?

    public init() {}
}

public enum ChartKind: String, Codable, CaseIterable, Sendable {
    case bar, line, pie, donut

    public var displayName: String { rawValue.capitalized }
}

public enum ChartAggregate: String, Codable, CaseIterable, Sendable {
    case count, sum, average, min, max

    public var displayName: String {
        switch self {
        case .count: "Count records"
        case .sum: "Sum"
        case .average: "Average"
        case .min: "Minimum"
        case .max: "Maximum"
        }
    }
}

public struct ChartConfig: Codable, Hashable, Sendable {
    public var kind: ChartKind?
    public var categoryFieldID: String?
    public var aggregate: ChartAggregate?
    public var valueFieldID: String?
    public var sortByValue: Bool?

    public init() {}
}

public enum TimelineScale: String, Codable, CaseIterable, Sendable {
    case week, month, quarter

    public var displayName: String { rawValue.capitalized }
}

public struct ViewConfig: Codable, Hashable, Sendable {
    public var filter: FilterGroup?
    public var sorts: [SortSpec]?
    public var groups: [SortSpec]?
    public var hiddenFieldIDs: [String]?
    public var fieldOrder: [String]?
    public var columnWidths: [String: Double]?
    public var rowHeight: RowHeight?
    public var summaries: [String: SummaryFunction]?
    /// Kanban stack field (single select).
    public var stackFieldID: String?
    /// Kanban/gallery cover image field (attachment).
    public var coverFieldID: String?
    /// Calendar/timeline start and end date fields.
    public var dateFieldID: String?
    public var endDateFieldID: String?
    public var timelineScale: TimelineScale?
    /// Colors records by the value of a single-select field.
    public var colorFieldID: String?
    /// Colors records by conditions instead (first matching rule wins); takes precedence over `colorFieldID`.
    public var colorRules: [ColorRule]?
    public var form: FormConfig?
    public var chart: ChartConfig?
    /// A locked view's filters, sorts, grouping, fields and layout can't be changed (records can).
    public var locked: Bool?

    public init() {}

    public var hidden: Set<String> { Set(hiddenFieldIDs ?? []) }
    public var isLocked: Bool { locked == true }
}

/// "Colour records using conditions": records matching `filter` get `color`.
public struct ColorRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var filter: FilterGroup
    public var color: ChoiceColor

    public init(id: String = RowID.make("clr"), filter: FilterGroup = FilterGroup(), color: ChoiceColor) {
        self.id = id
        self.filter = filter
        self.color = color
    }
}

public struct ViewModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var tableID: String
    public var name: String
    public var type: ViewType
    public var config: ViewConfig
    public var order: Double
}
