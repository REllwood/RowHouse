import Foundation
import RowHouseFormula

/// Resolves every cell (stored or computed) to a `CellValue`, memoising results until the next change.
@MainActor
public final class ComputeEngine {
    private unowned let document: BaseDocument
    private var cache: [String: [String: CellValue]] = [:]
    private var titleCache: [String: String] = [:]
    private var parsedFormulas: [String: (source: String, result: Result<FormulaExpr, FormulaSyntaxError>)] = [:]
    private var reverseLinks: [String: [String: [String]]] = [:]   // owner field id → target record id → source record ids
    private var autoNumbers: [String: [String: Int]] = [:]         // table id → record id → number
    private var evaluating: Set<String> = []
    private var titleIndex: [String: (exact: [String: String], folded: [String: String])] = [:]

    init(document: BaseDocument) {
        self.document = document
    }

    func invalidate(schema: Bool) {
        cache.removeAll(keepingCapacity: true)
        titleCache.removeAll(keepingCapacity: true)
        reverseLinks.removeAll()
        autoNumbers.removeAll()
        titleIndex.removeAll()
        if schema { parsedFormulas.removeAll() }
    }

    // MARK: - Public entry points

    public func value(record: RecordModel, field: FieldModel) -> CellValue {
        if let hit = cache[record.id]?[field.id] { return hit }
        let key = record.id + "|" + field.id
        if evaluating.contains(key) { return .error("Circular reference") }
        evaluating.insert(key)
        let v = resolve(record: record, field: field)
        evaluating.remove(key)
        cache[record.id, default: [:]][field.id] = v
        return v
    }

    public func title(of record: RecordModel) -> String {
        if let hit = titleCache[record.id] { return hit }
        guard let primary = document.primaryField(of: record.tableID) else { return "Unnamed record" }
        let text = document.displayString(record, primary)
        let title = text.isEmpty ? "Unnamed record" : text
        titleCache[record.id] = title
        return title
    }

    /// Finds a record by its primary value (exact match first, then ignoring case), using an index
    /// built once per change so bulk imports and conversions stay linear.
    public func recordID(titled title: String, in tableID: String) -> String? {
        if titleIndex[tableID] == nil {
            var exact: [String: String] = [:]
            var folded: [String: String] = [:]
            for r in document.records(in: tableID) {
                let t = self.title(of: r)
                if exact[t] == nil { exact[t] = r.id }
                let f = t.lowercased()
                if folded[f] == nil { folded[f] = r.id }
            }
            titleIndex[tableID] = (exact, folded)
        }
        let index = titleIndex[tableID]!
        return index.exact[title] ?? index.folded[title.lowercased()]
    }

    /// Validates a formula for a field in a table; returns an error message or nil.
    public func validateFormula(_ source: String, tableID: String, excludingFieldID: String? = nil, variables: Set<String> = []) -> String? {
        do {
            let expr = try FormulaParser.parse(source, variables: variables)
            for ref in expr.fieldReferences {
                guard let f = resolveField(ref, tableID: tableID) else { return "Unknown field {\(ref)}" }
                if f.id == excludingFieldID { return "A formula can't reference its own field" }
            }
            return nil
        } catch {
            return error.message
        }
    }

    public func parsedFormula(for field: FieldModel) -> Result<FormulaExpr, FormulaSyntaxError>? {
        let source: String?
        let variables: Set<String>
        switch field.type {
        case .formula: source = field.options.formula; variables = []
        case .rollup: source = field.options.rollupFormula ?? "SUM(values)"; variables = ["values"]
        case .button: source = field.options.buttonURLFormula; variables = []
        default: return nil
        }
        guard let source, !source.isEmpty else { return nil }
        let cacheKey = field.id + (field.type == .button ? "#url" : "")
        if let cached = parsedFormulas[cacheKey], cached.source == source { return cached.result }
        let result: Result<FormulaExpr, FormulaSyntaxError>
        do {
            result = .success(try FormulaParser.parse(source, variables: variables))
        } catch {
            result = .failure(error)
        }
        parsedFormulas[cacheKey] = (source, result)
        return result
    }

    /// Record ids linked from `record` through a link field (either side of the relationship).
    public func linkedRecordIDs(record: RecordModel, field: FieldModel) -> [String] {
        guard field.type == .link, let targetTable = field.options.linkedTableID else { return [] }
        if field.isInverseLink {
            guard let owner = field.options.inverseFieldID else { return [] }
            return reverseIndex(ownerFieldID: owner)[record.id] ?? []
        }
        let ids = record[field.id].stringArray
        guard !ids.isEmpty else { return [] }
        return ids.filter { document.record($0)?.tableID == targetTable }
    }

