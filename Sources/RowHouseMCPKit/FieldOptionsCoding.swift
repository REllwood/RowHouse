import Foundation
import RowHouseCore

/// Field options in the friendly form tools read and write: snake_case keys, and tables, fields and
/// automations named rather than referenced by internal id.
@MainActor
enum FieldOptionsCoding {
    // MARK: - Describing

    static func describe(_ field: FieldModel, in document: BaseDocument) -> [String: JSONValue] {
        let o = field.options
        var out: [String: JSONValue] = [:]
        func name(of fieldID: String?) -> JSONValue? { document.field(fieldID).map { .string($0.name) } }
        switch field.type {
        case .number, .percent:
            if let p = o.precision { out["precision"] = .number(Double(p)) }
        case .currency:
            if let p = o.precision { out["precision"] = .number(Double(p)) }
            if let s = o.currencySymbol { out["currency_symbol"] = .string(s) }
        case .duration:
            out["duration_format"] = .string((o.durationFormat ?? .hoursMinutes).rawValue)
        case .rating:
            out["max"] = .number(Double(o.ratingMax ?? 5))
        case .singleSelect, .multipleSelects:
            out["choices"] = .array(field.choices.map { .object(["id": .string($0.id), "name": .string($0.name), "color": .string($0.color.rawValue)]) })
        case .date, .createdTime, .lastModifiedTime:
            out["include_time"] = .bool(field.type == .date ? field.includesTime : (o.includeTime ?? true))
            if let f = o.dateFormat { out["date_format"] = .string(f.rawValue) }
            if let h = o.use24HourClock { out["use_24_hour_clock"] = .bool(h) }
            if field.type == .lastModifiedTime, let watched = o.watchedFieldIDs, !watched.isEmpty {
                out["watched_fields"] = .array(watched.compactMap { name(of: $0) })
            }
        case .link:
            if let table = document.table(o.linkedTableID) {
                out["linked_table"] = .string(table.name)
                out["linked_table_id"] = .string(table.id)
            }
            if o.singleRecordLink == true && !field.isInverseLink { out["single_record"] = true }
            if let inverse = name(of: o.inverseFieldID) { out[field.isInverseLink ? "owner_field" : "inverse_field"] = inverse }
            if field.isInverseLink { out["is_inverse"] = true }
        case .lookup, .rollup, .count:
            if let link = name(of: o.linkFieldID) { out["link_field"] = link }
            if field.type != .count, let target = name(of: o.targetFieldID) { out["target_field"] = target }
            if field.type == .rollup {
                out["formula"] = .string(o.rollupFormula ?? "SUM(values)")
                describeResult(o, into: &out)
            }
        case .formula:
            if let formula = o.formula { out["formula"] = .string(document.formulaWithFieldNames(formula, tableID: field.tableID)) }
            describeResult(o, into: &out)
        case .button:
            out["label"] = .string(o.buttonLabel ?? "Open")
            out["action"] = .string((o.buttonAction ?? .openURL) == .openURL ? "open_url" : "run_automation")
            if let formula = o.buttonURLFormula { out["url_formula"] = .string(document.formulaWithFieldNames(formula, tableID: field.tableID)) }
            if let automation = document.automation(o.buttonAutomationID) { out["automation"] = .string(automation.name) }
        default:
            break
        }
        return out
    }

    private static func describeResult(_ o: FieldOptions, into out: inout [String: JSONValue]) {
        if let format = o.resultFormat, format != .automatic { out["result_format"] = .string(format.rawValue) }
        if let p = o.precision { out["precision"] = .number(Double(p)) }
        if let s = o.currencySymbol { out["currency_symbol"] = .string(s) }
    }

    // MARK: - Accepted keys

