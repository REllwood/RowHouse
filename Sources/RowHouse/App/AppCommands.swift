import RowHouseCore
import SwiftUI

struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

struct GridActionsKey: FocusedValueKey {
    typealias Value = GridCommandTarget
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }

    var gridActions: GridCommandTarget? {
        get { self[GridActionsKey.self] }
        set { self[GridActionsKey.self] = newValue }
    }
}

/// Actions the menu bar can trigger on the table currently on screen. The table screen sets the
/// table-wide ones (export, print, search); the view on screen owns the record commands.
@MainActor
final class GridCommandTarget {
    var addRecord: () -> Void = {}
    var addRecordFromTemplate: (RecordTemplate) -> Void = { _ in }
    var expandSelection: () -> Void = {}
    var deleteSelection: () -> Void = {}
    var exportCSV: () -> Void = {}
    var printView: () -> Void = {}
    var focusSearch: () -> Void = {}
    var addField: () -> Void = {}
    var fillDown: () -> Void = {}

    /// The view whose record commands these are.
    private(set) var recordCommandsOwner: String?

    /// Hands the record commands to a view, starting from none, so a view never runs commands another
    /// view left behind. A view with no record commands (form, chart, dashboard) claims them to turn
    /// them off.
    func claimRecordCommands(for viewID: String) {
        recordCommandsOwner = viewID
        addRecord = {}
        addRecordFromTemplate = { _ in }
        expandSelection = {}
        deleteSelection = {}
        addField = {}
        fillDown = {}
    }
}

extension View {
    /// Gives this view the menu's record commands while it is on screen. They are set up again whenever
    /// the view's configuration changes, so they never act on an old one (a calendar's old date field).
    func recordCommands(_ target: GridCommandTarget, for view: ViewModel, install: @escaping (GridCommandTarget) -> Void = { _ in }) -> some View {
        onAppear {
            target.claimRecordCommands(for: view.id)
            install(target)
        }
        .onChange(of: view) { _, current in
            target.claimRecordCommands(for: current.id)
            install(target)
        }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowState) private var window
    @FocusedValue(\.gridActions) private var grid
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Base…") { window?.newBaseSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("New Table") { newTable() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(currentBase == nil)
            Divider()
            Button("Import Spreadsheet (Excel or CSV)…") { window?.csvImportSheet = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("Import from Airtable…") { window?.airtableImportSheet = true }
                .disabled(window == nil)
            Button("Export View as CSV…") { grid?.exportCSV() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(grid == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print View…") { grid?.printView() }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(grid == nil)
        }
        CommandMenu("Record") {
            // ⇧↩ is handled by the grid itself so it doesn't steal newlines from text editors.
            Button("Add Record") { grid?.addRecord() }
                .disabled(grid == nil)
            Button("Expand Record") { grid?.expandSelection() }
                .disabled(grid == nil)
            // No shortcut: ⌘⌫ means "delete to start of line" while typing; the grid's own Delete key
            // handles selected rows when the grid has focus.
            Button("Delete Selected Records") { grid?.deleteSelection() }
                .disabled(grid == nil)
            Button("Fill Down") { grid?.fillDown() }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(grid == nil)
            Divider()
            Button("Add Field") { grid?.addField() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(grid == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Views List") { window?.toggleViewsList() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(window == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Records") { grid?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(grid == nil)
            Button("Search Base…") {
                MainActor.assumeIsolated {
                    if let base = window?.destination?.baseID { window?.searchBase = BaseSheetTarget(baseID: base) }
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(window?.destination == nil)
            Button("Find and Replace…") { findReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(currentTable == nil)
            Button("Find Duplicates…") { findDuplicates() }
                .disabled(currentTable == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { window?.showShortcuts = true }
                .keyboardShortcut("/", modifiers: [.command])
                .disabled(window == nil)
            Divider()
            Button("RowHouse on GitHub") { NSWorkspace.shared.open(AppInfo.repository) }
            Button("Formula Reference") { NSWorkspace.shared.open(URL(string: "https://github.com/REllwood/RowHouse#formulas")!) }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.check(.menu) }
        }
    }

    private var currentBase: BaseSession? {
        MainActor.assumeIsolated { AppModel.shared.session(window?.destination?.baseID) }
    }

    private var currentTable: (base: String, table: String)? {
        guard case .table(let base, let table)? = window?.destination else { return nil }
        return (base, table)
    }

    private func findReplace() {
        MainActor.assumeIsolated {
            guard let current = currentTable else { return }
            window?.findReplaceTable = BaseSheetTarget(baseID: current.base, tableID: current.table)
        }
    }

    private func findDuplicates() {
        MainActor.assumeIsolated {
            guard let current = currentTable else { return }
            window?.duplicatesTable = BaseSheetTarget(baseID: current.base, tableID: current.table)
        }
    }

    private func newTable() {
        MainActor.assumeIsolated {
            guard let window, let session = currentBase else { return }
            let id = session.document.createTable(name: "Table \(session.document.tables.count + 1)")
            window.destination = .table(base: session.id, table: id)
        }
    }
}
