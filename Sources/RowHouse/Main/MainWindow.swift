import RowHouseCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    @State private var state = WindowState()
    @State private var pendingLink: URL?

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 360)
        } detail: {
            DetailRouter(state: state)
        }
        .focusedSceneValue(\.windowState, state)
        .sheet(isPresented: $state.newBaseSheet) {
            NewBaseSheet(state: state)
        }
        .sheet(isPresented: $state.csvImportSheet) {
            CSVImportSheet(state: state)
        }
        .sheet(isPresented: $state.airtableImportSheet) {
            AirtableImportSheet(state: state)
        }
        .sheet(item: $state.expandedRecord) { expanded in
            if let session = app.session(expanded.baseID) {
                RecordDetailSheet(session: session, expanded: expanded, state: state)
            }
        }
        .alert(item: Binding(get: { app.alert }, set: { app.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .onChange(of: app.library.entries) { _, _ in
            app.syncSessions()
        }
        .onChange(of: app.sessions.count, initial: true) { _, _ in
            attachUndoManager()
            ensureDestination()
            if let link = pendingLink, app.loading.isEmpty {
                pendingLink = nil
                handleDeepLink(link)
            }
        }
        .onChange(of: undoManager, initial: true) { _, _ in attachUndoManager() }
        .onChange(of: activeState) { _, new in
            // Documents have one undo manager; hand it to whichever window is in front.
            if new == .key { attachUndoManager() }
        }
        .onOpenURL { url in handleDeepLink(url) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onAppear {
            let open = openWindow
            StatusItemController.shared.openMainWindow = { open(id: "main") }
        }
    }

    private func attachUndoManager() {
        guard let undoManager else { return }
        for session in app.sessions.values where session.document.undoManager !== undoManager {
            session.document.undoManager = undoManager
        }
    }

    private func ensureDestination() {
        if let dest = state.destination, let session = app.session(dest.baseID) {
            if case .table(_, let t) = dest, session.document.table(t) == nil, let first = session.document.tables.first {
                state.destination = .table(base: session.id, table: first.id)
            }
            return
        }
        if let dest = state.destination, app.loading.contains(dest.baseID) { return }
        if let first = app.orderedSessions.first, let table = first.document.tables.first {
            state.destination = .table(base: first.id, table: table.id)
        } else if app.orderedSessions.isEmpty && app.loading.isEmpty {
            state.destination = nil
        }
    }

    /// rowhouse://record?base=…&table=…&record=…, rowhouse://open?base=…&table=…&view=…
    /// and rowhouse://automations?base=…
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "rowhouse", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let base = q["base"] else { return }
        guard let session = app.session(base) else {
            // The link may have launched the app; replay it once the bases have opened.
            if !app.loading.isEmpty || app.sessions.isEmpty { pendingLink = url }
            return
        }
        if url.host == "automations" {
            state.destination = .automations(base: base)
            return
        }
        let table = q["table"] ?? session.document.tables.first?.id
        if let table { state.destination = .table(base: base, table: table) }
        if let table, let view = q["view"], session.document.view(view) != nil { state.viewForTable[table] = view }
        if let record = q["record"], session.document.record(record) != nil {
            state.expandedRecord = ExpandedRecord(baseID: base, recordID: record)
        }
    }
}

struct DetailRouter: View {
    @Environment(AppModel.self) private var app
    var state: WindowState

    var body: some View {
        if let dest = state.destination, let session = app.session(dest.baseID) {
            switch dest {
            case .table(_, let tableID):
                if session.document.table(tableID) != nil {
                    TableScreen(session: session, tableID: tableID, state: state)
                        .id(tableID)
                } else {
                    ContentUnavailableView("Table not found", systemImage: "tablecells", description: Text("It may have been deleted on another Mac."))
                }
            case .automations:
                if let engine = app.engine(session.id) {
                    AutomationsScreen(session: session, engine: engine, state: state)
                        .id(session.id)
                } else {
                    ProgressView()
                }
            }
        } else if !app.loading.isEmpty {
            ProgressView("Opening bases…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if app.library.entries.isEmpty {
            WelcomeView(state: state)
        } else {
            ContentUnavailableView("Choose a table", systemImage: "sidebar.left", description: Text("Pick a table from the sidebar."))
        }
    }
}
