import AppKit
import Observation
import RowHouseCore
import SwiftUI

/// App-wide state: the library of bases, their open sessions and automation engines.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let identity = DeviceIdentity.current
    let library: Library
    private(set) var sessions: [String: BaseSession] = [:]
    private(set) var engines: [String: AutomationEngine] = [:]
    private(set) var loading: Set<String> = []
    private(set) var loadErrors: [String: String] = [:]
    var alert: AppAlert?

    @ObservationIgnored private let services = SystemAutomationServices()

    private init() {
        library = Library()
        syncSessions()
    }

    var orderedSessions: [BaseSession] {
        library.entries.compactMap { sessions[$0.baseID] }
    }

    func session(_ baseID: String?) -> BaseSession? {
        guard let baseID else { return nil }
        return sessions[baseID]
    }

    /// The table to open first: the one with the most views (templates put their main table there).
    func mainTable(of baseID: String) -> TableModel? {
        guard let doc = session(baseID)?.document else { return nil }
        return doc.tables.max { doc.views(in: $0.id).count < doc.views(in: $1.id).count } ?? doc.tables.first
    }

    func engine(_ baseID: String?) -> AutomationEngine? {
        guard let baseID else { return nil }
        return engines[baseID]
    }

    /// Opens sessions for bases that appeared in the library and closes ones that disappeared.
    func syncSessions() {
        let entries = library.entries
        let live = Set(entries.map(\.baseID))
        for (id, session) in sessions where !live.contains(id) {
            engines[id]?.stop()
            engines[id] = nil
            session.close()
            sessions[id] = nil
        }
        for entry in entries where sessions[entry.baseID] == nil && !loading.contains(entry.baseID) {
            open(entry)
        }
    }

    private func open(_ entry: LibraryEntry, then: ((BaseSession) -> Void)? = nil) {
        loading.insert(entry.baseID)
        Task {
            do {
                let session = try await BaseSession.open(entry: entry, identity: identity)
                sessions[entry.baseID] = session
                loadErrors[entry.baseID] = nil
                then?(session)
                engines[entry.baseID] = AutomationEngine(session: session, services: services)
            } catch {
                loadErrors[entry.baseID] = error.localizedDescription
            }
            loading.remove(entry.baseID)
        }
    }

    /// Creates a base from a template and returns its id once it's open.
    func createBase(name: String, template: BaseTemplate) async -> String? {
        var createdID: String?
        defer { if let createdID { loading.remove(createdID) } }
        do {
            let entry = try library.createPackage(named: name)
            createdID = entry.baseID
            loading.insert(entry.baseID)
            let session = try await BaseSession.open(entry: entry, identity: identity)
            session.document.updateBaseInfo(name: name)
            session.document.apply(template: template, storage: session.storage)
            session.writeSnapshotNow()
            sessions[entry.baseID] = session
            engines[entry.baseID] = AutomationEngine(session: session, services: services)
            return entry.baseID
        } catch {
            alert = AppAlert(title: "Couldn't create the base", message: error.localizedDescription)
            return nil
        }
    }

    /// Creates an empty base (no tables) and returns its open session, for importers to fill.
    func createEmptyBase(name: String, icon: String = "square.grid.3x3.fill", color: ChoiceColor = .blue) async throws -> BaseSession {
        let entry = try library.createPackage(named: name)
        loading.insert(entry.baseID)
        defer { loading.remove(entry.baseID) }
        let session = try await BaseSession.open(entry: entry, identity: identity)
        let manager = session.document.undoManager
        session.document.undoManager = nil
        session.document.updateBaseInfo(name: name, icon: icon, color: color)
        session.document.undoManager = manager
        sessions[entry.baseID] = session
        return session
    }

    /// Starts automations for a base created by an importer, once it has been filled.
    func finishImport(_ session: BaseSession) {
        session.writeSnapshotNow()
        if engines[session.id] == nil {
            engines[session.id] = AutomationEngine(session: session, services: services)
        }
    }

    /// Creates a base holding one table imported from CSV.
    func createBase(fromCSV rows: [[String]], hasHeader: Bool, plan: [CSVColumnPlan], name: String) async -> String? {
        var createdID: String?
        defer { if let createdID { loading.remove(createdID) } }
        do {
            let entry = try library.createPackage(named: name)
            createdID = entry.baseID
            loading.insert(entry.baseID)
            let session = try await BaseSession.open(entry: entry, identity: identity)
            let doc = session.document
            let manager = doc.undoManager
            doc.undoManager = nil
            doc.updateBaseInfo(name: name, icon: "tablecells", color: .cyan)
            doc.importCSV(rows: rows, hasHeader: hasHeader, plan: plan, tableName: name)
            doc.undoManager = manager
            session.writeSnapshotNow()
            sessions[entry.baseID] = session
            engines[entry.baseID] = AutomationEngine(session: session, services: services)
            return entry.baseID
        } catch {
            alert = AppAlert(title: "Couldn't import the CSV", message: error.localizedDescription)
            return nil
        }
    }

    func trashBase(_ baseID: String) {
        guard let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        engines[baseID]?.stop()
        engines[baseID] = nil
        sessions[baseID]?.close()
        sessions[baseID] = nil
        do {
            try library.trash(entry)
        } catch {
            alert = AppAlert(title: "Couldn't move the base to the Trash", message: error.localizedDescription)
        }
        syncSessions()
    }

    /// Copies a base (with attachments) as a new base.
    func duplicateBase(_ baseID: String) async -> String? {
        guard let source = sessions[baseID], let entry = library.entries.first(where: { $0.baseID == baseID }) else { return nil }
        source.storage.flush()
        do {
            let name = source.document.info.name + " copy"
            let copy = try library.duplicate(entry, state: source.document.state, name: name, deviceID: identity.id)
            loading.insert(copy.baseID)
            defer { loading.remove(copy.baseID) }
            let session = try await BaseSession.open(entry: copy, identity: identity)
            let manager = session.document.undoManager
            session.document.undoManager = nil
            session.document.updateBaseInfo(name: name)
            // Automations in the copy start switched off so nothing fires twice.
            for automation in session.document.automations where automation.enabled {
                session.document.updateAutomation(automation.id) { $0.enabled = false }
            }
            session.document.undoManager = manager
            sessions[copy.baseID] = session
            engines[copy.baseID] = AutomationEngine(session: session, services: services)
            return copy.baseID
        } catch {
            alert = AppAlert(title: "Couldn't duplicate the base", message: error.localizedDescription)
            return nil
        }
    }

    func exportBackup(_ baseID: String) {
        guard let session = sessions[baseID], let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        session.writeSnapshotNow()
        session.storage.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(session.document.info.name) \(Date().formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Library.exportBackup(of: entry.url, to: url)
        } catch {
            alert = AppAlert(title: "Couldn't export the backup", message: error.localizedDescription)
        }
    }

    func importBackup() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a RowHouse backup (.zip)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let entry = try library.importBackup(from: url)
            loading.insert(entry.baseID)
            defer { loading.remove(entry.baseID) }
            let session = try await BaseSession.open(entry: entry, identity: identity)
            sessions[entry.baseID] = session
            engines[entry.baseID] = AutomationEngine(session: session, services: services)
            return entry.baseID
        } catch {
            alert = AppAlert(title: "Couldn't restore the backup", message: error.localizedDescription)
            return nil
        }
    }

    func revealInFinder(_ baseID: String) {
        guard let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func setStorageLocation(_ location: StorageLocation) {
        for id in Array(sessions.keys) {
            engines[id]?.stop()
            sessions[id]?.close()
        }
        engines.removeAll()
        sessions.removeAll()
        library.setLocation(location)
        syncSessions()
    }

    func closeAll() {
        for engine in engines.values { engine.stop() }
        for session in sessions.values { session.close() }
    }

    func pollAll() {
        for session in sessions.values { session.poll() }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Where the user is in one window.
enum Destination: Hashable, Codable {
    case table(base: String, table: String)
    case automations(base: String)

    var baseID: String {
        switch self {
        case .table(let b, _), .automations(let b): b
        }
    }
}

@MainActor
@Observable
final class WindowState {
    var destination: Destination? {
        didSet { persist() }
    }
    var viewForTable: [String: String] = [:] {
        didSet { persist() }
    }
    var search: [String: String] = [:]
    var expandedRecord: ExpandedRecord?
    var showViewsList = true
    var collapsedGroups: [String: Set<String>] = [:]
    var newBaseSheet = false
    var csvImportSheet = false
    var airtableImportSheet = false
    var trashBase: BaseSheetTarget?
    var scriptBase: BaseSheetTarget?
    var findReplaceTable: BaseSheetTarget?
    var duplicatesTable: BaseSheetTarget?
    var showShortcuts = false
    var searchBase: BaseSheetTarget?
    /// Values to pre-fill in a form view, from a rowhouse://form link (view id → field name → text).
    var formPrefill: [String: [String: String]] = [:]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "RowHouse.window.destination"), let dest = try? JSONDecoder().decode(Destination.self, from: data) {
            destination = dest
        }
        viewForTable = d.dictionary(forKey: "RowHouse.window.views") as? [String: String] ?? [:]
        showViewsList = d.object(forKey: "RowHouse.window.showViews") as? Bool ?? true
    }

    private func persist() {
        let d = UserDefaults.standard
        if let destination, let data = try? JSONEncoder().encode(destination) { d.set(data, forKey: "RowHouse.window.destination") }
        d.set(viewForTable, forKey: "RowHouse.window.views")
    }

    func toggleViewsList() {
        showViewsList.toggle()
        UserDefaults.standard.set(showViewsList, forKey: "RowHouse.window.showViews")
    }

    /// The view shown for a table: the remembered one if it still exists, else the first.
    func currentView(for tableID: String, in document: BaseDocument) -> ViewModel? {
        let views = document.views(in: tableID)
        if let id = viewForTable[tableID], let v = views.first(where: { $0.id == id }) { return v }
        return views.first
    }
}

struct BaseSheetTarget: Identifiable, Hashable {
    var baseID: String
    var tableID: String?
    var id: String { baseID + (tableID ?? "") }
}

struct ExpandedRecord: Identifiable, Hashable {
    var baseID: String
    var recordID: String
    /// Records to step through with the previous/next buttons (the current view's order).
    var siblings: [String] = []
    var id: String { recordID }
}
