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
                    .frame(width: Theme.panelWidth)
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
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { state.toggleViewsList() }
                } label: {
                    Label("Views", systemImage: "rectangle.leadinghalf.inset.filled")
                }
                .help("Show or hide the views list")
            }
            ToolbarItem(placement: .automatic) {
                TableDetailsButton(document: document, tableID: tableID)
            }
            ToolbarItemGroup(placement: .automatic) {
                if let type = view?.type, type != .form && type != .chart && type != .dashboard {
                    let templates = document.table(tableID)?.recordTemplates ?? []
                    if templates.isEmpty || view?.type != .grid {
                        Button {
                            commandTarget.addRecord()
                        } label: {
                            Label("Add Record", systemImage: "plus")
                        }
                        .help("Add a record (⇧↩ in the grid)")
                    } else {
                        Menu {
                            Button("Blank Record") { commandTarget.addRecord() }
                            Section("Templates") {
                                ForEach(templates) { template in
                                    Button(template.name) { commandTarget.addRecordFromTemplate(template) }
                                }
                            }
                            Menu("Delete Template") {
                                ForEach(templates) { template in
                                    Button(template.name, role: .destructive) {
                                        document.setTemplates(templates.filter { $0.id != template.id }, in: tableID)
                                    }
                                }
                            }
                        } label: {
                            Label("Add Record", systemImage: "plus")
                        } primaryAction: {
                            commandTarget.addRecord()
                        }
                        .help("Add a record — hold for templates (⇧↩ in the grid)")
                    }
                }
            }
        }
        .searchable(text: Binding(get: { state.search[tableID] ?? "" }, set: { state.search[tableID] = $0 }), placement: .toolbar, prompt: "Search records")
        .modifier(SearchFocusModifier(focused: $searchFocused))
        .focusedSceneValue(\.gridActions, commandTarget)
        .onAppear {
            commandTarget.focusSearch = { searchFocused = true }
            commandTarget.exportCSV = { if let view { exportCSV(view) } }
            commandTarget.printView = { if let view { printView(view) } }
        }
        .onChange(of: view?.id) { _, _ in
            commandTarget.exportCSV = { if let v = state.currentView(for: tableID, in: document) { exportCSV(v) } }
            commandTarget.printView = { if let v = state.currentView(for: tableID, in: document) { printView(v) } }
        }
    }

    private var subtitle: String {
        let count = document.recordCount(in: tableID)
        return "\(document.info.name) · \(count) record\(count == 1 ? "" : "s")"
    }

    private func printView(_ view: ViewModel) {
        let current = document.view(view.id) ?? view
        Printing.print(html: document.exportHTML(view: current, collapsed: state.collapsedGroups[view.id] ?? []),
                       title: "\(document.table(tableID)?.name ?? "Table") - \(current.name)")
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

/// Opens the table's name and description editor.
private struct TableDetailsButton: View {
    let document: BaseDocument
    let tableID: String
    @State private var editing = false

    var body: some View {
        let description = document.table(tableID)?.description ?? ""
        Button {
            editing = true
        } label: {
            Label("Table Details", systemImage: "info.circle")
        }
        .help(description.isEmpty ? "Rename the table or add a description" : description)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
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
        VStack(alignment: .leading, spacing: 8) {
            PanelHeading(title: "Name")
            TextField("Table name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if name != document.table(tableID)?.name { document.renameTable(tableID, to: name) } }
            PanelHeading(title: "Description")
                .padding(.top, 4)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            Text("\(document.recordCount(in: tableID)) records · \(document.fields(in: tableID).count) fields · \(document.views(in: tableID).count) views")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
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
        case .list:
            ListView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .kanban:
            KanbanView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .calendar:
            CalendarView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .gallery:
            GalleryView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .timeline:
            RoadmapView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .gantt:
            GanttView(session: session, view: view, state: state, commandTarget: commandTarget)
        case .form:
            FormView(session: session, view: view, state: state)
        case .chart:
            ChartView(session: session, view: view, state: state)
        case .dashboard:
            DashboardView(session: session, view: view, state: state)
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
