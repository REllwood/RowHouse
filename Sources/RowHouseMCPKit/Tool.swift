import Foundation
import RowHouseCore

/// One MCP tool: its advertised definition and the code that runs it.
@MainActor
struct Tool {
    enum Effect {
        case readOnly, additive, destructive
    }

    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let effect: Effect
    let run: @MainActor (ToolArguments, Workspace) async throws -> JSONValue

    var argumentNames: Set<String> {
        Set(inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
    }

    var definition: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(effect == .readOnly),
                "destructiveHint": .bool(effect == .destructive),
                "idempotentHint": .bool(effect == .readOnly),
                "openWorldHint": false,
            ]),
        ])
    }
}

@MainActor
enum Tools {
    static let all: [Tool] = [
        listBases, getBaseSchema, listRecords, getRecord, searchRecords,
        createRecords, updateRecords, deleteRecords,
        createTable, updateTable, createField, updateField,
        listComments, addComment, createBase, describeFieldTypes,
    ]

    static let maxRecordsPerWrite = 100

    // MARK: - Shared argument schemas

    static let baseArgument = Schema.string("Base id (app…) or name.")
    static let tableArgument = Schema.string("Table id (tbl…) or name.")
    static let typecastArgument = Schema.boolean("When true, select option names that don't exist yet are added to the field instead of causing an error.", default: false)

    // MARK: - JSON for results

    static func iso(_ date: Date) -> JSONValue {
        .string(DateCoding.iso8601String(date))
    }

    static func coding(_ session: AgentSession, typecast: Bool = false) -> RecordValueCoding {
        RecordValueCoding(document: session.document, style: .api, typecast: typecast, attachmentsURL: session.attachmentsURL)
    }

    static func recordJSON(_ record: RecordModel, coding: RecordValueCoding, fields: [FieldModel]? = nil, includeEmpty: Bool = false) -> JSONValue {
        .object([
            "id": .string(record.id),
            "createdTime": iso(record.createdTime),
            "fields": .object(coding.fields(of: record, only: fields, includeEmpty: includeEmpty)),
        ])
    }

    static func baseSummary(_ session: AgentSession) -> JSONValue {
        let doc = session.document
        var out: [String: JSONValue] = [
            "id": .string(session.entry.baseID),
            "name": .string(doc.info.name),
            "tables": .array(doc.tables.map { t in
                .object(["id": .string(t.id), "name": .string(t.name), "recordCount": .number(Double(doc.recordCount(in: t.id)))])
            }),
        ]
        if !doc.info.description.isEmpty { out["description"] = .string(doc.info.description) }
        return .object(out)
    }

    static func tableSchema(_ table: TableModel, in doc: BaseDocument) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(table.id),
            "name": .string(table.name),
            "recordCount": .number(Double(doc.recordCount(in: table.id))),
            "fields": .array(doc.fields(in: table.id).map { fieldSchema($0, in: doc) }),
            "views": .array(doc.views(in: table.id).map { .object(["id": .string($0.id), "name": .string($0.name), "type": .string($0.type.rawValue)]) }),
        ]
        if let primary = doc.primaryField(of: table.id) {
            out["primaryField"] = .string(primary.name)
            out["primaryFieldId"] = .string(primary.id)
        }
        if !table.description.isEmpty { out["description"] = .string(table.description) }
        return .object(out)
    }

    static func fieldSchema(_ field: FieldModel, in doc: BaseDocument) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(field.id),
            "name": .string(field.name),
            "type": .string(field.type.rawValue),
        ]
        if field.type.isComputed || field.type == .attachment { out["readOnly"] = true }
        if doc.primaryField(of: field.tableID)?.id == field.id { out["primary"] = true }
        if !field.description.isEmpty { out["description"] = .string(field.description) }
        let options = FieldOptionsCoding.describe(field, in: doc)
        if !options.isEmpty { out["options"] = .object(options) }
        return .object(out)
    }

    // MARK: - Field types

    private static let typeAliases: [String: FieldType] = [
        "text": .singleLineText, "singlelinetext": .singleLineText, "string": .singleLineText,
        "longtext": .multilineText, "multilinetext": .multilineText, "richtext": .multilineText,
        "phone": .phoneNumber,
        "multipleselect": .multipleSelects, "multiselect": .multipleSelects,
        "select": .singleSelect,
        "datetime": .date,
        "attachments": .attachment, "multipleattachments": .attachment,
        "linkedrecord": .link, "linkedrecords": .link, "multiplerecordlinks": .link, "linktoanotherrecord": .link,
        "multiplelookupvalues": .lookup,
        "autonumber": .autoNumber,
        "bool": .checkbox, "boolean": .checkbox,
    ]

    /// A field type by its id ("singleSelect"), display name ("Single select") or Airtable name.
    /// "dateTime" also switches on include_time.
    static func fieldType(_ raw: String) throws(ToolError) -> (FieldType, impliedOptions: [String: JSONValue]) {
        let folded = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let implied: [String: JSONValue] = folded == "datetime" ? ["include_time": true] : [:]
        if let type = FieldType.allCases.first(where: { $0.rawValue.lowercased() == folded || $0.displayName.lowercased().filter { $0.isLetter || $0.isNumber } == folded }) {
            return (type, implied)
        }
        if let type = typeAliases[folded] { return (type, implied) }
        throw ToolError("Unknown field type \(raw). Types: \(FieldType.allCases.map(\.rawValue).joined(separator: ", ")). describe_field_types explains each one.")
    }
}
