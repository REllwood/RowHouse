import Foundation
import Observation

/// Ties a `BaseDocument` to its package on disk: loads it, persists local edits, watches for edits
/// arriving from other devices through iCloud Drive, and keeps snapshots fresh.
@MainActor
@Observable
public final class BaseSession: Identifiable {
    public nonisolated let id: String
    public let url: URL
    public let document: BaseDocument
    public let storage: BaseStorage
    public private(set) var runs: [AutomationRun] = []
    public private(set) var lastSyncedAt: Date?

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var snapshotWorkItem: DispatchWorkItem?
    @ObservationIgnored private var opsSinceSnapshot = 0
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var pendingPoll = false
    @ObservationIgnored private var closed = false

    static let maxRunsInMemory = 500
    static let snapshotEveryOps = 1_000
    static let snapshotIdleDelay: TimeInterval = 120

    private init(id: String, url: URL, document: BaseDocument, storage: BaseStorage, runs: [AutomationRun]) {
        self.id = id
        self.url = url
        self.document = document
        self.storage = storage
        self.runs = runs.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxRunsInMemory).map { $0 }
    }

    /// Opens a base package, reading every device's snapshot and logs off the main thread.
    public static func open(entry: LibraryEntry, identity: DeviceIdentity) async throws -> BaseSession {
        let storage = BaseStorage(packageURL: entry.url, deviceID: identity.id)
        let loaded = await Task.detached(priority: .userInitiated) { storage.loadAll() }.value
        let document = BaseDocument(baseID: entry.baseID, deviceID: identity.id, deviceName: identity.name, state: loaded.state)
        let session = BaseSession(id: entry.baseID, url: entry.url, document: document, storage: storage, runs: loaded.runs)
        session.start()
        return session
    }

    private func start() {
        document.outbox = { [weak self] ops in
            guard let self else { return }
            self.storage.append(ops)
            self.opsSinceSnapshot += ops.count
            self.scheduleSnapshot()
        }
        document.registerDevice()
        watcher = DirectoryWatcher(url: storage.packageURL.appendingPathComponent("devices", isDirectory: true)) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // FSEvents covers almost everything; the timer is a safety net for missed events.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        lastSyncedAt = Date()
        // A first snapshot makes the next launch fast when a base was built from many log lines.
        if storage.needsInitialSnapshot { writeSnapshotNow() }
    }

    /// Pulls in changes written by other devices.
    public func poll() {
        guard !closed else { return }
        if polling {
            pendingPoll = true
            return
        }
        polling = true
        let storage = self.storage
        Task { [weak self] in
            let changes = await Task.detached(priority: .utility) { storage.pollChanges() }.value
            guard let self else { return }
            self.polling = false
            self.apply(changes)
            if self.pendingPoll {
                self.pendingPoll = false
                self.poll()
            }
        }
    }

    private func apply(_ changes: BaseStorage.Changes) {
        for snapshot in changes.snapshots { document.mergeRemote(snapshot) }
        if !changes.ops.isEmpty { document.mergeRemote(changes.ops) }
        if !changes.runs.isEmpty {
            var merged = runs
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: changes.runs.filter { !known.contains($0.id) })
            runs = merged.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxRunsInMemory).map { $0 }
        }
        lastSyncedAt = Date()
    }

    /// Records an automation run locally and in this device's run log.
    public func record(run: AutomationRun) {
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
            if runs.count > Self.maxRunsInMemory { runs.removeLast(runs.count - Self.maxRunsInMemory) }
        }
        if run.status != .running { storage.appendRun(run) }
    }

    private func scheduleSnapshot() {
        if opsSinceSnapshot >= Self.snapshotEveryOps {
            writeSnapshotNow()
            return
        }
        snapshotWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeSnapshotNow() }
        }
        snapshotWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotIdleDelay, execute: item)
    }

    public func writeSnapshotNow() {
        snapshotWorkItem?.cancel()
        snapshotWorkItem = nil
        opsSinceSnapshot = 0
        storage.writeSnapshot(document.state)
    }

    /// Flushes pending writes and stops watching. Call before quitting.
    public func close() {
        guard !closed else { return }
        closed = true
        watcher?.stop()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if opsSinceSnapshot > 0 { writeSnapshotNow() }
        storage.flush()
    }
}
