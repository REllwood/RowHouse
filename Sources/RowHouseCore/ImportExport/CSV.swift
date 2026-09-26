import Foundation

/// RFC 4180 CSV reading and writing with delimiter detection.
public enum CSV {
    public static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        var input = Substring(text)
        if input.hasPrefix("\u{FEFF}") { input = input.dropFirst() }
        let delim = delimiter ?? detectDelimiter(input)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = input.startIndex
        var fieldStarted = false

        while index < input.endIndex {
            let ch = input[index]
            if inQuotes {
                if ch == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex && input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if ch == delim {
                row.append(field)
                field = ""
                fieldStarted = false
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                fieldStarted = false
            } else {
                field.append(ch)
                fieldStarted = true
            }
            index = input.index(after: index)
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop trailing completely empty rows.
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        return rows
    }

    static func detectDelimiter(_ text: Substring) -> Character {
        let sample = text.prefix(4_000)
        let firstLine = sample.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).first ?? sample
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
    }

    public static func escape(_ value: String, delimiter: Character = ",") -> String {
        if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") || value.hasPrefix(" ") || value.hasSuffix(" ") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    public static func write(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { $0.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }.joined(separator: "\r\n") + "\r\n"
    }
}

public struct CSVColumnPlan: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var header: String
    public var include: Bool
    public var type: FieldType
    /// When importing into an existing table: the field to fill (nil = create a new field).
    public var targetFieldID: String?
}

public enum CSVImporter {
    /// Guesses a field type from sample values.
    public static func inferType(_ values: [String]) -> FieldType {
        let nonEmpty = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return .singleLineText }
        let sample = Array(nonEmpty.prefix(500))
        func all(_ test: (String) -> Bool) -> Bool { sample.allSatisfy(test) }

        let boolWords: Set<String> = ["true", "false", "yes", "no", "checked", "unchecked", "x", "✓", "✔", "0", "1"]
        if all({ boolWords.contains($0.lowercased()) }) && !all({ $0 == "0" || $0 == "1" }) { return .checkbox }
        if all({ $0.hasSuffix("%") && Double($0.dropLast().trimmingCharacters(in: .whitespaces)) != nil }) { return .percent }
        let currencyPrefixes = ["$", "€", "£", "¥", "A$", "US$", "C$", "NZ$", "₹"]
        if all({ s in currencyPrefixes.contains { s.hasPrefix($0) || s.hasPrefix("-" + $0) } && ValueParsing.number(from: s) != nil }) { return .currency }
        if all({ Double($0.replacingOccurrences(of: ",", with: "")) != nil }) { return .number }
        if all({ $0.contains("@") && $0.contains(".") && !$0.contains(" ") }) { return .email }
        if all({ ($0.hasPrefix("http://") || $0.hasPrefix("https://")) && !$0.contains(" ") }) { return .url }
        if all({ s in DateCoding.parseUserInput(s) != nil && s.count >= 6 && s.rangeOfCharacter(from: .decimalDigits) != nil }) { return .date }
        if sample.contains(where: { $0.contains("\n") }) || sample.contains(where: { $0.count > 120 }) { return .multilineText }
        let unique = Set(sample.map { $0.lowercased() })
        if sample.count >= 4 && unique.count <= max(2, min(12, sample.count / 3)) { return .singleSelect }
        return .singleLineText
    }

    public static func plan(rows: [[String]], hasHeader: Bool) -> [CSVColumnPlan] {
        let width = rows.map(\.count).max() ?? 0
        let header = hasHeader ? (rows.first ?? []) : []
        let body = hasHeader ? Array(rows.dropFirst()) : rows
        return (0..<width).map { i in
            let name = i < header.count && !header[i].trimmingCharacters(in: .whitespaces).isEmpty ? header[i].trimmingCharacters(in: .whitespaces) : "Field \(i + 1)"
            let values = body.map { i < $0.count ? $0[i] : "" }
            return CSVColumnPlan(index: i, header: name, include: true, type: i == 0 && inferType(values) == .multilineText ? .singleLineText : inferType(values))
        }
    }
}

extension BaseDocument {
    /// Imports CSV rows into a new table. Returns the new table id.
    @discardableResult
    public func importCSV(rows: [[String]], hasHeader: Bool, plan: [CSVColumnPlan], tableName: String) -> String {
        var tableID = ""
        batch("Import CSV") {
            let included = plan.filter(\.include)
            tableID = createTable(name: tableName, starterFields: false, emptyRecords: 0)
            var fieldIDs: [Int: String] = [:]
            if let primary = primaryField(of: tableID), let first = included.first {
                let type = first.type.canBePrimary ? first.type : .singleLineText
                updateField(primary.id, name: first.header, type: type)
                fieldIDs[first.index] = primary.id
            }
            for column in included.dropFirst() {
                fieldIDs[column.index] = createField(in: tableID, name: column.header, type: column.type)
            }
            appendCSVRows(rows: hasHeader ? Array(rows.dropFirst()) : rows, into: tableID, fieldIDs: fieldIDs)
        }
        return tableID
    }

    /// Appends CSV rows to an existing table using the plan's target fields.
    public func importCSV(rows: [[String]], hasHeader: Bool, plan: [CSVColumnPlan], into tableID: String) {
        batch("Import CSV") {
            var fieldIDs: [Int: String] = [:]
            for column in plan where column.include {
                if let target = column.targetFieldID, field(target) != nil {
                    fieldIDs[column.index] = target
                } else {
                    fieldIDs[column.index] = createField(in: tableID, name: column.header, type: column.type)
                }
            }
            appendCSVRows(rows: hasHeader ? Array(rows.dropFirst()) : rows, into: tableID, fieldIDs: fieldIDs)
        }
    }

    private func appendCSVRows(rows: [[String]], into tableID: String, fieldIDs: [Int: String]) {
        var values: [[String: JSONValue]] = []
        values.reserveCapacity(rows.count)
        for row in rows {
            var set: [String: JSONValue] = [:]
            for (i, text) in row.enumerated() {
                guard let fid = fieldIDs[i], let f = field(fid), !text.isEmpty else { continue }
                let v = parseValue(text, for: f, createMissingChoices: true)
                if !v.isNull { set[fid] = v }
            }
            values.append(set)
        }
        createRecords(in: tableID, values: values, applyingDefaults: false)
    }

    /// Exports a view (visible fields, filtered/sorted records) as CSV text.
    public func exportCSV(view: ViewModel) -> String {
        let fields = visibleFields(for: view)
        var rows: [[String]] = [fields.map(\.name)]
        for id in evaluate(view: view).recordIDs {
            guard let r = record(id) else { continue }
            rows.append(fields.map { displayString(r, $0) })
        }
        return CSV.write(rows)
    }
}