    private static let aliases: [String: String] = [
        "precision": "precision", "decimals": "precision", "decimalplaces": "precision",
        "currencysymbol": "currency_symbol",
        "durationformat": "duration_format",
        "max": "max", "ratingmax": "max", "maxrating": "max",
        "choices": "choices",
        "includetime": "include_time",
        "dateformat": "date_format",
        "use24hourclock": "use_24_hour_clock",
        "linkedtable": "linked_table", "linkedtableid": "linked_table",
        "singlerecord": "single_record", "singlerecordlink": "single_record", "prefersinglerecordlink": "single_record",
        "linkfield": "link_field", "linkfieldid": "link_field", "recordlinkfieldid": "link_field",
        "targetfield": "target_field", "targetfieldid": "target_field", "fieldidinlinkedtable": "target_field",
        "formula": "formula", "rollupformula": "formula", "aggregation": "formula",
        "resultformat": "result_format",
        "watchedfields": "watched_fields",
        "label": "label", "buttonlabel": "label",
        "urlformula": "url_formula", "buttonurlformula": "url_formula",
        "action": "action", "buttonaction": "action",
        "automation": "automation", "automationid": "automation",
    ]

    /// The option keys a field type accepts. Types added later accept none until they're described here.
    static func keys(for type: FieldType) -> [String] {
        switch type {
        case .number, .percent: ["precision"]
        case .currency: ["precision", "currency_symbol"]
        case .duration: ["duration_format"]
        case .rating: ["max"]
        case .singleSelect, .multipleSelects: ["choices"]
        case .date, .createdTime: ["include_time", "date_format", "use_24_hour_clock"]
        case .lastModifiedTime: ["include_time", "date_format", "use_24_hour_clock", "watched_fields"]
        case .link: ["linked_table", "single_record"]
        case .lookup: ["link_field", "target_field"]
        case .rollup: ["link_field", "target_field", "formula", "result_format", "precision", "currency_symbol"]
        case .count: ["link_field"]
        case .formula: ["formula", "result_format", "precision", "currency_symbol", "duration_format", "date_format", "use_24_hour_clock"]
        case .button: ["label", "action", "url_formula", "automation"]
        default: []
        }
    }

    /// Options that name fields of the table, which `create_table` can only resolve once every new
    /// field exists.
    static let referenceKeys: Set<String> = ["link_field", "target_field", "formula", "watched_fields", "url_formula"]

    /// Maps keys onto their canonical snake_case form, rejecting ones the type doesn't take.
    static func normalize(_ raw: [String: JSONValue], for type: FieldType, fieldName: String) throws(ToolError) -> [String: JSONValue] {
        let accepted = keys(for: type)
        var out: [String: JSONValue] = [:]
        for key in raw.keys.sorted() {
            let folded = key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
            guard let canonical = aliases[folded], accepted.contains(canonical) else {
                let list = accepted.isEmpty ? "\(type.displayName) fields take no options" : "accepted: \(accepted.joined(separator: ", "))"
                throw ToolError("Unknown option \(key) for \(fieldName) (\(list))")
            }
            out[canonical] = raw[key]
        }
        return out
    }

    static func missingRequired(_ options: [String: JSONValue], for type: FieldType) -> [String] {
        let required: [String]
        switch type {
        case .link: required = ["linked_table"]
        case .lookup, .rollup: required = ["link_field", "target_field"]
        case .count: required = ["link_field"]
        case .formula: required = ["formula"]
        default: required = []
        }
        return required.filter { options[$0] == nil || options[$0]?.isNull == true }
    }

    // MARK: - Applying

    /// Where the field being configured lives. `tableID` is nil while planning a table that doesn't
    /// exist yet, when only options that don't name fields can be checked.
    struct Target {
        var tableID: String?
        var tableName: String
        var fieldID: String?
        var fieldName: String
    }

