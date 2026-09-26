import RowHouseCore
import SwiftUI
import UniformTypeIdentifiers

struct CSVImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var state: WindowState

    enum Destination: Hashable {
        case newBase, newTable, existingTable(String)
    }

    @State private var fileURL: URL?
    @State private var rows: [[String]] = []
    @State private var sheets: [XLSXReader.Sheet] = []
    @State private var sheetName = ""
    @State private var hasHeader = true
    @State private var plan: [CSVColumnPlan] = []
    @State private var destination: Destination = .newBase
    @State private var name = ""
    @State private var error: String?
    @State private var importing = false

    private var currentSession: BaseSession? { app.session(state.destination?.baseID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a spreadsheet").font(.title2.bold())
            if rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells.badge.ellipsis").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Choose an Excel workbook (.xlsx) or a CSV/TSV file exported from Airtable, Numbers or Google Sheets.")
                        .foregroundStyle(.secondary)
                    Button("Choose File…", action: pick).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                configure
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                if !rows.isEmpty {
                    Text("\(max(0, rows.count - (hasHeader ? 1 : 0))) rows · \(plan.filter(\.include).count) fields")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    runImport()
                } label: {
                    if importing { ProgressView().controlSize(.small) } else { Text("Import") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(rows.isEmpty || importing || plan.allSatisfy { !$0.include })
            }
        }
        .padding(24)
        .frame(width: 720)
    }

    private var configure: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(fileURL?.lastPathComponent ?? "", systemImage: "doc.text")
                Spacer()
                Button("Choose Another…", action: pick).controlSize(.small)
            }
            if sheets.count > 1 {
                Picker("Worksheet", selection: $sheetName) {
                    ForEach(sheets) { Text("\($0.name) (\(max(0, $0.rows.count - 1)) rows)").tag($0.name) }
                }
                .frame(maxWidth: 360)
                .onChange(of: sheetName) { _, name in
                    guard let sheet = sheets.first(where: { $0.name == name }) else { return }
                    load(rows: sheet.rows, name: name)
                }
            }
            Toggle("First row contains field names", isOn: $hasHeader)
                .onChange(of: hasHeader) { _, _ in plan = CSVImporter.plan(rows: rows, hasHeader: hasHeader) }
            Picker("Import into", selection: $destination) {
                Text("A new base").tag(Destination.newBase)
                if let session = currentSession {
                    Text("A new table in \(session.document.info.name)").tag(Destination.newTable)
                    ForEach(session.document.tables) { t in
                        Text("Existing table: \(t.name)").tag(Destination.existingTable(t.id))
                    }
                }
            }
            .onChange(of: destination) { _, new in autoMatch(new) }
            if case .existingTable = destination {} else {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            Text("Fields").font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($plan) { $column in
                        HStack {
                            Toggle("", isOn: $column.include).labelsHidden()
                            TextField("Name", text: $column.header).textFieldStyle(.roundedBorder).frame(width: 190)
                            if case .existingTable(let tableID) = destination, let doc = currentSession?.document {
                                Picker("", selection: Binding(get: { column.targetFieldID ?? "" }, set: { column.targetFieldID = $0.isEmpty ? nil : $0 })) {
                                    Text("New field").tag("")
                                    ForEach(doc.fields(in: tableID).filter(\.isEditable)) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden()
                                .frame(width: 180)
                            }
                            if column.targetFieldID == nil {
                                Picker("", selection: $column.type) {
                                    ForEach(FieldType.allCases.filter { !$0.isComputed && $0 != .attachment && $0 != .link }) { t in
                                        Label(t.displayName, systemImage: t.symbolName).tag(t)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                            }
                            Text(sample(column.index))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .opacity(column.include ? 1 : 0.5)
                    }
                }
            }
            .frame(height: 260)
        }
    }

    private func sample(_ index: Int) -> String {
        rows.dropFirst(hasHeader ? 1 : 0).prefix(3).compactMap { index < $0.count ? $0[index] : nil }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func pick() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.insert(xlsx, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            fileURL = url
            if url.pathExtension.lowercased() == "xlsx" {
                let workbook = try XLSXReader.read(url)
                sheets = workbook.filter { !$0.rows.isEmpty }
                guard let first = sheets.first else { throw CocoaError(.fileReadCorruptFile) }
                sheetName = first.name
                load(rows: first.rows, name: sheets.count > 1 ? first.name : url.deletingPathExtension().lastPathComponent)
            } else {
                sheets = []
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let parsed = CSV.parse(text, delimiter: url.pathExtension.lowercased() == "tsv" ? "\t" : nil)
                guard !parsed.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                load(rows: parsed, name: url.deletingPathExtension().lastPathComponent)
            }
            error = nil
        } catch {
            self.error = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    private func load(rows parsed: [[String]], name newName: String) {
        rows = parsed
        plan = CSVImporter.plan(rows: parsed, hasHeader: hasHeader)
        name = newName
        autoMatch(destination)
    }

    private func autoMatch(_ dest: Destination) {
        guard case .existingTable(let tableID) = dest, let doc = currentSession?.document else {
            for i in plan.indices { plan[i].targetFieldID = nil }
            return
        }
        for i in plan.indices {
            plan[i].targetFieldID = doc.field(named: plan[i].header, in: tableID).flatMap { $0.isEditable ? $0.id : nil }
        }
    }

    private func runImport() {
        importing = true
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported" : name
        Task {
            switch destination {
            case .newBase:
                if let id = await app.createBase(fromCSV: rows, hasHeader: hasHeader, plan: plan, name: finalName),
                   let table = app.session(id)?.document.tables.first {
                    state.destination = .table(base: id, table: table.id)
                }
            case .newTable:
                if let session = currentSession {
                    let id = session.document.importCSV(rows: rows, hasHeader: hasHeader, plan: plan, tableName: finalName)
                    state.destination = .table(base: session.id, table: id)
                }
            case .existingTable(let tableID):
                currentSession?.document.importCSV(rows: rows, hasHeader: hasHeader, plan: plan, into: tableID)
                if let session = currentSession { state.destination = .table(base: session.id, table: tableID) }
            }
            importing = false
            dismiss()
        }
    }
}