    public func buttonURL(record: RecordModel, field: FieldModel) -> URL? {
        guard case .success(let expr)? = parsedFormula(for: field) else { return nil }
        let v = FormulaEvaluator.evaluate(expr, in: Context(engine: self, record: record, tableID: record.tableID, variables: [:]))
        let s = v.asText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return nil }
        // Buttons open web pages, email, phone numbers and RowHouse links — never local files or apps.
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel", "rowhouse"].contains(scheme) else { return nil }
        return url
    }

    // MARK: - Resolution

    private func resolve(record: RecordModel, field: FieldModel) -> CellValue {
        let raw = record[field.id]
        switch field.type {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber:
            if let s = raw.stringValue, !s.isEmpty { return .text(s) }
            if let n = raw.numberValue { return .text(CellFormatter.number(n, precision: nil)) }
            return .empty
        case .number, .currency, .percent, .duration, .rating:
            if let n = raw.numberValue { return .number(n) }
            if let s = raw.stringValue, let n = Double(s) { return .number(n) }
            return .empty
        case .checkbox:
            return .bool(raw.boolValue ?? false)
        case .singleSelect:
            guard let key = raw.stringValue else { return .empty }
            if let c = field.choice(id: key) ?? field.choice(named: key) { return .choice(c) }
            return .empty
        case .multipleSelects:
            let keys = raw.stringArray
            let choices = keys.compactMap { field.choice(id: $0) ?? field.choice(named: $0) }
            return choices.isEmpty ? .empty : .choices(choices)
        case .date:
            guard let s = raw.stringValue, let d = DateCoding.decode(s) else { return .empty }
            return .date(d, includesTime: field.includesTime)
        case .attachment:
            guard let items = raw.arrayValue else { return .empty }
            let atts = items.compactMap { $0.decode(AttachmentInfo.self) }
            return atts.isEmpty ? .empty : .attachments(atts)
        case .link:
            let ids = linkedRecordIDs(record: record, field: field)
            guard !ids.isEmpty else { return .empty }
            let refs = ids.compactMap { id -> LinkedRecordRef? in
                guard let r = document.record(id) else { return nil }
                return LinkedRecordRef(id: id, title: title(of: r))
            }
            return refs.isEmpty ? .empty : .links(refs)
        case .lookup:
            guard let linkField = document.field(field.options.linkFieldID),
                  let target = document.field(field.options.targetFieldID)
            else { return .error("Lookup is not configured") }
            let ids = linkedRecordIDs(record: record, field: linkField)
            var items: [CellValue] = []
            for id in ids {
                guard let r = document.record(id) else { continue }
                let v = value(record: r, field: target)
                switch v {
                case .empty: continue
                case .list(let inner): items.append(contentsOf: inner)
                default: items.append(v)
                }
            }
            return items.isEmpty ? .empty : .list(items)
        case .rollup:
            guard let linkField = document.field(field.options.linkFieldID),
                  let target = document.field(field.options.targetFieldID)
            else { return .error("Rollup is not configured") }
            guard case .success(let expr)? = parsedFormula(for: field) else { return .error("Invalid rollup formula") }
            let ids = linkedRecordIDs(record: record, field: linkField)
            let values: [FormulaValue] = ids.compactMap { id in
                guard let r = document.record(id) else { return nil }
                return value(record: r, field: target).formulaValue
            }
            let ctx = Context(engine: self, record: record, tableID: record.tableID, variables: ["values": .array(values)])
            return formatted(FormulaEvaluator.evaluate(expr, in: ctx), field: field)
        case .count:
            guard let linkField = document.field(field.options.linkFieldID) else { return .error("Count is not configured") }
            return .number(Double(linkedRecordIDs(record: record, field: linkField).count))
        case .formula:
            guard let parsed = parsedFormula(for: field) else { return .empty }
            switch parsed {
            case .failure(let e): return .error(e.message)
            case .success(let expr):
                let ctx = Context(engine: self, record: record, tableID: record.tableID, variables: [:])
                return formatted(FormulaEvaluator.evaluate(expr, in: ctx), field: field)
            }
        case .createdTime:
            return .date(record.createdTime, includesTime: field.options.includeTime ?? true)
        case .lastModifiedTime:
            let watched = field.options.watchedFieldIDs ?? []
            let stamp: HLC
            if watched.isEmpty {
                stamp = record.lastModifiedStamp
            } else {
                stamp = watched.compactMap { record.cellStamps[$0] }.max() ?? record.createdStamp
            }
            return .date(stamp.date, includesTime: field.options.includeTime ?? true)
        case .autoNumber:
            return .number(Double(autoNumber(for: record)))
        case .button:
            return .text(field.options.buttonLabel ?? "Open")
        }
    }

    private func formatted(_ value: FormulaValue, field: FieldModel) -> CellValue {
        switch field.options.resultFormat {
        case .date?:
            if case .date(let d) = value { return .date(d, includesTime: false) }
        case .dateTime?:
            if case .date(let d) = value { return .date(d, includesTime: true) }
        default:
            if case .date(let d) = value {
                let cal = Calendar.current
                let isMidnight = cal.component(.hour, from: d) == 0 && cal.component(.minute, from: d) == 0 && cal.component(.second, from: d) == 0
                return .date(d, includesTime: !isMidnight)
            }
        }
        return CellValue(formula: value)
    }

    private func autoNumber(for record: RecordModel) -> Int {
        if let table = autoNumbers[record.tableID], let n = table[record.id] { return n }
        // Numbers follow creation order across every record ever created in the table (including
        // deleted ones), so numbers are never reused and every device computes the same sequence.
        var entries: [(HLC, String)] = []
        for (id, e) in document.state.all(.record) where e["_table"]?.stringValue == record.tableID {
            entries.append(((e.props["_created"] ?? e.props["_table"])?.ts ?? .zero, id))
        }
        entries.sort { $0.0 < $1.0 }
        var map: [String: Int] = [:]
        for (i, entry) in entries.enumerated() { map[entry.1] = i + 1 }
        autoNumbers[record.tableID] = map
        return map[record.id] ?? 0
    }

    private func reverseIndex(ownerFieldID: String) -> [String: [String]] {
        if let cached = reverseLinks[ownerFieldID] { return cached }
        var index: [String: [String]] = [:]
        if let owner = document.field(ownerFieldID) {
            for r in document.records(in: owner.tableID) {
                for target in r[owner.id].stringArray {
                    index[target, default: []].append(r.id)
                }
            }
        }
        reverseLinks[ownerFieldID] = index
        return index
    }

    fileprivate func resolveField(_ reference: String, tableID: String) -> FieldModel? {
        if let f = document.field(reference), f.tableID == tableID { return f }
        return document.field(named: reference, in: tableID)
    }

    fileprivate struct Context: FormulaContext {
        let engine: ComputeEngine
        let record: RecordModel
        let tableID: String
        let variables: [String: FormulaValue]

        func value(forField reference: String) -> FormulaValue? {
            MainActor.assumeIsolated {
                guard let field = engine.resolveField(reference, tableID: tableID) else { return nil }
                return engine.value(record: record, field: field).formulaValue
            }
        }

        func variable(_ name: String) -> FormulaValue? { variables[name] }
        var recordID: String { record.id }
        var createdTime: Date { record.createdTime }
        var lastModifiedTime: Date { record.lastModifiedTime }
        var now: Date { Date() }
        var timeZone: TimeZone { .current }
    }
}

