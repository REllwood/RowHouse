import Foundation

/// Reads worksheets from an Excel .xlsx file as rows of text, ready for the CSV import pipeline.
/// Dates (numbers with a date format) become "YYYY-MM-DD" or ISO date-times; booleans "true"/"false".
public enum XLSXReader {
    public struct Sheet: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var rows: [[String]]
    }

    public enum Failure: LocalizedError, Sendable {
        case notAWorkbook
        case unzip(String)

        public var errorDescription: String? {
            switch self {
            case .notAWorkbook: "That file isn't an Excel workbook (.xlsx)."
            case .unzip(let m): "Couldn't open the workbook: \(m)"
            }
        }
    }

    public static func read(_ url: URL) throws -> [Sheet] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rowhouse-xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, dir.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.unzip(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return try read(unzippedAt: dir)
    }

    static func read(unzippedAt dir: URL) throws -> [Sheet] {
        guard let workbook = try? Data(contentsOf: dir.appendingPathComponent("xl/workbook.xml")) else { throw Failure.notAWorkbook }
        let rels = (try? Data(contentsOf: dir.appendingPathComponent("xl/_rels/workbook.xml.rels"))).map(parseRelationships) ?? [:]
        let shared = (try? Data(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml"))).map(parseSharedStrings) ?? []
        let dateStyles = (try? Data(contentsOf: dir.appendingPathComponent("xl/styles.xml"))).map(parseDateStyles) ?? []
        let date1904 = String(decoding: workbook, as: UTF8.self).contains("date1904=\"1\"")
        var sheets: [Sheet] = []
        for (name, relID) in parseSheets(workbook) {
            guard let target = rels[relID] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(path)) else { continue }
            let rows = parseWorksheet(data, shared: shared, dateStyles: dateStyles, date1904: date1904)
            sheets.append(Sheet(name: name, rows: rows))
        }
        guard !sheets.isEmpty else { throw Failure.notAWorkbook }
        return sheets
    }

    // MARK: - XML parts

    private final class Collector: NSObject, XMLParserDelegate {
        var onStart: (String, [String: String]) -> Void = { _, _ in }
        var onEnd: (String) -> Void = { _ in }
        var onText: (String) -> Void = { _ in }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            onStart(localName(elementName), attributes)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            onEnd(localName(elementName))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            onText(string)
        }

        private func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }
    }

    private static func parse(_ data: Data, _ configure: (Collector) -> Void) {
        let collector = Collector()
        configure(collector)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
    }

    static func parseSheets(_ data: Data) -> [(String, String)] {
        var sheets: [(String, String)] = []
        parse(data) { c in
            c.onStart = { name, attrs in
                if name == "sheet", let n = attrs["name"], let id = attrs["r:id"] ?? attrs.first(where: { $0.key.hasSuffix(":id") })?.value {
                    sheets.append((n, id))
                }
            }
        }
        return sheets
    }

    static func parseRelationships(_ data: Data) -> [String: String] {
        var rels: [String: String] = [:]
        parse(data) { c in
            c.onStart = { name, attrs in
                if name == "Relationship", let id = attrs["Id"], let target = attrs["Target"] { rels[id] = target }
            }
        }
        return rels
    }

    static func parseSharedStrings(_ data: Data) -> [String] {
        var strings: [String] = []
        var current = ""
        var inText = false
        var inPhonetic = false
        parse(data) { c in
            c.onStart = { name, _ in
                switch name {
                case "si": current = ""
                case "t": inText = true
                case "rPh": inPhonetic = true
                default: break
                }
            }
            c.onEnd = { name in
                switch name {
                case "si": strings.append(current)
                case "t": inText = false
                case "rPh": inPhonetic = false
                default: break
                }
            }
            c.onText = { text in if inText && !inPhonetic { current += text } }
        }
        return strings
    }

    /// Indexes into `cellXfs` whose number format is a date/time format.
    static func parseDateStyles(_ data: Data) -> Set<Int> {
        var customDateFormats: Set<Int> = []
        var dateStyles: Set<Int> = []
        var inCellXfs = false
        var xfIndex = 0
        parse(data) { c in
            c.onStart = { name, attrs in
                if name == "numFmt", let id = attrs["numFmtId"].flatMap(Int.init), let code = attrs["formatCode"] {
                    let stripped = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression).lowercased()
                    if stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && stripped.contains("h")) || stripped.contains("h:") {
                        customDateFormats.insert(id)
                    }
                } else if name == "cellXfs" {
                    inCellXfs = true
                    xfIndex = 0
                } else if name == "xf", inCellXfs {
                    let id = attrs["numFmtId"].flatMap(Int.init) ?? 0
                    if (14...22).contains(id) || (45...47).contains(id) || customDateFormats.contains(id) { dateStyles.insert(xfIndex) }
                    xfIndex += 1
                }
            }
            c.onEnd = { name in if name == "cellXfs" { inCellXfs = false } }
        }
        return dateStyles
    }

    static func parseWorksheet(_ data: Data, shared: [String], dateStyles: Set<Int>, date1904: Bool) -> [[String]] {
        var rows: [Int: [Int: String]] = [:]
        var rowIndex = 0
        var cellRef = ""
        var cellType = ""
        var cellStyle = 0
        var value = ""
        var inValue = false
        var inInline = false
        var nextColumn = 0
        parse(data) { c in
            c.onStart = { name, attrs in
                switch name {
                case "row":
                    rowIndex = attrs["r"].flatMap(Int.init).map { $0 - 1 } ?? (rows.keys.max().map { $0 + 1 } ?? 0)
                    nextColumn = 0
                case "c":
                    cellRef = attrs["r"] ?? ""
                    cellType = attrs["t"] ?? "n"
                    cellStyle = attrs["s"].flatMap(Int.init) ?? 0
                    value = ""
                case "v":
                    inValue = true
                case "is":
                    inInline = true
                case "t" where inInline:
                    inValue = true
                default:
                    break
                }
            }
            c.onText = { text in if inValue { value += text } }
            c.onEnd = { name in
                switch name {
                case "v", "t":
                    inValue = false
                case "is":
                    inInline = false
                case "c":
                    let column = columnIndex(cellRef) ?? nextColumn
                    nextColumn = column + 1
                    let text: String
                    switch cellType {
                    case "s": text = Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                    case "b": text = value == "1" ? "true" : "false"
                    case "e": text = ""
                    case "str", "inlineStr": text = value
                    default:
                        if dateStyles.contains(cellStyle), let serial = Double(value) {
                            text = excelDate(serial, date1904: date1904)
                        } else {
                            text = value
                        }
                    }
                    if !text.isEmpty { rows[rowIndex, default: [:]][column] = text }
                default:
                    break
                }
            }
        }
        guard let lastRow = rows.keys.max() else { return [] }
        let width = (rows.values.flatMap(\.keys).max() ?? -1) + 1
        return (0...lastRow).map { r in (0..<width).map { rows[r]?[$0] ?? "" } }
    }

    static func columnIndex(_ ref: String) -> Int? {
        let letters = ref.prefix { $0.isLetter }.uppercased()
        guard !letters.isEmpty else { return nil }
        return letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    /// Excel serial dates count days from 1899-12-30 (or 1904-01-01); a fraction is the time of day.
    static func excelDate(_ serial: Double, date1904: Bool) -> String {
        let epoch = date1904 ? -24_107.0 : -25_569.0
        let seconds = (serial + epoch) * 86_400
        let date = Date(timeIntervalSince1970: seconds.rounded())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        if serial == serial.rounded() { return day }
        return day + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
