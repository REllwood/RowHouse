import RowHouseCore
import SwiftUI
import UniformTypeIdentifiers

struct TableScreen: View {
    @Environment(AppModel.self) private var app
    let session: BaseSession
    let tableID: String
    var state: WindowState
    @State private var commandTarget = GridCommandTarget()
    @FocusState private var searchFocused: Bool

    private var document: BaseDocument { session.document }

    var body: some View {
        let view = state.currentView(for: tableID, in: document)
        HStack(spacing: 0) {
            if state.showViewsList {
                ViewsListPanel(document: document, tableID: tableID, state: state)
                    .frame(width: 230)
                Divider()
            }
            VStack(spacing: 0) {
                if let view {
                    ViewBar(document: document, view: view, state: state)
                    Divider()
                    ViewContent(session: session, view: view, state: state, commandTarget: commandTarget)
                        .id(view.id)
                } else {
                    ContentUnavailableView("No views", systemImage: "tablecells")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.table(tableID)?.name ?? "")
        .navigationSubtitle(document.info.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { state.toggleViewsList() }
                } label: {
                    Label("Views", systemImage: "rectangle.leadinghalf.inset.filled")
                }
                .help("Show or hide the views list")
            }
            ToolbarItem(placement: .navigation) {
                TableTitle(document: document, tableID: tableID)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if view?.type != .form && view?.type != .chart {
                    Button {
                        commandTarget.addRecord()
                    } label: {
                        Label("Add Record", systemImage: "plus")
                    }
                    .help("Add a record (⇧↩ in the grid)")
                }
            }
        }
        .searchable(text: Binding(get: { state.search[tableID] ?? "" }, set: { state.search[tableID] = $0 }), placement: .toolbar, prompt: "Search records")
        .modifier(SearchFocusModifier(focused: $searchFocused))
        .focusedSceneValue(\.gridActions, commandTarget)
        .onAppear {
            commandTarget.focusSearch = { searchFocused = true }
            commandTarget.exportCSV = { if let view { exportCSV(view) } }
        }
        .onChange(of: view?.id) { _, _ in
            commandTarget.exportCSV = { if let v = state.currentView(for: tableID, in: document) { exportCSV(v) } }
        }
    }

    private func exportCSV(_ view: ViewModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(document.table(tableID)?.name ?? "Table") - \(view.name).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(document.exportCSV(view: view).utf8).write(to: url, options: .atomic)
        } catch {
            app.alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}

private struct TableTitle: View {
    let document: BaseDocument
    let tableID: String
    @State private var editingDescription = false

    var body: some View {
        let table = document.table(tableID)
        Button {
            editingDescription = true
        } label: {
            HStack(spacing: 6) {
                Text(table?.name ?? "").font(.headline)
                Text("\(document.recordCount(in: tableID)) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(table?.description.isEmpty == false ? table!.description : "Add a table description")
        .popover(isPresented: $editingDescription) {
            TableDescriptionEditor(document: document, tableID: tableID)
        }
    }
}

private struct TableDescriptionEditor: View {
    let document: BaseDocument
    let tableID: String
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Table name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .onSubmit { if name != document.table(tableID)?.name { document.renameTable(tableID, to: name) } }
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(14)
        .onAppear {
            name = document.table(tableID)?.name ?? ""
            text = document.table(tableID)?.description ?? ""
        }
        .onDisappear {
            if name.trimmingCharacters(in: .whitespacesAndNewlines) != document.table(tableID)?.name { document.renameTable(tableID, to: name) }
            if text != document.table(tableID)?.description { document.updateTableDescription(tableID, text) }
        }
    }
}

/// Routes to the right view renderer.
struct ViewContent: View {
    let session: BaseSession
    let view: ViewModel
    var state: WindowState
    let commandTarget: GridCommandTarget

    var body: some View {
        switch view.type {
        case .grid:
            GridContainer(session: session, view: view, state: state, commandTarget: commandTarget)
        case .kanban:
            KanbanView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .calendar:
            CalendarView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .gallery:
            GalleryView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .timeline:
            RoadmapView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .form:
            FormView(session: session, view: view, state: state)
        case .chart:
            ChartView(session: session, view: view, state: state)
        }
    }
}

/// `searchFocused` needs macOS 15; on 14 the search field is still reachable by clicking it.
private struct SearchFocusModifier: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}
