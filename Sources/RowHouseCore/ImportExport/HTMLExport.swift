import Foundation

/// Printable HTML for a view or a single record (used for Print and Export PDF).
extension BaseDocument {
    public func exportHTML(view: ViewModel, collapsed: Set<String> = []) -> String {
        let fields = visibleFields(for: view)
        let tableName = table(view.tableID)?.name ?? "Table"
        let result = evaluate(view: view, collapsedGroups: collapsed)
        var html = Self.htmlHead(title: "\(tableName) — \(view.name)")
        html += "<h1>\(Self.escape(tableName))</h1><p class=\"sub\">\(Self.escape(info.name)) · \(Self.escape(view.name)) · \(result.recordIDs.count) record\(result.recordIDs.count == 1 ? "" : "s")</p>"
        html += "<table><thead><tr>" + fields.map { "<th>\(Self.escape($0.name))</th>" }.joined() + "</tr></thead><tbody>"
        for row in result.rows {
            switch row {
            case .group(let g):
                let indent = String(repeating: "&nbsp;&nbsp;&nbsp;", count: g.depth)
                let name = field(g.fieldID)?.name ?? ""
                html += "<tr class=\"group\"><td colspan=\"\(fields.count)\">\(indent)\(Self.escape(name)): <b>\(Self.escape(g.title.isEmpty ? "(Empty)" : g.title))</b> · \(g.count)</td></tr>"
            case .record(let id):
                guard let r = record(id) else { continue }
                html += "<tr>" + fields.map { "<td>\(Self.escape(displayString(r, $0)))</td>" }.joined() + "</tr>"
            }
        }
        html += "</tbody>"
        if let summaries = view.config.summaries, !summaries.isEmpty {
            html += "<tfoot><tr>" + fields.map { f in
                guard let fn = summaries[f.id] else { return "<td></td>" }
                return "<td>\(Self.escape(summary(fn, field: f, recordIDs: result.recordIDs)))</td>"
            }.joined() + "</tr></tfoot>"
        }
        return html + "</table></body></html>"
    }

    public func exportHTML(recordID: String) -> String {
        guard let r = record(recordID) else { return Self.htmlHead(title: "Record") + "</body></html>" }
        let title = primaryTitle(r)
        var html = Self.htmlHead(title: title)
        html += "<h1>\(Self.escape(title.isEmpty ? "Unnamed record" : title))</h1><p class=\"sub\">\(Self.escape(info.name)) · \(Self.escape(table(r.tableID)?.name ?? ""))</p><dl>"
        for f in fields(in: r.tableID) where f.id != table(r.tableID)?.primaryFieldID && f.type != .button {
            let text = displayString(r, f)
            html += "<dt>\(Self.escape(f.name))</dt><dd>\(text.isEmpty ? "<span class=\"empty\">—</span>" : Self.escape(text))</dd>"
        }
        html += "</dl>"
        let notes = comments(for: recordID)
        if !notes.isEmpty {
            html += "<h2>Comments</h2>"
            for c in notes {
                html += "<p><b>\(Self.escape(c.authorName))</b>: \(Self.escape(c.text))</p>"
            }
        }
        return html + "</body></html>"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "<br>"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func htmlHead(title: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { font: 10pt -apple-system, Helvetica, sans-serif; color: #1d1d1f; margin: 0; }
        h1 { font-size: 18pt; margin: 0 0 2pt; } h2 { font-size: 13pt; margin-top: 16pt; }
        .sub { color: #6e6e73; margin: 0 0 12pt; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 0.5pt solid #d2d2d7; padding: 3pt 5pt; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; font-weight: 600; }
        tr.group td { background: #eef3fb; }
        tfoot td { color: #6e6e73; font-weight: 600; }
        dt { font-weight: 600; color: #6e6e73; margin-top: 8pt; } dd { margin: 2pt 0 0; }
        .empty { color: #aeaeb2; }
        </style></head><body>
        """
    }
}
