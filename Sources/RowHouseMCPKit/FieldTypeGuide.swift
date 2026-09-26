import Foundation
import RowHouseCore

/// How each field type's values look in tool results and what writes accept. Built from
/// `FieldType.allCases`, so a type added later is listed (with a generic description) automatically.
@MainActor
enum FieldTypeGuide {
    static func all() -> JSONValue {
        .object([
            "fieldTypes": .array(FieldType.allCases.map(entry)),
            "notes": .array([
                "Record fields are keyed by field name (or id). Empty values are left out of records unless noted.",
                "Pass null to clear a field.",
                "Computed fields are read-only; writing one is an error.",
                "Options are set with create_field / update_field using the keys listed under options.",
                "Colors for select options: \(ChoiceColor.allCases.map(\.rawValue).joined(separator: ", ")).",
            ].map(JSONValue.string)),
        ])
    }

    private static func entry(_ type: FieldType) -> JSONValue {
        let (read, write) = formats(type)
        var out: [String: JSONValue] = [
            "type": .string(type.rawValue),
            "displayName": .string(type.displayName),
            "category": .string(type.category.rawValue),
            "readOnly": .bool(!writable(type)),
            "canBePrimary": .bool(type.canBePrimary),
            "read": .string(read),
            "write": .string(write),
        ]
        let keys = FieldOptionsCoding.keys(for: type)
        if !keys.isEmpty { out["options"] = .string(optionHelp(type, keys: keys)) }
        return .object(out)
    }

    private static func writable(_ type: FieldType) -> Bool {
        !type.isComputed && type != .attachment
    }

    private static func formats(_ type: FieldType) -> (read: String, write: String) {
        formatsByType[type] ?? generic(type)
    }

    private static let formatsByType: [FieldType: (read: String, write: String)] = [
        .singleLineText: ("string", "string (line breaks become spaces)"),
        .multilineText: ("string (may contain line breaks)", "string"),
        .email: ("string", "string, e.g. \"ada@example.com\""),
        .url: ("string", "string, e.g. \"https://example.com\""),
        .phoneNumber: ("string", "string"),
        .number: ("number", "number, or text such as \"1,234.5\""),
        .currency: ("number (the amount, without symbol)", "number, or text such as \"$1,200\""),
        .percent: ("number as a fraction: 0.25 means 25%", "number as a fraction (0.25), or text such as \"25%\""),
        .duration: ("number of seconds", "number of seconds, or text such as \"1:30\" (h:mm) or \"45m\""),
        .rating: ("whole number from 1 to the field's max; unrated is empty", "whole number (0 or null clears it)"),
        .checkbox: ("true when checked; unchecked is left out (false with get_record)", "true or false"),
        .singleSelect: ("option name, e.g. \"Done\"", "option name (or id). Unknown names are an error unless typecast is true, which adds the option"),
        .multipleSelects: ("array of option names", "array of option names (or ids), or one comma-separated string. typecast adds unknown options"),
        .date: ("\"YYYY-MM-DD\", or an ISO-8601 date-time (UTC) when the field includes a time", "\"YYYY-MM-DD\", an ISO-8601 date-time, or text such as \"tomorrow\""),
        .attachment: ("array of {id, filename, size, type, url (file:// URL of the file inside the base), width, height}", "read-only here; add files in RowHouse"),
        .link: ("array of {id, name} for the linked records", "array of record ids or primary field values of existing records in the linked table (never creates records)"),
        .lookup: ("array of the looked-up values from linked records, in the target field's format", "read-only (computed)"),
        .rollup: ("the aggregated result: number, string, boolean or date", "read-only (computed)"),
        .count: ("number of linked records", "read-only (computed)"),
        .formula: ("the result: number, string, boolean, date string, or {error} when it fails", "read-only (computed)"),
        .createdTime: ("ISO-8601 date-time (or YYYY-MM-DD when include_time is false)", "read-only (computed)"),
        .lastModifiedTime: ("ISO-8601 date-time (or YYYY-MM-DD when include_time is false)", "read-only (computed)"),
        .autoNumber: ("number, unique and increasing in creation order", "read-only (computed)"),
        .button: ("{label, url} (url is present when the URL formula produces a web link)", "read-only (computed)"),
    ]

    private static func generic(_ type: FieldType) -> (String, String) {
        if type.isComputed { return ("computed value", "read-only (computed)") }
        if type.isNumeric { return ("number", "number, or text as typed in RowHouse") }
        if type.isDateLike { return ("date string", "\"YYYY-MM-DD\" or ISO-8601 date-time") }
        return ("string", "text, read the same way as text typed into the cell in RowHouse")
    }

    private static func optionHelp(_ type: FieldType, keys: [String]) -> String {
        let help: [String: String] = [
            "precision": "precision: decimal places, 0–8",
            "currency_symbol": "currency_symbol: e.g. \"$\" or \"€\"",
            "duration_format": "duration_format: \"h:mm\" or \"h:mm:ss\"",
            "max": "max: highest rating, 1–10 (default 5)",
            "choices": "choices: [\"A\", \"B\"] or [{name, color}]; listing choices replaces them all (existing options keep their ids when listed by name)",
            "include_time": "include_time: true to store a time as well as a date",
            "date_format": "date_format: \(DateDisplayFormat.allCases.map(\.rawValue).joined(separator: ", "))",
            "use_24_hour_clock": "use_24_hour_clock: true or false",
            "watched_fields": "watched_fields: names of the fields whose edits count (default: any field)",
            "linked_table": "linked_table: name or id of the table to link to (required); a paired field is added to that table automatically",
            "single_record": "single_record: true to allow only one linked record",
            "link_field": "link_field: a link field in this table (required)",
            "target_field": type == .rollup ? "target_field: the field in the linked table to aggregate (required)" : "target_field: the field in the linked table to show (required)",
            "formula": type == .rollup ? "formula: aggregation over values, e.g. \"SUM(values)\" (default), \"MAX(values)\", \"ARRAYJOIN(values)\"" : "formula: Airtable formula referring to fields as {Field Name} (required)",
            "result_format": "result_format: \(FormulaResultFormat.allCases.map(\.rawValue).joined(separator: ", "))",
            "label": "label: button text",
            "action": "action: open_url or run_automation",
            "url_formula": "url_formula: formula producing the URL to open, e.g. \"https://example.com/\" & {Name}",
            "automation": "automation: name of the automation to run (sets action to run_automation)",
        ]
        return keys.map { help[$0] ?? $0 }.joined(separator: "; ")
    }
}
