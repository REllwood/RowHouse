import Foundation

/// Converts between stored cells and the plain JSON that integrations read and write: the MCP server
/// uses Airtable REST-style values (`.api`) and automation scripts use Airtable scripting-style values
/// (`.scripting`). Fields can be addressed by name or id.
///
/// Reading: text → string, numbers → number (percent as a fraction, duration in seconds), checkbox →
/// bool, select → option name (`.api`) or `{id, name, color}` (`.scripting`), multiple select → array of
/// those, date → "YYYY-MM-DD" or an ISO-8601 date-time, link → `[{id, name}]`, attachment →
/// `[{id, filename, size, type, url}]`, computed fields → their result.
///
/// Writing accepts the same shapes plus friendlier ones (option names for selects, record ids or primary
/// field values for links, typed text for numbers and dates). Computed and attachment fields are read-only.
@MainActor
public final class RecordValueCoding {
    public enum Style: Sendable {
        /// Select options as names, like Airtable's REST API.
        case api
        /// Select options as `{id, name, color}` objects, like Airtable's scripting API.
        case scripting
    }

    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
        public var errorDescription: String? { message }
    }

    public let document: BaseDocument
    public let style: Style
    /// When true, select option names that don't exist yet become new options instead of failing.
    public let typecast: Bool
    /// When true, values that can't be used are dropped instead of failing the write: unknown linked
    /// records are skipped, unreadable dates clear the cell and lists written to text are joined. This
    /// is how automation scripts have always behaved.
    public let lenient: Bool
    /// The base's attachments folder; when set, attachments are given a `file://` URL.
    public let attachmentsURL: URL?

    /// Options needed by converted values that don't exist yet, keyed by field id. They're added when
    /// the values are written, so a write that fails validation never leaves stray options behind.
    private var pendingChoices: [String: [SelectChoice]] = [:]
    /// Primary field values → record ids, per table, built on first use. Valid while the coder is
    /// used for one read or write.
    private var titleIndexes: [String: (exact: [String: [String]], folded: [String: [String]])] = [:]

    public init(document: BaseDocument, style: Style = .api, typecast: Bool = false, lenient: Bool = false, attachmentsURL: URL? = nil) {
        self.document = document
        self.style = style
        self.typecast = typecast
        self.lenient = lenient
        self.attachmentsURL = attachmentsURL
    }

    // MARK: - Reading

    /// A record's values keyed by field name. Empty values are left out unless `includeEmpty` is set,
    /// in which case they're `null` (`false` for checkboxes).
    public func fields(of record: RecordModel, only fields: [FieldModel]? = nil, includeEmpty: Bool = false) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for field in fields ?? document.fields(in: record.tableID) {
            if !includeEmpty && document.value(record, field).isEmpty { continue }
            out[field.name] = value(of: record, field: field)
        }
        return out
    }

    /// The JSON for one cell of a record.
    public func value(of record: RecordModel, field: FieldModel) -> JSONValue {
        if style == .api && field.type == .button {
            var button: [String: JSONValue] = ["label": .string(field.options.buttonLabel ?? "Open")]
            if let url = document.compute.buttonURL(record: record, field: field) { button["url"] = .string(url.absoluteString) }
            return .object(button)
        }
        return value(document.value(record, field), field: field)
    }

    /// The JSON for a resolved value of `field`.
    public func value(_ value: CellValue, field: FieldModel) -> JSONValue {
        switch value {
        case .empty: return field.type == .checkbox ? .bool(false) : .null
        case .text(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .date(let d, let includesTime):
            return .string(includesTime ? DateCoding.iso8601String(d) : DateCoding.encode(d, includeTime: false))
        case .choice(let c): return json(c)
        case .choices(let cs): return .array(cs.map(json))
        case .attachments(let atts): return .array(atts.map(json))
        case .links(let refs): return .array(refs.map { .object(["id": .string($0.id), "name": .string($0.title)]) })
        case .collaborators(let people):
            let objects: [JSONValue] = people.map { person in
                var o: [String: JSONValue] = ["id": .string(person.id), "name": .string(person.displayName)]
                if !person.email.isEmpty { o["email"] = .string(person.email) }
                return .object(o)
            }
            let single = field.type == .createdBy || field.type == .lastModifiedBy
                || (field.type == .collaborator && field.options.allowMultipleCollaborators != true)
            return single && objects.count == 1 ? objects[0] : .array(objects)
        case .list(let items): return .array(items.map { self.value($0, field: field) })
        case .error(let message): return .object(["error": .string(message)])
        }
    }

    private func json(_ choice: SelectChoice) -> JSONValue {
        switch style {
        case .api: return .string(choice.name)
        case .scripting: return .object(["id": .string(choice.id), "name": .string(choice.name), "color": .string(choice.color.rawValue)])
        }
    }

    private func json(_ attachment: AttachmentInfo) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(attachment.id),
            "filename": .string(attachment.filename),
            "size": .number(Double(attachment.size)),
            "type": .string(attachment.mimeType),
        ]
        if let attachmentsURL { out["url"] = .string(attachmentsURL.appendingPathComponent(attachment.storedFileName).absoluteString) }
        if let w = attachment.width { out["width"] = .number(Double(w)) }
        if let h = attachment.height { out["height"] = .number(Double(h)) }
        return .object(out)
    }

    // MARK: - Writing

    /// A field of a table by id, then by name (exact, then ignoring case).
    public func field(_ key: String, in tableID: String) -> FieldModel? {
        if let f = document.field(key), f.tableID == tableID { return f }
        return document.field(named: key.trimmingCharacters(in: .whitespacesAndNewlines), in: tableID)
    }

    /// Converts JSON keyed by field name or id into stored values keyed by field id. Select options
    /// that `typecast` has to create are added by `commitPendingChoices()` (which `createRecords` and
    /// `updateRecords` call for you).
    public func storedValues(_ fields: [String: JSONValue], tableID: String) throws(Failure) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in fields.keys.sorted() {
            guard let field = field(key, in: tableID) else {
                let table = document.table(tableID)
                let names = document.fields(in: tableID).map(\.name).joined(separator: ", ")
                throw Failure("No field named \(key) in table \(table?.name ?? tableID). Fields: \(names)")
            }
            out[field.id] = try storedValue(fields[key] ?? .null, for: field)
        }
        return out
    }

    /// Converts JSON for one field into its stored form. `null` clears the cell.
    public func storedValue(_ value: JSONValue, for field: FieldModel) throws(Failure) -> JSONValue {
        guard field.isEditable else {
            throw Failure("\(field.name) is a \(field.type.displayName.lowercased()) field, which is computed and can't be written")
        }
        if value.isNull { return .null }
        switch field.type {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber:
            guard let text = Self.scalarText(value) ?? (lenient ? TemplateRenderer.string(value) : nil) else {
                throw Failure("\(field.name) expects text")
            }
            return document.parseValue(text, for: field, createMissingChoices: false)
        case .number, .currency, .percent, .duration, .rating:
            return try number(value, for: field)
        case .checkbox:
            if let b = value.boolValue { return .bool(b) }
            if let n = value.numberValue { return .bool(n != 0) }
            if let s = value.stringValue ?? (lenient ? TemplateRenderer.string(value) : nil) {
                return .bool(ValueParsing.truthyStrings.contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
            }
            throw Failure("\(field.name) expects true or false")
        case .singleSelect:
            let item: JSONValue
            if let items = value.arrayValue {
                guard items.count <= 1 else { throw Failure("\(field.name) is a single select; pass one option") }
                guard let first = items.first else { return .null }
                item = first
            } else {
                item = value
            }
            return try choiceID(item, for: field).map(JSONValue.string) ?? .null
        case .multipleSelects:
            var items = value.arrayValue ?? [value]
            if let s = value.stringValue, !hasChoice(named: s, in: field) {
                // Comma-separated names, unless the whole text is one option's name.
                items = s.split(separator: ",").map { .string(String($0)) }
            }
            var ids: [String] = []
            for item in items {
                if let id = try choiceID(item, for: field), !ids.contains(id) { ids.append(id) }
            }
            return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
        case .date:
            let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if text?.isEmpty == true { return .null }
            if let text, let stored = Self.date(text, includeTime: field.includesTime) { return .string(stored) }
            if lenient { return .null }
            let example = "a date such as \"2026-09-26\" or \"2026-09-26T14:30:00Z\""
            throw Failure(text.map { "\(field.name) expects \(example), not \"\($0)\"" } ?? "\(field.name) expects \(example)")
        case .link:
            return try links(value, for: field)
        case .attachment:
            throw Failure("\(field.name) is an attachment field; attachments can't be written here, add files in RowHouse")
        case .collaborator:
            return try collaborators(value, for: field)
        case .barcode:
            guard let barcode = BarcodeValue(json: value) else { throw Failure("\(field.name) expects barcode text or {text, type}") }
            return barcode.json
        default:
            // Types without a dedicated JSON form take text, read the way typed input is.
            guard let text = Self.scalarText(value) ?? (lenient ? TemplateRenderer.string(value) : nil) else {
                throw Failure("\(field.name) expects text")
            }
            return document.parseValue(text, for: field, createMissingChoices: false)
        }
    }

    /// Records of a table whose primary field value is `title`: exact matches if there are any,
    /// otherwise matches ignoring case.
    public func recordIDs(titled title: String, in tableID: String) -> [String] {
        if titleIndexes[tableID] == nil {
            var exact: [String: [String]] = [:]
            var folded: [String: [String]] = [:]
            for record in document.records(in: tableID) {
                let t = document.primaryTitle(record)
                exact[t, default: []].append(record.id)
                folded[t.lowercased(), default: []].append(record.id)
            }
            titleIndexes[tableID] = (exact, folded)
        }
        let index = titleIndexes[tableID]!
        return index.exact[title] ?? index.folded[title.lowercased()] ?? []
    }

    /// Adds the select options that converted values need. Not needed after `createRecords` or
    /// `updateRecords`, which call it.
    public func commitPendingChoices(origin: ChangeOrigin = .local) {
        let pending = pendingChoices
        pendingChoices = [:]
        for (fieldID, choices) in pending.sorted(by: { $0.key < $1.key }) {
            guard let field = document.field(fieldID) else { continue }
            var options = field.options
            options.choices = (options.choices ?? []) + choices
            document.commit([Mutation(.field, fieldID, ["options": JSONValue(encoding: options)])], actionName: "Add Option", origin: origin)
        }
    }

    /// Creates records from JSON keyed by field name or id. Every record is checked before any is
    /// written, so a bad value creates nothing. Returns the new record ids in order.
    @discardableResult
    public func createRecords(_ records: [[String: JSONValue]], in tableID: String, origin: ChangeOrigin = .local) throws(Failure) -> [String] {
        guard document.table(tableID) != nil else { throw Failure("No table \(tableID)") }
        var values: [[String: JSONValue]] = []
        do throws(Failure) {
            for (index, fields) in records.enumerated() {
                do throws(Failure) {
                    values.append(try storedValues(fields, tableID: tableID).filter { !$0.value.isNull })
                } catch {
                    throw records.count > 1 ? Failure("Record \(index + 1): \(error.message)") : error
                }
            }
        } catch {
            pendingChoices = [:]
            throw error
        }
        var ids: [String] = []
        document.batch(records.count == 1 ? "Add Record" : "Add Records", origin: origin) {
            commitPendingChoices(origin: origin)
            ids = document.createRecords(in: tableID, values: values, origin: origin)
        }
        return ids
    }

    /// Changes only the fields named in each update; other fields keep their values. Every update is
    /// checked before any is written.
    public func updateRecords(_ updates: [(id: String, fields: [String: JSONValue])], in tableID: String, actionName: String = "Edit Records", origin: ChangeOrigin = .local) throws(Failure) {
        var values: [String: [String: JSONValue]] = [:]
        do throws(Failure) {
            for update in updates {
                guard let record = document.record(update.id), record.tableID == tableID else {
                    throw Failure("No record \(update.id) in table \(document.table(tableID)?.name ?? tableID)")
                }
                do throws(Failure) {
                    values[update.id, default: [:]].merge(try storedValues(update.fields, tableID: tableID)) { _, new in new }
                } catch {
                    throw updates.count > 1 ? Failure("Record \(update.id): \(error.message)") : error
                }
            }
        } catch {
            pendingChoices = [:]
            throw error
        }
        document.batch(actionName, origin: origin) {
            commitPendingChoices(origin: origin)
            document.updateRecords(values, actionName: actionName, origin: origin)
        }
    }

    // MARK: - Conversions

    /// People by id, email or name, or `{id}` / `{email}` / `{name}` objects. Unknown people are an
    /// error unless `typecast` (or `lenient`) is set, which adds them to the base's collaborators.
    private func collaborators(_ value: JSONValue, for field: FieldModel) throws(Failure) -> JSONValue {
        var items = value.arrayValue ?? [value]
        if let s = value.stringValue, document.person(matching: s) == nil {
            items = s.split(separator: ",").map { .string(String($0)) }
        }
        var ids: [String] = []
        for item in items {
            let key = (item["id"]?.stringValue ?? item["email"]?.stringValue ?? item["name"]?.stringValue ?? Self.scalarText(item) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            if let person = document.person(matching: key) {
                if !ids.contains(person.id) { ids.append(person.id) }
                continue
            }
            guard typecast || lenient else {
                let names = document.people.map(\.displayName)
                let list = names.isEmpty ? "the base has no collaborators yet" : "collaborators: " + names.joined(separator: ", ")
                throw Failure("No collaborator matches \(key) for \(field.name) (\(list)). Use typecast to add them.")
            }
            let isEmail = key.contains("@") && !key.contains(" ")
            let name = item["name"]?.stringValue ?? (isEmail ? "" : key)
            let email = item["email"]?.stringValue ?? (isEmail ? key : "")
            if let person = document.addPerson(name: name, email: email) { ids.append(person.id) }
        }
        if ids.count > 1, field.options.allowMultipleCollaborators != true, !lenient {
            throw Failure("\(field.name) takes one collaborator")
        }
        return document.storedCollaborators(ids, field: field)
    }

    private func number(_ value: JSONValue, for field: FieldModel) throws(Failure) -> JSONValue {
        let expected: String
        switch field.type {
        case .percent: expected = "a number (0.5 is 50%) or text such as \"50%\""
        case .duration: expected = "a number of seconds or text such as \"1:30\""
        case .rating: expected = "a whole number from 0 to \(field.options.ratingMax ?? 5)"
        default: expected = "a number"
        }
        var stored: JSONValue
        // A plain number in a string means the same as the number itself; other text is read the way
        // a person types it ("25%", "1:30", "$1,200").
        let plain = value.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let n = value.numberValue ?? plain {
            guard n.isFinite else { throw Failure("\(field.name) expects \(expected)") }
            stored = .number(n)
        } else if let s = value.stringValue {
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .null }
            let isStars = field.type == .rating && s.contains { $0 == "★" || $0 == "⭐" }
            if field.type == .rating && !isStars && ValueParsing.number(from: s) == nil {
                throw Failure("\(field.name) expects \(expected), not \"\(s)\"")
            }
            // Text is read the way a person would type it into the cell.
            stored = document.parseValue(s, for: field, createMissingChoices: false)
            if stored.isNull && field.type != .rating { throw Failure("\(field.name) expects \(expected), not \"\(s)\"") }
        } else {
            throw Failure("\(field.name) expects \(expected)")
        }
        if field.type == .rating, let n = stored.numberValue {
            let clamped = min(max(0, n.rounded()), Double(field.options.ratingMax ?? 5))
            stored = clamped == 0 ? .null : .number(clamped)
        }
        return stored
    }

    private func hasChoice(named name: String, in field: FieldModel) -> Bool {
        let current = document.field(field.id) ?? field
        return current.choice(named: name) != nil
            || pendingChoices[field.id]?.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } == true
    }

    /// The option id for a name, id or `{id}` / `{name}` object; nil for an empty name.
    private func choiceID(_ item: JSONValue, for field: FieldModel) throws(Failure) -> String? {
        let current = document.field(field.id) ?? field
        if let id = item["id"]?.stringValue, current.choice(id: id) != nil { return id }
        guard let raw = item["name"]?.stringValue ?? Self.scalarText(item) else {
            throw Failure("\(field.name) expects option names")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if let choice = current.choice(id: name) ?? current.choice(named: name) { return choice.id }
        if let pending = pendingChoices[field.id]?.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return pending.id
        }
        guard typecast else {
            let names = current.choices.map(\.name)
            let list = names.isEmpty ? "it has no options yet" : "options: " + names.joined(separator: ", ")
            throw Failure("\(name) isn't an option of \(field.name) (\(list)). Use typecast to add new options.")
        }
        let choice = SelectChoice(name: name, color: .cycling(current.choices.count + (pendingChoices[field.id]?.count ?? 0)))
        pendingChoices[field.id, default: []].append(choice)
        return choice.id
    }

    /// Record ids for a link field from ids, primary field values or `{id}` / `{name}` objects.
    /// Links only ever point at existing records; text never creates one.
    private func links(_ value: JSONValue, for field: FieldModel) throws(Failure) -> JSONValue {
        guard let tableID = field.options.linkedTableID, let table = document.table(tableID) else {
            throw Failure("\(field.name) isn't linked to a table")
        }
        var ids: [String] = []
        for item in value.arrayValue ?? [value] {
            guard let raw = item["id"]?.stringValue ?? item["name"]?.stringValue ?? Self.scalarText(item) else {
                throw Failure("\(field.name) expects record ids or primary field values from \(table.name)")
            }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            let id: String
            if let r = document.record(key), r.tableID == tableID {
                id = key
            } else {
                let matches = recordIDs(titled: key, in: tableID)
                if matches.count == 1 {
                    id = matches[0]
                } else if lenient, let first = matches.first {
                    id = first
                } else if lenient {
                    continue
                } else if matches.isEmpty {
                    throw Failure("\(field.name): no record \(key) in \(table.name). Links must name an existing record by id or primary field value.")
                } else {
                    throw Failure("\(field.name): \(matches.count) records in \(table.name) are called \(key); link them by record id")
                }
            }
            if !ids.contains(id) { ids.append(id) }
        }
        if field.options.singleRecordLink == true && !field.isInverseLink && ids.count > 1 {
            guard lenient else { throw Failure("\(field.name) links to a single record; pass one") }
            ids = [ids[0]]
        }
        return ids.isEmpty ? .null : .array(ids.map(JSONValue.string))
    }

    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n):
            guard n.isFinite else { return nil }
            return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : "\(n)"
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Stored form of a date given as "YYYY-MM-DD", an ISO-8601 date-time (with or without a zone) or
    /// text a person might type. A date-only field keeps the calendar day written in an ISO date-time
    /// rather than shifting it into this Mac's time zone.
    static func date(_ text: String, includeTime: Bool) -> String? {
        let isoDateTime = text.count > 10 && text.utf8.count == text.count && Array(text)[10] == "T"
        if isoDateTime && !includeTime {
            let day = String(text.prefix(10))
            guard DateCoding.dayDate(day) != nil, parseDateTime(text) != nil else { return nil }
            return day
        }
        guard let date = (isoDateTime ? parseDateTime(text) : nil) ?? DateCoding.parseUserInput(text) else { return nil }
        return DateCoding.encode(date, includeTime: includeTime)
    }

    /// ISO-8601 date-times; ones without a zone are read in this Mac's time zone.
    private static func parseDateTime(_ text: String) -> Date? {
        if let d = DateCoding.parseISO(text) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = pattern
            if let d = formatter.date(from: text) { return d }
        }
        return nil
    }
}
