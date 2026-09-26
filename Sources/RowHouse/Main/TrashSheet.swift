import RowHouseCore
import SwiftUI

/// Everything deleted in a base, with restore. Deletions are kept (as tombstones) on every Mac.
struct TrashSheet: View {
    let session: BaseSession
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var kind: TrashItem.Kind?
    @State private var confirmEmpty = false

    var body: some View {
        let document = session.document
        let items = document.trashItems().filter { item in
            (kind == nil || item.kind == kind) && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.location.localizedCaseInsensitiveContains(search))
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash").font(.title2.bold())
                    Text("Restore anything deleted in \(document.info.name), from any of your Macs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("", selection: $kind) {
                    Text("Everything").tag(TrashItem.Kind?.none)
                    ForEach(TrashItem.Kind.allCases, id: \.self) { Text($0.displayName + "s").tag(TrashItem.Kind?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Erase Deleted Records…", role: .destructive) { confirmEmpty = true }
                    .disabled(!items.contains { $0.kind == .record || $0.kind == .comment })
            }
            if items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "trash", description: Text("Deleted tables, fields, views, records, automations and comments show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: icon(item.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? "Untitled" : item.title).lineLimit(1)
                            Text("\(item.kind.displayName) in \(item.location) · deleted \(item.deletedAt.formatted(.relative(presentation: .named))) on \(item.deletedBy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Restore") { document.restore(item) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
        .confirmationDialog("Erase deleted records?", isPresented: $confirmEmpty) {
            Button("Erase", role: .destructive) {
                document.emptyTrash(document.trashItems().filter { $0.kind == .record || $0.kind == .comment })
            }
        } message: {
            Text("The contents of deleted records and comments are erased on every Mac. Tables, fields and automations stay restorable.")
        }
    }

    private func icon(_ kind: TrashItem.Kind) -> String {
        switch kind {
        case .table: "tablecells"
        case .field: "textformat"
        case .view: "rectangle.stack"
        case .record: "doc.text"
        case .automation: "bolt"
        case .comment: "text.bubble"
        }
    }
}

/// Find and replace text across a table (or just the current view's records).
struct FindReplaceSheet: View {
    let session: BaseSession
    let tableID: String
    let viewRecordIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var find = ""
    @State private var replacement = ""
    @State private var matchCase = false
    @State private var wholeCell = false
    @State private var onlyView = true
    @State private var fieldIDs: Set<String> = []
    @State private var result: String?

    var body: some View {
        let document = session.document
        let candidates = document.fields(in: tableID).filter { BaseDocument.findReplaceTypes.contains($0.type) }
        let recordIDs = onlyView ? viewRecordIDs : document.records(in: tableID).map(\.id)
        let options = FindReplaceOptions(find: find, replacement: replacement, matchCase: matchCase, wholeCell: wholeCell)
        let selected = fieldIDs.isEmpty ? candidates.map(\.id) : Array(fieldIDs)
        let matches = document.countMatches(options, recordIDs: recordIDs, fieldIDs: selected)
        VStack(alignment: .leading, spacing: 14) {
            Text("Find and Replace").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Find").foregroundStyle(.secondary)
                    TextField("Text to find", text: $find).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Replace with").foregroundStyle(.secondary)
                    TextField("Replacement", text: $replacement).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 16) {
                Toggle("Match case", isOn: $matchCase)
                Toggle("Whole cell", isOn: $wholeCell)
                Toggle("Only records in this view", isOn: $onlyView)
            }
            .toggleStyle(.checkbox)
            Menu {
                Button("All text fields") { fieldIDs = [] }
                Divider()
                ForEach(candidates) { f in
                    Button {
                        if fieldIDs.contains(f.id) { fieldIDs.remove(f.id) } else { fieldIDs.insert(f.id) }
                    } label: {
                        Label(f.name, systemImage: fieldIDs.contains(f.id) ? "checkmark" : f.type.symbolName)
                    }
                }
            } label: {
                Text(fieldIDs.isEmpty ? "In all text fields" : "In \(candidates.filter { fieldIDs.contains($0.id) }.map(\.name).joined(separator: ", "))")
            }
            .fixedSize()
            HStack {
                Text(find.isEmpty ? " " : "\(matches) matching cell\(matches == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let result { Text(result).font(.callout).foregroundStyle(.green) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace All") {
                    let n = document.replaceAll(options, recordIDs: recordIDs, fieldIDs: selected)
                    result = "Replaced in \(n) cell\(n == 1 ? "" : "s")"
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(find.isEmpty || matches == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Run a script against a base, like Airtable's Scripting extension.
struct ScriptConsoleSheet: View {
    let session: BaseSession
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var running = false
    @State private var result: ScriptResult?

    private var storageKey: String { "RowHouse.scriptConsole.\(session.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run a script").font(.title2.bold())
                    Text("JavaScript with the same API as automation scripts: base, table.selectRecordsAsync(), createRecordAsync(), updateRecordAsync(), fetch(), output.set(). Changes can be undone with ⌘Z.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            TextEditor(text: $source)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                .frame(minHeight: 220)
            VStack(alignment: .leading, spacing: 6) {
                Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    Text(outputText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(result?.error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    run()
                } label: {
                    if running { ProgressView().controlSize(.small) } else { Label("Run", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(running || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .onAppear {
            let first = session.document.tables.first?.name ?? "Table 1"
            source = UserDefaults.standard.string(forKey: storageKey) ?? """
            const table = base.getTable("\(first)");
            const query = await table.selectRecordsAsync();
            console.log(`${query.records.length} records in ${table.name}`);
            for (const record of query.records.slice(0, 5)) {
              console.log(record.name);
            }
            """
        }
    }

    private var outputText: String {
        guard let result else { return "Press ⌘↩ to run." }
        var lines = result.logs
        for (k, v) in result.output.sorted(by: { $0.key < $1.key }) { lines.append("output.\(k) = \(v.jsonString)") }
        if let error = result.error { lines.append("Error: \(error)") }
        return lines.isEmpty ? "Finished with no output." : lines.joined(separator: "\n")
    }

    private func run() {
        UserDefaults.standard.set(source, forKey: storageKey)
        running = true
        Task {
            result = await ScriptRunner.run(source: source, inputs: [:], document: session.document, origin: .local)
            running = false
        }
    }
}

/// Search every table in a base at once.
struct BaseSearchSheet: View {
    let session: BaseSession
    var state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let document = session.document
        let hits = document.search(query)
        let grouped = Dictionary(grouping: hits, by: \.tableID)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search \(document.info.name)", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit { if let first = hits.first { open(first) } }
            if query.isEmpty {
                Text("Find records in every table by any value.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(document.tables.filter { grouped[$0.id] != nil }) { table in
                        Section("\(table.name) · \(grouped[table.id]?.count ?? 0)") {
                            ForEach(grouped[table.id] ?? []) { hit in
                                Button {
                                    open(hit)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title).font(.body.weight(.medium))
                                        Text("\(hit.fieldName): \(hit.excerpt)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            HStack {
                Text(hits.count >= 200 ? "Showing the first 200 matches" : "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear { focused = true }
    }

    private func open(_ hit: BaseSearchHit) {
        dismiss()
        state.destination = .table(base: session.id, table: hit.tableID)
        let siblings = session.document.records(in: hit.tableID).map(\.id)
        DispatchQueue.main.async {
            state.expandedRecord = ExpandedRecord(baseID: session.id, recordID: hit.recordID, siblings: siblings)
        }
    }
}
