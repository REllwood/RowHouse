import Foundation
import RowHouseCore

/// A base opened by the server: its document plus this agent's storage. Unlike the app's
/// `BaseSession` there is no file watcher, timer or undo; the server pulls other devices' changes
/// right before each tool call and flushes its own right after, which is all a request/response
/// process needs.
@MainActor
final class AgentSession {
    static let snapshotEveryOps = 1_000

    let entry: LibraryEntry
    let storage: BaseStorage
    let document: BaseDocument
    private(set) var opsSinceSnapshot = 0

    private init(entry: LibraryEntry, storage: BaseStorage, document: BaseDocument) {
        self.entry = entry
        self.storage = storage
        self.document = document
    }

    /// Reads every device's snapshot and logs, then registers this agent as a device of the base.
    static func open(entry: LibraryEntry, deviceID: String, deviceName: String) async -> AgentSession {
        let storage = BaseStorage(packageURL: entry.url, deviceID: deviceID)
        let loaded = await Task.detached(priority: .userInitiated) { storage.loadAll() }.value
        let document = BaseDocument(baseID: entry.baseID, deviceID: deviceID, deviceName: deviceName, state: loaded.state)
        let session = AgentSession(entry: entry, storage: storage, document: document)
        document.outbox = { [weak session] ops in
            guard let session else { return }
            session.storage.append(ops)
            session.opsSinceSnapshot += ops.count
        }
        document.registerDevice(kind: DeviceInfo.agentKind)
        if storage.needsInitialSnapshot { session.writeSnapshot() }
        return session
    }

    var attachmentsURL: URL { storage.attachmentsURL }

    /// Merges whatever other devices have written since the last pull.
    func pull() async {
        let storage = self.storage
        let changes = await Task.detached(priority: .userInitiated) { storage.pollChanges() }.value
        for snapshot in changes.snapshots { document.mergeRemote(snapshot) }
        if !changes.ops.isEmpty { document.mergeRemote(changes.ops) }
    }

    /// Waits until this agent's operations are on disk, where the app's file watcher picks them up.
    func flush() {
        storage.flush()
        if opsSinceSnapshot >= Self.snapshotEveryOps { writeSnapshot() }
    }

    func writeSnapshot() {
        opsSinceSnapshot = 0
        storage.writeSnapshot(document.state)
        storage.flush()
    }

    func renameDevice(_ name: String) {
        guard document.deviceName != name else { return }
        document.deviceName = name
        document.registerDevice(kind: DeviceInfo.agentKind)
        storage.flush()
    }

    /// Final snapshot before the process exits.
    func close() {
        if opsSinceSnapshot > 0 { writeSnapshot() } else { storage.flush() }
    }
}
