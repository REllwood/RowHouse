import RowHouseCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    var state: WindowState
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var confirmDelete: DeleteTarget?
    @State private var collaboratorsBase: String?

    var body: some View {
        List(selection: Binding(get: { state.destination }, set: { if let v = $0 { state.destination = v } })) {
            ForEach(app.orderedSessions) { session in
                Section {
                    BaseSectionRows(session: session, state: state, renaming: $renaming, renameText: $renameText, confirmDelete: $confirmDelete)
                } header: {
                    BaseHeader(session: session)
                        .contextMenu { baseMenu(session) }
                }
            }
            ForEach(app.library.entries.filter { app.session($0.baseID) == nil }) { entry in
                if case .failed(_, let message)? = app.bases[entry.baseID] {
                    Label("Could not open \(entry.initialName)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(message)
                } else {
                    Label {
                        Text(entry.initialName).foregroundStyle(.secondary)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Bases open after the list first appears, and sections added later start collapsed. Building
        // the list again when the set of open bases changes keeps every base expanded.
        .id(app.orderedSessions.map(\.id).joined(separator: ","))
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(state: state)
        }
        .appDialog(item: $renaming) { target in
            .prompt(target.title, placeholder: "Name", text: renameText, confirmTitle: "Rename")
        } onConfirm: { target, name in
            commitRename(target, to: name)
        }
        .appDialog(item: $confirmDelete) { target in
            .confirm(target.title, message: target.message, confirmTitle: target.button, destructive: true)
        } onConfirm: { target, _ in
            performDelete(target)
        }
        .sheet(isPresented: Binding(get: { collaboratorsBase != nil }, set: { if !$0 { collaboratorsBase = nil } })) {
            if let document = app.session(collaboratorsBase)?.document {
                CollaboratorsSheet(document: document)
            }
        }
    }

    @ViewBuilder
    private func baseMenu(_ session: BaseSession) -> some View {
        Button("Rename Base…") {
            renameText = session.document.info.name
            renaming = .base(session.id)
        }
        Menu("Icon Colour") {
            ForEach(ChoiceColor.allCases, id: \.self) { color in
                Button(color.displayName) { session.document.updateBaseInfo(color: color) }
            }
        }
        Button("New Table") {
            let id = session.document.createTable(name: "Table \(session.document.tables.count + 1)")
            state.destination = .table(base: session.id, table: id)
        }
        Button("Duplicate Base") {
            Task {
                if let id = await app.duplicateBase(session.id), let table = app.mainTable(of: id) {
                    state.destination = .table(base: id, table: table.id)
                }
            }
        }
        Button("Collaborators…") { collaboratorsBase = session.id }
        Divider()
        Button("Run Script…") { state.scriptBase = BaseSheetTarget(baseID: session.id) }
        Button("Trash…") { state.trashBase = BaseSheetTarget(baseID: session.id) }
        Divider()
        Button("Export Backup…") { app.exportBackup(session.id) }
        Button("Show in Finder") { app.revealInFinder(session.id) }
        Divider()
        Button("Move Base to Trash…", role: .destructive) {
            confirmDelete = .base(session.id, session.document.info.name)
        }
    }

    private func commitRename(_ target: RenameTarget, to name: String) {
        switch target {
        case .base(let id):
            app.session(id)?.document.updateBaseInfo(name: name.trimmingCharacters(in: .whitespaces))
        case .table(let base, let table):
            app.session(base)?.document.renameTable(table, to: name)
        }
    }

    private func performDelete(_ target: DeleteTarget) {
        switch target {
        case .base(let id, _):
            if state.destination?.baseID == id { state.destination = nil }
            app.trashBase(id)
        case .table(let base, let table, _):
            guard let doc = app.session(base)?.document else { return }
            if case .table(_, let current) = state.destination, current == table,
               let other = doc.tables.first(where: { $0.id != table }) {
                state.destination = .table(base: base, table: other.id)
            }
            doc.deleteTable(table)
        }
    }
}

enum RenameTarget {
    case base(String)
    case table(String, String)

    var title: String {
        switch self {
        case .base: "Rename Base"
        case .table: "Rename Table"
        }
    }
}

enum DeleteTarget {
    case base(String, String)
    case table(String, String, String)

    var title: String {
        switch self {
        case .base(_, let name): "Move “\(name)” to the Trash?"
        case .table(_, _, let name): "Delete the table “\(name)”?"
        }
    }

    var message: String {
        switch self {
        case .base: "The base folder is moved to the Trash on this Mac and removed from iCloud Drive on your other Macs. You can restore it from the Trash."
        case .table: "Its records, fields and views are removed. You can undo this with ⌘Z."
        }
    }

    var button: String {
        switch self {
        case .base: "Move to Trash"
        case .table: "Delete Table"
        }
    }
}

private struct BaseHeader: View {
    var session: BaseSession

    var body: some View {
        let info = session.document.info
        HStack(spacing: 8) {
            Image(systemName: info.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(info.color.swiftUI.gradient))
            Text(info.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
    }
}

private struct BaseSectionRows: View {
    var session: BaseSession
    var state: WindowState
    @Binding var renaming: RenameTarget?
    @Binding var renameText: String
    @Binding var confirmDelete: DeleteTarget?

    var body: some View {
        let doc = session.document
        ForEach(doc.tables) { table in
            HStack(spacing: 6) {
                Label {
                    Text(table.name).lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "tablecells").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(doc.recordCount(in: table.id))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .tag(Destination.table(base: session.id, table: table.id))
            .contextMenu {
                Button("Rename Table…") {
                    renameText = table.name
                    renaming = .table(session.id, table.id)
                }
                Button("Duplicate Table") { _ = doc.duplicateTable(table.id, includeRecords: true) }
                Button("Duplicate Structure Only") { _ = doc.duplicateTable(table.id, includeRecords: false) }
                Divider()
                Button("Delete Table…", role: .destructive) {
                    confirmDelete = .table(session.id, table.id, table.name)
                }
                .disabled(doc.tables.count <= 1)
            }
        }
        .onMove { indices, destination in
            let tables = doc.tables
            guard let from = indices.first else { return }
            let before = destination < tables.count ? tables[destination].id : nil
            doc.moveTable(tables[from].id, before: before)
        }
        let enabled = doc.automations.filter(\.enabled).count
        HStack(spacing: 6) {
            Label {
                Text("Automations")
            } icon: {
                Image(systemName: "bolt").foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if enabled > 0 {
                Text("\(enabled)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .tag(Destination.automations(base: session.id))
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app
    var state: WindowState

    var body: some View {
        VStack(spacing: 0) {
            UpdateAvailableButton()
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("New Base…") { state.newBaseSheet = true }
                    Button("Import CSV…") { state.csvImportSheet = true }
                    Button("Import from Airtable…") { state.airtableImportSheet = true }
                    Button("Restore Backup…") {
                        Task {
                            if let id = await app.importBackup(), let table = app.mainTable(of: id) {
                                state.destination = .table(base: id, table: table.id)
                            }
                        }
                    }
                } label: {
                    Label("New Base", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 8)
                SyncStatus()
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.barHeight)
        }
    }
}

/// Shown above the sidebar footer once an update check finds a newer version.
private struct UpdateAvailableButton: View {
    private let checker = UpdateChecker.shared
    @State private var hovering = false

    var body: some View {
        if let version = checker.availableVersion {
            Button {
                checker.offerUpdate()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
                            .font(.system(size: 12, weight: .semibold))
                        Text("RowHouse \(version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color.accentColor.opacity(hovering ? 0.16 : 0.10)))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("See what is new in RowHouse \(version) and download it")
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

private struct SyncStatus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let inCloud = app.library.isInICloudDrive
        Label(inCloud ? "iCloud Drive" : "On this Mac", systemImage: inCloud ? "icloud" : "internaldrive")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .help(app.library.rootURL.path)
    }
}