    /// Applies normalized options on top of `base`. With `resolveReferences` false, options that name
    /// fields are skipped (see `referenceKeys`).
    static func apply(_ options: [String: JSONValue], to base: FieldOptions, type: FieldType, target: Target, document: BaseDocument, resolveReferences: Bool) throws(ToolError) -> FieldOptions {
        var o = base
        let label = target.fieldName
        for key in options.keys.sorted() {
            let value = options[key]!
            if !resolveReferences && referenceKeys.contains(key) { continue }
            switch key {
            case "precision":
                o.precision = try optionalInt(value, key: key, field: label, range: 0...8)
            case "currency_symbol":
                o.currencySymbol = try optionalString(value, key: key, field: label)
            case "duration_format":
                o.durationFormat = try optionalEnum(value, key: key, field: label, cases: DurationFormat.allCases.map { ($0.rawValue, $0) })
            case "max":
                o.ratingMax = try optionalInt(value, key: key, field: label, range: 1...10)
            case "choices":
                o.choices = try choices(value, existing: base.choices ?? [], field: label)
            case "include_time":
                o.includeTime = try optionalBool(value, key: key, field: label)
            case "date_format":
                o.dateFormat = try optionalEnum(value, key: key, field: label, cases: DateDisplayFormat.allCases.map { ($0.rawValue, $0) })
            case "use_24_hour_clock":
                o.use24HourClock = try optionalBool(value, key: key, field: label)
            case "single_record":
                o.singleRecordLink = try optionalBool(value, key: key, field: label) == true ? true : nil
            case "result_format":
                o.resultFormat = try optionalEnum(value, key: key, field: label, cases: FormulaResultFormat.allCases.map { ($0.rawValue, $0) })
            case "label":
                o.buttonLabel = try optionalString(value, key: key, field: label)
            case "action":
                o.buttonAction = try optionalEnum(value, key: key, field: label, cases: [("open_url", .openURL), ("openURL", .openURL), ("run_automation", .runAutomation), ("runAutomation", .runAutomation)])
            case "automation":
                if let name = try optionalString(value, key: key, field: label) {
                    guard let automation = document.automations.first(where: { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                        throw ToolError("No automation named \(name) for \(label). Automations: \(document.automations.map(\.name).joined(separator: ", "))")
                    }
                    o.buttonAutomationID = automation.id
                    if options["action"] == nil { o.buttonAction = .runAutomation }
                } else {
                    o.buttonAutomationID = nil
                }
            case "linked_table":
                guard let name = try optionalString(value, key: key, field: label) else { throw ToolError("\(label) needs linked_table") }
                if name == target.tableID || name.caseInsensitiveCompare(target.tableName) == .orderedSame {
                    o.linkedTableID = target.tableID
                } else if let table = document.table(name) ?? document.table(named: name) {
                    o.linkedTableID = table.id
                } else {
                    throw ToolError("No table named \(name) to link \(label) to. Tables: \(document.tables.map(\.name).joined(separator: ", "))")
                }
            case "link_field":
                guard let tableID = target.tableID, let name = try optionalString(value, key: key, field: label) else { break }
                guard let link = field(name, in: tableID, document: document), link.type == .link else {
                    let links = document.fields(in: tableID).filter { $0.type == .link }.map(\.name)
                    throw ToolError("\(label): link_field must name a link field in \(target.tableName) (\(links.isEmpty ? "it has none" : links.joined(separator: ", ")))")
                }
                o.linkFieldID = link.id
            case "watched_fields":
                guard let tableID = target.tableID else { break }
                guard let names = value.arrayValue?.compactMap(\.stringValue), names.count == value.arrayValue?.count else {
                    throw ToolError("\(label): watched_fields must be an array of field names")
                }
                var ids: [String] = []
                for name in names {
                    guard let f = field(name, in: tableID, document: document) else { throw ToolError("\(label): no field named \(name) in \(target.tableName)") }
                    ids.append(f.id)
                }
                o.watchedFieldIDs = ids.isEmpty ? nil : ids
            case "target_field", "formula", "url_formula":
                break
            default:
                throw ToolError("Unknown option \(key) for \(label)")
            }
        }
        guard resolveReferences, let tableID = target.tableID else { return o }

        if let value = options["target_field"], let key = try optionalString(value, key: "target_field", field: label) {
            guard let link = document.field(o.linkFieldID), let linkedTable = link.options.linkedTableID else {
                throw ToolError("\(label): set link_field before target_field")
            }
            guard let targetField = field(key, in: linkedTable, document: document) else {
                let names = document.fields(in: linkedTable).map(\.name).joined(separator: ", ")
                throw ToolError("\(label): no field named \(key) in \(document.table(linkedTable)?.name ?? "the linked table"). Fields: \(names)")
            }
            o.targetFieldID = targetField.id
        }
        if let value = options["formula"] {
            if let formula = try optionalString(value, key: "formula", field: label) {
                let variables: Set<String> = type == .rollup ? ["values"] : []
                if let problem = document.compute.validateFormula(formula, tableID: tableID, excludingFieldID: target.fieldID, variables: variables) {
                    throw ToolError("\(label): \(problem) in formula \(formula)")
                }
                if type == .rollup { o.rollupFormula = formula } else { o.formula = formula }
            } else if type == .formula {
                throw ToolError("\(label) needs a formula")
            } else {
                o.rollupFormula = nil
            }
        }
        if let value = options["url_formula"] {
            if let formula = try optionalString(value, key: "url_formula", field: label) {
                if let problem = document.compute.validateFormula(formula, tableID: tableID, excludingFieldID: target.fieldID) {
                    throw ToolError("\(label): \(problem) in url_formula \(formula)")
                }
                o.buttonURLFormula = formula
            } else {
                o.buttonURLFormula = nil
            }
        }
        return o
    }

    private static func field(_ key: String, in tableID: String, document: BaseDocument) -> FieldModel? {
        if let f = document.field(key), f.tableID == tableID { return f }
        return document.field(named: key, in: tableID)
    }

    /// Choices from names or `{name, color, id}` objects. Listed options keep their id (matched by id
    /// or name) so cells using them stay set; options left out are removed.
    private static func choices(_ value: JSONValue, existing: [SelectChoice], field: String) throws(ToolError) -> [SelectChoice] {
        guard let items = value.arrayValue else { throw ToolError("\(field): choices must be an array of option names or {name, color} objects") }
        var out: [SelectChoice] = []
        var seen = Set<String>()
        for item in items {
            let name: String
            var color: ChoiceColor?
            var id: String?
            if let s = item.stringValue {
                name = s
            } else if let object = item.objectValue, let n = object["name"]?.stringValue {
                name = n
                id = object["id"]?.stringValue
                if let c = object["color"], !c.isNull {
                    guard let raw = c.stringValue, let parsed = ChoiceColor(rawValue: raw.lowercased()) else {
                        throw ToolError("\(field): color must be one of \(ChoiceColor.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    color = parsed
                }
            } else {
                throw ToolError("\(field): choices must be option names or {name, color} objects")
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ToolError("\(field): option names can't be empty") }
            guard seen.insert(trimmed.lowercased()).inserted else { throw ToolError("\(field): option \(trimmed) is listed twice") }
            let match = existing.first { $0.id == id } ?? existing.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            out.append(SelectChoice(id: match?.id ?? RowID.choice(), name: trimmed, color: color ?? match?.color ?? .cycling(out.count)))
        }
        return out
    }

    // MARK: - Scalars

    private static func optionalInt(_ value: JSONValue, key: String, field: String, range: ClosedRange<Int>) throws(ToolError) -> Int? {
        if value.isNull { return nil }
        guard let n = value.numberValue ?? value.stringValue.flatMap(Double.init), n == n.rounded(), n >= Double(range.lowerBound), n <= Double(range.upperBound) else {
            throw ToolError("\(field): \(key) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(n)
    }

    private static func optionalBool(_ value: JSONValue, key: String, field: String) throws(ToolError) -> Bool? {
        if value.isNull { return nil }
        guard let b = value.boolValue else { throw ToolError("\(field): \(key) must be true or false") }
        return b
    }

    private static func optionalString(_ value: JSONValue, key: String, field: String) throws(ToolError) -> String? {
        if value.isNull { return nil }
        guard let s = value.stringValue else { throw ToolError("\(field): \(key) must be a string") }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalEnum<T>(_ value: JSONValue, key: String, field: String, cases: [(String, T)]) throws(ToolError) -> T? {
        if value.isNull { return nil }
        guard let s = value.stringValue, let match = cases.first(where: { $0.0.caseInsensitiveCompare(s) == .orderedSame }) else {
            var names: [String] = []
            for (name, _) in cases where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            throw ToolError("\(field): \(key) must be one of \(names.joined(separator: ", "))")
        }
        return match.1
    }
}
