import Foundation

public enum FieldType: String, Codable, CaseIterable, Sendable, Identifiable {
    case singleLineText
    case multilineText
    case email
    case url
    case phoneNumber
    case number
    case currency
    case percent
    case duration
    case rating
    case checkbox
    case singleSelect
    case multipleSelects
    case date
    case attachment
    case link
    case lookup
    case rollup
    case count
    case formula
    case createdTime
    case lastModifiedTime
    case autoNumber
    case button
    case collaborator
    case createdBy
    case lastModifiedBy
    case barcode
    case aiText

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .singleLineText: "Single line text"
        case .multilineText: "Long text"
        case .email: "Email"
        case .url: "URL"
        case .phoneNumber: "Phone number"
        case .number: "Number"
        case .currency: "Currency"
        case .percent: "Percent"
        case .duration: "Duration"
        case .rating: "Rating"
        case .checkbox: "Checkbox"
        case .singleSelect: "Single select"
        case .multipleSelects: "Multiple select"
        case .date: "Date"
        case .attachment: "Attachment"
        case .link: "Link to another record"
        case .lookup: "Lookup"
        case .rollup: "Rollup"
        case .count: "Count"
        case .formula: "Formula"
        case .createdTime: "Created time"
        case .lastModifiedTime: "Last modified time"
        case .autoNumber: "Autonumber"
        case .button: "Button"
        case .collaborator: "Collaborator"
        case .createdBy: "Created by"
        case .lastModifiedBy: "Last modified by"
        case .barcode: "Barcode"
        case .aiText: "AI text"
        }
    }

    /// SF Symbol shown next to the field name.
    public var symbolName: String {
        switch self {
        case .singleLineText: "textformat"
        case .multilineText: "text.alignleft"
        case .email: "envelope"
        case .url: "link"
        case .phoneNumber: "phone"
        case .number: "number"
        case .currency: "dollarsign.circle"
        case .percent: "percent"
        case .duration: "timer"
        case .rating: "star"
        case .checkbox: "checkmark.square"
        case .singleSelect: "chevron.down.circle"
        case .multipleSelects: "list.bullet.circle"
        case .date: "calendar"
        case .attachment: "paperclip"
        case .link: "arrow.up.right.square"
        case .lookup: "magnifyingglass"
        case .rollup: "sum"
        case .count: "number.square"
        case .formula: "function"
        case .createdTime: "clock.badge.checkmark"
        case .lastModifiedTime: "clock.arrow.circlepath"
        case .autoNumber: "textformat.123"
        case .button: "cursorarrow.click"
        case .collaborator: "person.crop.circle"
        case .createdBy: "person.crop.circle.badge.plus"
        case .lastModifiedBy: "person.crop.circle.badge.clock"
        case .barcode: "barcode"
        case .aiText: "sparkles"
        }
    }

    /// Values computed from other data; users cannot type into these cells.
    public var isComputed: Bool {
        switch self {
        case .lookup, .rollup, .count, .formula, .createdTime, .lastModifiedTime, .autoNumber, .button, .createdBy, .lastModifiedBy: true
        default: false
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .number, .currency, .percent, .duration, .rating, .count, .autoNumber: true
        default: false
        }
    }

    public var isTextual: Bool {
        switch self {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber, .aiText: true
        default: false
        }
    }

    public var isDateLike: Bool {
        switch self {
        case .date, .createdTime, .lastModifiedTime: true
        default: false
        }
    }

    /// Types that can be chosen as the primary (first) field of a table.
    public var canBePrimary: Bool {
        switch self {
        case .attachment, .checkbox, .link, .multipleSelects, .rating, .button, .lookup, .rollup, .count,
             .collaborator, .createdBy, .lastModifiedBy, .aiText: false
        default: true
        }
    }

    /// Types whose values show people (collaborators, or the Mac that made a change).
    public var isPeople: Bool {
        switch self {
        case .collaborator, .createdBy, .lastModifiedBy: true
        default: false
        }
    }

    /// Types that can have a default value applied to new records.
    public var supportsDefaultValue: Bool {
        switch self {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber, .number, .currency, .percent, .duration, .rating,
             .checkbox, .singleSelect, .multipleSelects, .date, .collaborator: true
        default: false
        }
    }

    public enum Category: String, CaseIterable, Sendable {
        case basic = "Basic"
        case choice = "Choice"
        case numeric = "Numbers"
        case dates = "Dates"
        case people = "People"
        case relational = "Relationships"
        case computed = "Computed"
    }

    public var category: Category {
        switch self {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber, .attachment, .barcode: .basic
        case .checkbox, .singleSelect, .multipleSelects, .rating: .choice
        case .number, .currency, .percent, .duration: .numeric
        case .date, .createdTime, .lastModifiedTime: .dates
        case .collaborator, .createdBy, .lastModifiedBy: .people
        case .link, .lookup, .rollup, .count: .relational
        case .formula, .autoNumber, .button, .aiText: .computed
        }
    }
}