/// A filter formula that can't be used: a syntax error, or a reference to a field the table lacks.
public struct FormulaFilterError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

extension ComputeEngine {
    /// Keeps the records for which an Airtable-style formula, such as `AND({Status} = "Done", {Qty} > 3)`,
    /// evaluates to a truthy value. Errors inside the formula count as false for that record.
    public func filter(_ records: [RecordModel], formula source: String, tableID: String) throws(FormulaFilterError) -> [RecordModel] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return records }
        let expr: FormulaExpr
        do {
            expr = try FormulaParser.parse(source)
        } catch {
            throw FormulaFilterError(error.message)
        }
        for reference in expr.fieldReferences.sorted() where resolveField(reference, tableID: tableID) == nil {
            throw FormulaFilterError("Unknown field {\(reference)}")
        }
        return records.filter { record in
            FormulaEvaluator.evaluate(expr, in: Context(engine: self, record: record, tableID: tableID, variables: [:])).isTruthy
        }
    }
}

extension BaseDocument {
    /// Records of a table, in their manual order, for which an Airtable-style formula is truthy.
    public func records(in tableID: String, matchingFormula formula: String) throws(FormulaFilterError) -> [RecordModel] {
        try compute.filter(records(in: tableID), formula: formula, tableID: tableID)
    }
}
