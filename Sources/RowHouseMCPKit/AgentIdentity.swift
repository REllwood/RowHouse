import Darwin
import Foundation
import RowHouseCore

/// The device this server writes as. Every running server holds an exclusive lock on one numbered
/// slot, so two assistants working at once (say Claude Desktop and Codex) never append to the same
/// device folder, while a restarted assistant reuses its old folder instead of creating a new one.
final class AgentIdentity: @unchecked Sendable {
    static let maxSlots = 64

    let deviceID: String
    /// nil when no slot could be locked; the device id is then unique to this process.
    let slot: Int?
    private var lockFD: Int32

    /// `~/Library/Application Support/RowHouse/agents`, shared by every copy of the server.
    static var defaultLockDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("RowHouse/agents", isDirectory: true)
    }

    init(hostDeviceID: String, lockDirectory: URL) {
        let (slot, fd) = Self.acquireSlot(in: lockDirectory)
        self.slot = slot
        self.lockFD = fd
        // Sharing a device folder between processes would let two writers stamp operations with the
        // same clock node, so without a lock the server writes as a one-off device instead.
        self.deviceID = slot.map { "\(hostDeviceID)-agent\($0)" } ?? "\(hostDeviceID)-agent-\(RowID.make("", length: 8))"
    }

    deinit {
        release()
    }

    /// Gives the slot back (the lock also goes away when the process exits).
    func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    /// The lowest slot whose lock file isn't held by another server.
    private static func acquireSlot(in directory: URL) -> (Int?, Int32) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.warning("can't create \(directory.path) (\(error.localizedDescription)); writing as a temporary device")
            return (nil, -1)
        }
        for slot in 0..<maxSlots {
            let path = directory.appendingPathComponent("\(slot).lock").path
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return (slot, fd) }
            close(fd)
        }
        Log.warning("all \(maxSlots) agent slots are in use; writing as a temporary device")
        return (nil, -1)
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
