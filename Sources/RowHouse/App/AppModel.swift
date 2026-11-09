import AppKit
import Observation
import RowHouseCore
import SwiftUI

/// Where one base in the library stands on this Mac.
@MainActor
enum BaseStatus {
    /// Its files are being read from this folder.
    case loading(URL)
    /// Open. The engine runs its automations; a base being filled by an importer has none yet.
    case open(BaseSession, engine: AutomationEngine?)
    /// Could not be read. Tried again whenever the library changes.
    case failed(URL, message: String)

    var url: URL {
        switch self {
        case .loading(let url), .failed(let url, _): url
        case .open(let session, _): session.storage.packageURL
        }
    }
}

/// App-wide state: the library of bases and where each one stands on this Mac.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let identity = DeviceIdentity.current
    let library: Library
    /// Every base this Mac is opening, has open or could not open, by base id. The one place a base's
    /// lifecycle is recorded: a base can only be in one of these states, and a base that leaves the
    /// library (trashed, moved, or a different storage location) leaves this too.
    private(set) var bases: [String: BaseStatus] = [:]

    @ObservationIgnored private let services = SystemAutomationServices()
    @ObservationIgnored private var mentionObservers: [String: UUID] = [:]

    private init() {
        library = Library()
        syncSessions()
    }

    var sessions: [String: BaseSession] {
        bases.compactMapValues { if case .open(let session, _) = $0 { session } else { nil } }
    }

    var engines: [String: AutomationEngine] {
        bases.compactMapValues { if case .open(_, let engine) = $0 { engine } else { nil } }
    }

    var loading: Set<String> {
        Set(bases.compactMap { if case .loading = $0.value { $0.key } else { nil } })
    }

    var orderedSessions: [BaseSession] {
        library.entries.compactMap { session($0.baseID) }
    }

    func session(_ baseID: String?) -> BaseSession? {
        guard let baseID, case .open(let session, _)? = bases[baseID] else { return nil }
        return session
    }

    /// The table to open first: the one with the most views (templates put their main table there).
    func mainTable(of baseID: String) -> TableModel? {
        guard let doc = session(baseID)?.document else { return nil }
        return doc.tables.max { doc.views(in: $0.id).count < doc.views(in: $1.id).count } ?? doc.tables.first
    }

    func engine(_ baseID: String?) -> AutomationEngine? {
        guard let baseID, case .open(_, let engine)? = bases[baseID] else { return nil }
        return engine
    }

    /// Reports a failure over the window being worked in, after any sheet in front of it has closed.
    func showAlert(title: String, message: String) {
        AppDialogPresenter.present(.failure(title, message: message), over: NSApp.mainWindow)
    }

    /// Opens bases that appeared in the library (or failed before), closes ones that left it, and
    /// reopens ones that moved, such as a base renamed in Finder.
    func syncSessions() {
        let entries = Dictionary(library.entries.map { ($0.baseID, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, status) in bases {
            guard let entry = entries[id], entry.url.standardizedFileURL == status.url.standardizedFileURL else {
                close(id)
                continue
            }
        }
        for entry in library.entries {
            switch bases[entry.baseID] {
            case nil, .failed?: open(entry)
            case .loading?, .open?: break
            }
        }
    }

    private func open(_ entry: LibraryEntry) {
        bases[entry.baseID] = .loading(entry.url)
        Task {
            do {
                install(try await BaseSession.open(entry: entry, identity: identity), from: entry)
            } catch {
                guard isLoading(entry) else { return }
                bases[entry.baseID] = .failed(entry.url, message: error.localizedDescription)
            }
        }
    }

    private func isLoading(_ entry: LibraryEntry) -> Bool {
        if case .loading(let url)? = bases[entry.baseID] { return url == entry.url }
        return false
    }

    /// Puts a session that has finished opening in place, unless its base was closed, trashed or moved
    /// meanwhile, in which case the session is closed so it never runs automations or writes unseen.
    @discardableResult
    private func install(_ session: BaseSession, from entry: LibraryEntry, startingServices: Bool = true) -> Bool {
        guard isLoading(entry) else {
            session.close()
            return false
        }
        bases[entry.baseID] = .open(session, engine: nil)
        if startingServices { startServices(for: session) }
        return true
    }

    /// Forgets a base that was being opened by hand, after that failed.
    private func abandon(_ entry: LibraryEntry) {
        if isLoading(entry) { bases[entry.baseID] = nil }
    }

    private func close(_ baseID: String) {
        if case .open(let session, let engine)? = bases[baseID] {
            engine?.stop()
            if let observer = mentionObservers.removeValue(forKey: baseID) { session.document.removeObserver(observer) }
            session.close()
        }
        bases[baseID] = nil
    }

    /// Starts a base's automations and watches for comments that @mention you from other Macs.
    private func startServices(for session: BaseSession) {
        guard case .open(let open, nil)? = bases[session.id], open === session else { return }
        bases[session.id] = .open(session, engine: AutomationEngine(session: session, services: services))
        session.document.currentPersonID = Me.personID(in: session.id)
        if let old = mentionObservers[session.id] { session.document.removeObserver(old) }
        mentionObservers[session.id] = session.document.addObserver { [weak self, weak session] changes in
            guard changes.origin.isRemote, !changes.createdComments.isEmpty, let self, let session else { return }
            self.notifyMentions(changes.createdComments, in: session)
        }
    }

    private func notifyMentions(_ commentIDs: [String], in session: BaseSession) {
        guard let me = Me.personID(in: session.id) else { return }
        let doc = session.document
        for id in commentIDs {
            guard let comment = doc.comment(id), comment.mentions.contains(me), comment.authorDeviceID != doc.deviceID,
                  comment.createdTime > Date().addingTimeInterval(-7 * 86_400),
                  let record = doc.record(comment.recordID) else { continue }
            let title = doc.primaryTitle(record)
            let link = "rowhouse://record?base=\(doc.baseID)&table=\(record.tableID)&record=\(record.id)"
            Task {
                await MentionNotifier.post(title: "\(comment.authorName) mentioned you", subtitle: "\(title.isEmpty ? "Unnamed record" : title) · \(doc.info.name)", body: comment.text, link: link)
            }
        }
    }

    /// Creates a base from a template and returns its id once it's open.
    func createBase(name: String, template: BaseTemplate) async -> String? {
        var created: LibraryEntry?
        do {
            let entry = try library.createPackage(named: name)
            created = entry
            bases[entry.baseID] = .loading(entry.url)
            let session = try await BaseSession.open(entry: entry, identity: identity)
            session.document.updateBaseInfo(name: name)
            session.document.apply(template: template, storage: session.storage)
            session.writeSnapshotNow()
            return install(session, from: entry) ? entry.baseID : nil
        } catch {
            if let created { abandon(created) }
            showAlert(title: "Could not create the base", message: error.localizedDescription)
            return nil
        }
    }

    /// Creates an empty base (no tables) and returns its open session, for importers to fill.
    func createEmptyBase(name: String, icon: String = "square.grid.3x3.fill", color: ChoiceColor = .blue) async throws -> BaseSession {
        let entry = try library.createPackage(named: name)
        bases[entry.baseID] = .loading(entry.url)
        let session: BaseSession
        do {
            session = try await BaseSession.open(entry: entry, identity: identity)
        } catch {
            abandon(entry)
            throw error
        }
        let manager = session.document.undoManager
        session.document.undoManager = nil
        session.document.updateBaseInfo(name: name, icon: icon, color: color)
        session.document.undoManager = manager
        // Its automations start once the importer has filled it.
        guard install(session, from: entry, startingServices: false) else { throw CancellationError() }
        return session
    }

    /// Starts automations for a base created by an importer, once it has been filled.
    func finishImport(_ session: BaseSession) {
        session.writeSnapshotNow()
        startServices(for: session)
    }

    /// Creates a base holding one table imported from CSV.
    func createBase(fromCSV rows: [[String]], hasHeader: Bool, plan: [CSVColumnPlan], name: String) async -> String? {
        var created: LibraryEntry?
        do {
            let entry = try library.createPackage(named: name)
            created = entry
            bases[entry.baseID] = .loading(entry.url)
            let session = try await BaseSession.open(entry: entry, identity: identity)
            let doc = session.document
            let manager = doc.undoManager
            doc.undoManager = nil
            doc.updateBaseInfo(name: name, icon: "tablecells", color: .cyan)
            doc.importCSV(rows: rows, hasHeader: hasHeader, plan: plan, tableName: name)
            doc.undoManager = manager
            session.writeSnapshotNow()
            return install(session, from: entry) ? entry.baseID : nil
        } catch {
            if let created { abandon(created) }
            showAlert(title: "Could not import the CSV", message: error.localizedDescription)
            return nil
        }
    }

    func trashBase(_ baseID: String) {
        guard let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        close(baseID)
        do {
            try library.trash(entry)
        } catch {
            showAlert(title: "Could not move the base to the Trash", message: error.localizedDescription)
        }
        syncSessions()
    }

    /// Copies a base (with attachments) as a new base.
    func duplicateBase(_ baseID: String) async -> String? {
        guard let source = session(baseID), let entry = library.entries.first(where: { $0.baseID == baseID }) else { return nil }
        source.storage.flush()
        var created: LibraryEntry?
        do {
            let name = source.document.info.name + " copy"
            let copy = try library.duplicate(entry, state: source.document.state, name: name, deviceID: identity.id)
            created = copy
            bases[copy.baseID] = .loading(copy.url)
            let session = try await BaseSession.open(entry: copy, identity: identity)
            let manager = session.document.undoManager
            session.document.undoManager = nil
            session.document.updateBaseInfo(name: name)
            // Automations in the copy start switched off so nothing fires twice.
            for automation in session.document.automations where automation.enabled {
                session.document.updateAutomation(automation.id) { $0.enabled = false }
            }
            session.document.undoManager = manager
            return install(session, from: copy) ? copy.baseID : nil
        } catch {
            if let created { abandon(created) }
            showAlert(title: "Could not duplicate the base", message: error.localizedDescription)
            return nil
        }
    }

    func exportBackup(_ baseID: String) {
        guard let session = session(baseID), let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        session.writeSnapshotNow()
        session.storage.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(session.document.info.name) \(Date().formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Library.exportBackup(of: entry.url, to: url)
        } catch {
            showAlert(title: "Could not export the backup", message: error.localizedDescription)
        }
    }

    func importBackup() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a RowHouse backup (.zip)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var restored: LibraryEntry?
        do {
            let entry = try library.importBackup(from: url)
            restored = entry
            bases[entry.baseID] = .loading(entry.url)
            let session = try await BaseSession.open(entry: entry, identity: identity)
            return install(session, from: entry) ? entry.baseID : nil
        } catch {
            if let restored { abandon(restored) }
            showAlert(title: "Could not restore the backup", message: error.localizedDescription)
            return nil
        }
    }

    func revealInFinder(_ baseID: String) {
        guard let entry = library.entries.first(where: { $0.baseID == baseID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func setStorageLocation(_ location: StorageLocation) {
        // Every status belongs to the old folder, including bases still opening there.
        for id in Array(bases.keys) { close(id) }
        library.setLocation(location)
        syncSessions()
    }

    func closeAll() {
        for id in Array(bases.keys) { close(id) }
    }

    func pollAll() {
        for session in sessions.values { session.poll() }
    }
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
    var listExpansion: [String: ListExpansion] = [:]
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
