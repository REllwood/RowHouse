import RowHouseCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    var state: WindowState
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var confirmDelete: DeleteTarget?
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "RowHouse.sidebar.collapsed") ?? [])

    var body: some View {
        List(selection: Binding(get: { state.destination }, set: { if let v = $0 { state.destination = v } })) {
            ForEach(app.orderedSessions) { session in
                Section(isExpanded: expandedBinding(session.id)) {
                    BaseSectionRows(session: session, state: state, renaming: $renaming, renameText: $renameText, confirmDelete: $confirmDelete)
                } header: {
                    BaseHeader(session: session)
                        .contextMenu { baseMenu(session) }
                }
            }
            ForEach(app.library.entries.filter { app.loading.contains($0.baseID) && app.session($0.baseID) == nil }) { entry in
                Label {
                    Text(entry.initialName).foregroundStyle(.secondary)
                } icon: {
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(Array(app.loadErrors.keys), id: \.self) { id in
                Label("Couldn't open a base", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(app.loadErrors[id] ?? "")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(state: state)
        }
        .alert(renaming?.title ?? "Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(confirmDelete?.title ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(confirmDelete?.button ?? "Delete", role: .destructive) { performDelete() }
        } message: {
            Text(confirmDelete?.message ?? "")
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) }, set: { expanded in
            if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            UserDefaults.standard.set(Array(collapsed), forKey: "RowHouse.sidebar.collapsed")
        })
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
        Divider()
        Button("Show in Finder") { app.revealInFinder(session.id) }
        Divider()
        Button("Move Base to Trash…", role: .destructive) {
            confirmDelete = .base(session.id, session.document.info.name)
        }
    }

    private func commitRename() {
        guard let target = renaming else { return }
        switch target {
        case .base(let id):
            app.session(id)?.document.updateBaseInfo(name: renameText.trimmingCharacters(in: .whitespaces))
        case .table(let base, let table):
            app.session(base)?.document.renameTable(table, to: renameText)
        }
        renaming = nil
    }

    private func performDelete() {
        guard let target = confirmDelete else { return }
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
        confirmDelete = nil
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
        HStack(spacing: 7) {
            Image(systemName: info.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(info.color.swiftUI.gradient))
            Text(info.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
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
            HStack {
                Label(table.name, systemImage: "tablecells")
                Spacer()
                Text("\(doc.recordCount(in: table.id))")
                    .font(.caption)
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
        HStack {
            Label("Automations", systemImage: "bolt.fill")
            Spacer()
            if enabled > 0 {
                Text("\(enabled)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("New Base…") { state.newBaseSheet = true }
                    Button("Import CSV…") { state.csvImportSheet = true }
                    Button("Import from Airtable…") { state.airtableImportSheet = true }
                } label: {
                    Label("New Base", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                SyncStatus()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct SyncStatus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let inCloud = app.library.isInICloudDrive
        Label(inCloud ? "iCloud Drive" : "On this Mac", systemImage: inCloud ? "icloud" : "internaldrive")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .help(app.library.rootURL.path)
    }
}
