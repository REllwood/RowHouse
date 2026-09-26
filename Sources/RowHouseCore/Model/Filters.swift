import Foundation

public enum FilterConjunction: String, Codable, CaseIterable, Sendable {
    case and, or

    public var displayName: String { self == .and ? "and" : "or" }
}

public enum FilterOperator: String, Codable, CaseIterable, Sendable {
    case contains, doesNotContain
    case `is`, isNot
    case isEmpty, isNotEmpty
    case startsWith, endsWith
    case lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
    case isBefore, isAfter, isOnOrBefore, isOnOrAfter, isWithin
    case isAnyOf, isNoneOf
    case hasAnyOf, hasAllOf, hasNoneOf, isExactly

    public var displayName: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .is: "is"
        case .isNot: "is not"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .lessThan: "<"
        case .lessThanOrEqual: "≤"
        case .greaterThan: ">"
        case .greaterThanOrEqual: "≥"
        case .isBefore: "is before"
        case .isAfter: "is after"
        case .isOnOrBefore: "is on or before"
        case .isOnOrAfter: "is on or after"
        case .isWithin: "is within"
        case .isAnyOf: "is any of"
        case .isNoneOf: "is none of"
        case .hasAnyOf: "has any of"
        case .hasAllOf: "has all of"
        case .hasNoneOf: "has none of"
        case .isExactly: "is exactly"
        }
    }

    public var needsValue: Bool {
        self != .isEmpty && self != .isNotEmpty
    }

    public static func available(for type: FieldType) -> [FilterOperator] {
        switch type {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber, .formula, .lookup, .rollup, .autoNumber:
            if type == .autoNumber {
                return [.is, .isNot, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual]
            }
            return [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
                + (type == .formula || type == .rollup ? [.lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual] : [])
        case .number, .currency, .percent, .duration, .rating, .count:
            return [.is, .isNot, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .isEmpty, .isNotEmpty]
        case .checkbox:
            return [.is]
        case .singleSelect:
            return [.is, .isNot, .isAnyOf, .isNoneOf, .isEmpty, .isNotEmpty]
        case .multipleSelects:
            return [.hasAnyOf, .hasAllOf, .hasNoneOf, .isExactly, .isEmpty, .isNotEmpty]
        case .date, .createdTime, .lastModifiedTime:
            return [.is, .isNot, .isBefore, .isAfter, .isOnOrBefore, .isOnOrAfter, .isWithin, .isEmpty, .isNotEmpty]
        case .attachment:
            return [.contains, .isEmpty, .isNotEmpty]
        case .link:
            return [.contains, .doesNotContain, .isEmpty, .isNotEmpty]
        case .button:
            return []
        case .collaborator:
            return [.is, .isNot, .isAnyOf, .isNoneOf, .hasAnyOf, .hasAllOf, .hasNoneOf, .isExactly, .isEmpty, .isNotEmpty]
        case .createdBy, .lastModifiedBy, .barcode, .aiText:
            return [.contains, .doesNotContain, .is, .isNot, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
        }
    }

    /// Operators for a particular field. Collaborator fields offer single- or multiple-person
    /// comparisons depending on whether they allow several people.
    public static func available(for field: FieldModel) -> [FilterOperator] {
        guard field.type == .collaborator else { return available(for: field.type) }
        if field.options.allowMultipleCollaborators == true {
            return [.hasAnyOf, .hasAllOf, .hasNoneOf, .isExactly, .isEmpty, .isNotEmpty]
        }
        return [.is, .isNot, .isAnyOf, .isNoneOf, .isEmpty, .isNotEmpty]
    }
}

/// Relative date values used by date filters ("today", "one week ago", an exact date…).
public enum RelativeDateMode: String, Codable, CaseIterable, Sendable {
    case today, tomorrow, yesterday, oneWeekAgo, oneWeekFromNow, oneMonthAgo, oneMonthFromNow
    case daysAgo, daysFromNow, exactDate

    public var displayName: String {
        switch self {
        case .today: "today"
        case .tomorrow: "tomorrow"
        case .yesterday: "yesterday"
        case .oneWeekAgo: "one week ago"
        case .oneWeekFromNow: "one week from now"
        case .oneMonthAgo: "one month ago"
        case .oneMonthFromNow: "one month from now"
        case .daysAgo: "number of days ago"
        case .daysFromNow: "number of days from now"
        case .exactDate: "exact date"
        }
    }
}

public enum WithinMode: String, Codable, CaseIterable, Sendable {
    case pastWeek, pastMonth, pastYear, nextWeek, nextMonth, nextYear, pastNumberOfDays, nextNumberOfDays

    public var displayName: String {
        switch self {
        case .pastWeek: "the past week"
        case .pastMonth: "the past month"
        case .pastYear: "the past year"
        case .nextWeek: "the next week"
        case .nextMonth: "the next month"
        case .nextYear: "the next year"
        case .pastNumberOfDays: "the past number of days"
        case .nextNumberOfDays: "the next number of days"
        }
    }
}

public struct FilterCondition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fieldID: String
    public var op: FilterOperator
    /// Text/number for scalar comparisons, choice ids (array) for selects, person ids (array) for
    /// collaborators, bool for checkboxes, and `{"mode": RelativeDateMode, "date": "YYYY-MM-DD", "days": n}` for dates.
    public var value: JSONValue?

    public init(id: String = RowID.condition(), fieldID: String, op: FilterOperator, value: JSONValue? = nil) {
        self.id = id
        self.fieldID = fieldID
        self.op = op
        self.value = value
    }
}

public struct FilterGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var conjunction: FilterConjunction
    public var conditions: [FilterCondition]
    public var groups: [FilterGroup]

    public init(id: String = RowID.condition(), conjunction: FilterConjunction = .and, conditions: [FilterCondition] = [], groups: [FilterGroup] = []) {
        self.id = id
        self.conjunction = conjunction
        self.conditions = conditions
        self.groups = groups
    }

    public var isEmpty: Bool { conditions.isEmpty && groups.allSatisfy(\.isEmpty) }

    public var conditionCount: Int {
        conditions.count + groups.reduce(0) { $0 + $1.conditionCount }
    }
}
