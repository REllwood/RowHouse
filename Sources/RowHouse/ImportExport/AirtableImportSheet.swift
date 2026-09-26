import RowHouseCore
import SwiftUI

/// Imports a whole Airtable base (tables, fields, records, links and attachments) through
/// Airtable's API using a personal access token. The token lives only in this sheet's state.
struct AirtableImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var state: WindowState

    @State private var token = ""
    @State private var importer: AirtableImporter?
    @State private var bases: [AirtableBaseSummary] = []
    @State private var basesLoaded = false
    @State private var selection: String?
    @State private var loadingBases = false
    @State private var importing = false
    @State private var status = ""
    @State private var fraction = 0.0
    @State private var errorMessage: String?
    @State private var finished: (name: String, report: ImportReport)?
    @State private var work: Task<Void, Never>?

    private static let tokenPage = URL(string: "https://airtable.com/create/tokens")!

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { loadingBases || importing }
    private var selectedBase: AirtableBaseSummary? { bases.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Airtable").font(.title2.bold())
            if let finished {
                summary(name: finished.name, report: finished.report)
            } else {
                instructions
                tokenRow
                if basesLoaded { baseList }
                if importing { progressSection }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                footer
            }
        }
        .padding(24)
        .frame(width: 600)
        .onChange(of: token) { _, _ in
            guard !busy else { return }
            importer = nil
            bases = []
            basesLoaded = false
            selection = nil
        }
        .onDisappear { work?.cancel() }
    }

    // MARK: - Sections

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RowHouse copies a base's tables, fields, records, links and attachments using Airtable's API. You'll need a personal access token:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Create a token at airtable.com/create/tokens.")
                step(2, "Give it the scopes `schema.bases:read` and `data.records:read`.")
                step(3, "Under Access, add the bases you want to import.")
            }
            Link(destination: Self.tokenPage) {
                Label("Create a Token on airtable.com", systemImage: "arrow.up.right.square")
            }
        }
        .font(.callout)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Personal access token", text: $token, prompt: Text("Paste your personal access token"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                Button {
                    loadBases()
                } label: {
                    if loadingBases {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(basesLoaded ? "Reload" : "Load Bases")
                    }
                }
                .keyboardShortcut(basesLoaded ? nil : .defaultAction)
                .disabled(trimmedToken.isEmpty || busy)
            }
            Label("The token is used for this import only and is never saved.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var baseList: some View {
        if bases.isEmpty {
            Text("This token can't see any bases. On airtable.com, add bases to the token's Access list, then load again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a base").font(.headline)
                List(bases, selection: $selection) { base in
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3.fill")
                            .foregroundStyle(.secondary)
                        Text(base.name).lineLimit(1)
                        Spacer()
                        Text(permissionName(base.permissionLevel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(base.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                    guard let id = ids.first else { return }
                    selection = id
                    startImport()
                })
                .frame(height: 200)
                .disabled(busy)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: fraction)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
            Button {
                startImport()
            } label: {
                if importing { ProgressView().controlSize(.small) } else { Text("Import") }
            }
            .keyboardShortcut(basesLoaded ? .defaultAction : nil)
            .disabled(selectedBase == nil || busy)
        }
    }

    private func summary(name: String, report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Imported “\(name)”: \(counted(report.tables, "table")), \(counted(report.records, "record")) and \(counted(report.attachments, "attachment")).", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            Text("A few things came across differently:").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text(warning).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func loadBases() {
        let key = trimmedToken
        guard !key.isEmpty, !busy else { return }
        errorMessage = nil
        loadingBases = true
        let client = AirtableImporter(token: key)
        work = Task {
            do {
                let list = try await client.listBases()
                importer = client
                bases = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if !bases.contains(where: { $0.id == selection }) {
                    selection = bases.count == 1 ? bases[0].id : nil
                }
                basesLoaded = true
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            loadingBases = false
        }
    }

    private func startImport() {
        guard let base = selectedBase, let importer, !busy else { return }
        errorMessage = nil
        importing = true
        status = "Creating the base…"
        fraction = 0
        work = Task {
            var created: BaseSession?
            do {
                let session = try await app.createEmptyBase(name: base.name)
                created = session
                let report = try await importer.importBase(id: base.id, name: base.name, into: session.document, storage: session.storage) { text, value in
                    status = text
                    fraction = value
                }
                app.finishImport(session)
                if let first = session.document.tables.first {
                    state.destination = .table(base: session.id, table: first.id)
                }
                importing = false
                if report.warnings.isEmpty {
                    dismiss()
                } else {
                    finished = (base.name, report)
                }
            } catch {
                // A cancelled or failed import leaves an incomplete base behind; move it to the Trash.
                if let created { app.trashBase(created.id) }
                importing = false
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancel() {
        work?.cancel()
        dismiss()
    }

    // MARK: - Formatting

    private func permissionName(_ level: String) -> String {
        switch level {
        case "create": "Creator"
        case "edit": "Editor"
        case "comment": "Commenter"
        case "read": "Read only"
        case "none": "No access"
        default: level.capitalized
        }
    }

    private func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