public enum ChoiceColor: String, Codable, CaseIterable, Sendable {
    case blue, cyan, teal, green, yellow, orange, red, pink, purple, gray

    public static func cycling(_ index: Int) -> ChoiceColor {
        allCases[index % allCases.count]
    }
}

public struct SelectChoice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: ChoiceColor

    public init(id: String = RowID.choice(), name: String, color: ChoiceColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public enum DateDisplayFormat: String, Codable, CaseIterable, Sendable {
    case local       // system short style
    case friendly    // Sep 26, 2026
    case us          // 9/26/2026
    case european    // 26/9/2026
    case iso         // 2026-09-26
}

public enum DurationFormat: String, Codable, CaseIterable, Sendable {
    case hoursMinutes = "h:mm"
    case hoursMinutesSeconds = "h:mm:ss"
}

public enum FormulaResultFormat: String, Codable, CaseIterable, Sendable {
    case automatic, number, currency, percent, duration, date, dateTime
}

public enum ButtonAction: String, Codable, CaseIterable, Sendable {
    case openURL
    case runAutomation
}

/// Type-specific options. All members are optional so a single struct serves every field type and
/// changing a field's type never loses configuration the user might switch back to.
public struct FieldOptions: Codable, Hashable, Sendable {
    // Numbers
    public var precision: Int?
    public var currencySymbol: String?
    public var allowNegative: Bool?
    public var durationFormat: DurationFormat?
    public var ratingMax: Int?
    public var ratingSymbol: String?

    // Choices
    public var choices: [SelectChoice]?

    // Dates
    public var includeTime: Bool?
    public var dateFormat: DateDisplayFormat?
    public var use24HourClock: Bool?

    // Links
    public var linkedTableID: String?
    public var inverseFieldID: String?
    /// Inverse link fields hold no data; their value is derived from the owning field.
    public var isInverseLink: Bool?
    public var singleRecordLink: Bool?

    // Lookup / rollup / count
    public var linkFieldID: String?
    public var targetFieldID: String?
    /// Rollup aggregation formula over `values`, e.g. "SUM(values)".
    public var rollupFormula: String?

    // Formula
    public var formula: String?
    public var resultFormat: FormulaResultFormat?

    // Last modified time / last modified by
    public var watchedFieldIDs: [String]?

    // Conditional lookups, rollups and counts: only linked records matching this filter are used.
    public var linkFilter: FilterGroup?

    // Collaborator
    public var allowMultipleCollaborators: Bool?

    // Long text
    public var richText: Bool?

    // AI text: a prompt with `{fldID}` references, and an optional model id overriding the default.
    public var aiPrompt: String?
    public var aiModel: String?

    /// Stored value given to new records that don't provide one. Dates also accept `{"today": true}`.
    public var defaultValue: JSONValue?

    // Button
    public var buttonLabel: String?
    public var buttonAction: ButtonAction?
    public var buttonURLFormula: String?
    public var buttonAutomationID: String?

    // Checkbox
    public var checkboxSymbol: String?

    public init() {}
}
