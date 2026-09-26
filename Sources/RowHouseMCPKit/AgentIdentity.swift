import Darwin
import Foundation
import RowHouseCore

/// The device this server writes as. Every running server holds an exclusive lock on one numbered
/// slot, so two assistants working at once (say Claude Desktop and Codex) never append to the same
/// device folder, while a restarted assistant reuses its old folder instead of creating a new one.
///
/// The server starts in the lowest free slot. Each lock file remembers which assistant last used it,
/// and once the client introduces itself the server moves to a free slot that assistant used before
/// (or an unused one), so one assistant's past edits aren't relabelled with another's name.
final class AgentIdentity: @unchecked Sendable {
    static let maxSlots = 64

    private let hostDeviceID: String
    private let directory: URL
    private(set) var deviceID: String
    /// nil when no slot could be locked; the device id is then unique to this process.
    private(set) var slot: Int?
    private var lockFD: Int32

    /// `~/Library/Application Support/RowHouse/agents`, shared by every copy of the server.
    static var defaultLockDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("RowHouse/agents", isDirectory: true)
    }

    init(hostDeviceID: String, lockDirectory: URL) {
        self.hostDeviceID = hostDeviceID
        self.directory = lockDirectory
        let acquired = Self.acquireSlot(in: lockDirectory) { _ in true }
        slot = acquired?.slot
        lockFD = acquired?.fd ?? -1
        // Sharing a device folder between processes would let two writers stamp operations with the
        // same clock node, so without a lock the server writes as a one-off device instead.
        deviceID = Self.deviceID(host: hostDeviceID, slot: slot)
    }

    deinit {
        release()
    }

    private static func deviceID(host: String, slot: Int?) -> String {
        slot.map { "\(host)-agent\($0)" } ?? "\(host)-agent-\(RowID.make("", length: 8))"
    }

    /// Records `client` as this slot's user, first moving to a free slot that `client` used before (or
    /// one nobody has used) when the current slot belonged to another assistant. Call before anything
    /// is written; returns true when the device id changed.
    @discardableResult
    func claim(for client: String) -> Bool {
        guard let current = slot, lockFD >= 0 else { return false }
        let previous = Self.recordedClient(lockFD)
        if previous.isEmpty || previous == client {
            Self.record(client, in: lockFD)
            return false
        }
        let better = Self.acquireSlot(in: directory, excluding: current) { $0 == client }
            ?? Self.acquireSlot(in: directory, excluding: current) { $0.isEmpty }
        guard let better else {
            Self.record(client, in: lockFD)
            return false
        }
        release()
        slot = better.slot
        lockFD = better.fd
        deviceID = Self.deviceID(host: hostDeviceID, slot: better.slot)
        Self.record(client, in: lockFD)
        return true
    }

    /// Gives the slot back (the lock also goes away when the process exits).
    func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    /// The lowest unlocked slot whose recorded client satisfies `accept`, locked and open.
    private static func acquireSlot(in directory: URL, excluding excluded: Int? = nil, accept: (String) -> Bool) -> (slot: Int, fd: Int32)? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.warning("can't create \(directory.path) (\(error.localizedDescription)); writing as a temporary device")
            return nil
        }
        for slot in 0..<maxSlots where slot != excluded {
            let path = directory.appendingPathComponent("\(slot).lock").path
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 && accept(recordedClient(fd)) { return (slot, fd) }
            close(fd)
        }
        if excluded == nil { Log.warning("all \(maxSlots) agent slots are in use; writing as a temporary device") }
        return nil
    }

    private static func recordedClient(_ fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func record(_ client: String, in fd: Int32) {
        let bytes = Array(client.utf8.prefix(255))
        guard ftruncate(fd, 0) == 0 else { return }
        _ = bytes.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }
}

/// Diagnostics go to standard error; standard output carries only protocol messages.
enum Log {
    static func info(_ message: String) {
        write("rowhouse-mcp: \(message)\n")
    }

    static func warning(_ message: String) {
        write("rowhouse-mcp: warning: \(message)\n")
    }

    private static func write(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}
