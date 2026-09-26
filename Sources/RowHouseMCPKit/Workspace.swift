import Foundation
import RowHouseCore

/// The library of bases as the server sees it: which bases exist, which are open, and how names
/// and ids in tool arguments map onto bases, tables, fields, views and records.
@MainActor
final class Workspace {
    let library: Library
    let agent: AgentIdentity
    private(set) var deviceName: String
    private var sessions: [String: AgentSession] = [:]

    init(library: Library, agent: AgentIdentity, deviceName: String) {
        self.library = library
        self.agent = agent
        self.deviceName = deviceName
    }

    var openSessions: [AgentSession] { Array(sessions.values) }

    /// Bases in the library, re-read from disk so bases created, moved or removed elsewhere show up.
    func entries() throws(ToolError) -> [LibraryEntry] {
        library.refresh()
        if let error = library.lastError { throw Self.accessError(root: library.rootURL, detail: error) }
        let live = Dictionary(library.entries.map { ($0.baseID, $0.url.standardizedFileURL) }, uniquingKeysWith: { first, _ in first })
        for (id, session) in sessions where live[id] != session.entry.url.standardizedFileURL {
            // Gone, or moved or renamed in Finder: its edits are already on disk (every change is
            // flushed), so the session is dropped without writing, and reopened where it now lives.
            sessions[id] = nil
        }
        return library.entries
    }

    static func accessError(root: URL, detail: String) -> ToolError {
        ToolError("""
            Can't read the RowHouse library at \(root.path). \(detail)
            If the folder is in iCloud Drive, macOS may be blocking the app that started this server. Open System Settings › Privacy & Security › Files & Folders, find that app (for example Claude, Codex, Terminal or your code editor) and turn on iCloud Drive (or the folder's location), then try again. Setting the environment variable ROWHOUSE_LIBRARY_PATH changes which folder the server uses.
            """)
    }

    /// The open session for a base, pulling in recent changes from other devices first.
    func session(for entry: LibraryEntry) async -> AgentSession {
        if let existing = sessions[entry.baseID] {
            await existing.pull()
            return existing
        }
        let session = await AgentSession.open(entry: entry, deviceID: agent.deviceID, deviceName: deviceName)
        // Another call may have opened the same base while this one was loading.
        if let existing = sessions[entry.baseID] { return existing }
        sessions[entry.baseID] = session
        return session
    }

    func allSessions() async throws(ToolError) -> [AgentSession] {
        var result: [AgentSession] = []
        for entry in try entries() { result.append(await session(for: entry)) }
        return result
    }

    /// A base by id or name (exact, then ignoring case).
    func base(_ key: String) async throws(ToolError) -> AgentSession {
        let list = try entries()
        if let entry = list.first(where: { $0.baseID == key }) { return await session(for: entry) }
        let all = try await allSessions()
        var matches = all.filter { $0.document.info.name == key }
        if matches.isEmpty { matches = all.filter { $0.document.info.name.caseInsensitiveCompare(key) == .orderedSame } }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let ids = matches.map(\.entry.baseID).sorted().joined(separator: ", ")
            throw ToolError("Several bases are named \(key) (\(ids)); pass the base id instead.")
        }
        if all.isEmpty { throw ToolError("No base named \(key). There are no bases yet; create one with create_base.") }
        let names = all.map { "\($0.document.info.name) (\($0.entry.baseID))" }.sorted().joined(separator: ", ")
        throw ToolError("No base named \(key). Bases: \(names)")
    }

    func adopt(_ session: AgentSession) {
        sessions[session.entry.baseID] = session
    }

    /// Called when the client introduces itself: settles which agent slot to write as (while nothing
    /// has been written yet) and the name other devices show, e.g. "Claude Code (MCP)".
    func introduce(client: String) {
        if !sessions.values.contains(where: \.hasWritten), agent.claim(for: client) {
            sessions = [:]
            Log.info("writing as \(agent.deviceID)")
        }
        let name = "\(client) (MCP)"
        guard name != deviceName else { return }
        deviceName = name
        for session in sessions.values { session.renameDevice(name) }
    }

    /// Writes snapshots for bases with many unsnapshotted edits (called every few minutes).
    func performMaintenance() {
        for session in sessions.values where session.opsSinceSnapshot > 0 { session.writeSnapshot() }
    }

    func close() {
        for session in sessions.values { session.close() }
        sessions = [:]
    }
}

/// Resolving names and ids inside one base.
@MainActor
struct BaseLookup {
    let session: AgentSession
    /// Indexes primary field values the first time a record is looked up by one.
    private let titles: RecordValueCoding

    init(session: AgentSession) {
        self.session = session
        titles = RecordValueCoding(document: session.document)
    }

    var document: BaseDocument { session.document }
    var baseName: String { document.info.name }

    func table(_ key: String) throws(ToolError) -> TableModel {
        if let t = document.table(key) { return t }
        if let t = document.table(named: key) { return t }
        let names = document.tables.map(\.name).joined(separator: ", ")
        throw ToolError("No table named \(key) in base \(baseName). Tables: \(names.isEmpty ? "none" : names)")
    }

    func field(_ key: String, in table: TableModel) throws(ToolError) -> FieldModel {
        if let f = document.field(key), f.tableID == table.id { return f }
        if let f = document.field(named: key, in: table.id) { return f }
        let names = document.fields(in: table.id).map(\.name).joined(separator: ", ")
        throw ToolError("No field named \(key) in table \(table.name). Fields: \(names)")
    }

    func view(_ key: String, in table: TableModel) throws(ToolError) -> ViewModel {
        let views = document.views(in: table.id)
        if let v = views.first(where: { $0.id == key }) ?? views.first(where: { $0.name == key })
            ?? views.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return v
        }
        let names = views.map(\.name).joined(separator: ", ")
        throw ToolError("No view named \(key) in table \(table.name). Views: \(names.isEmpty ? "none" : names)")
    }

    /// A record by id, or by primary field value within `table` (or any table when none is given).
    func record(_ key: String, in table: TableModel?) throws(ToolError) -> RecordModel {
        if let r = document.record(key) {
            if let table, r.tableID != table.id {
                throw ToolError("Record \(key) belongs to table \(document.table(r.tableID)?.name ?? r.tableID), not \(table.name)")
            }
            return r
        }
        let tables = table.map { [$0] } ?? document.tables
        let matches = tables.flatMap { t in titles.recordIDs(titled: key, in: t.id).compactMap { document.record($0) } }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let places = matches.prefix(10).map { "\($0.id) in \(document.table($0.tableID)?.name ?? "")" }.joined(separator: ", ")
            throw ToolError("\(matches.count) records are called \(key) (\(places)); pass a record id instead.")
        }
        if let table { throw ToolError("No record \(key) in table \(table.name). Pass a record id (rec…) or the primary field value.") }
        throw ToolError("No record \(key) in base \(baseName). Pass a record id (rec…).")
    }

    /// Several records of one table, checked before anything is written.
    func records(_ keys: [String], in table: TableModel) throws(ToolError) -> [RecordModel] {
        var out: [RecordModel] = []
        for key in keys { out.append(try record(key, in: table)) }
        return out
    }
}
