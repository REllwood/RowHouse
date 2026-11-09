import AppKit
import RowHouseCore

/// Keeps a second copy of RowHouse from running on this Mac. Two copies would share this Mac's device
/// id and interleave writes to the same change logs, so a second copy must stop before any window opens
/// a base. A development build ("RowHouse Dev") has its own lock, so it can run beside the app.
@MainActor
enum InstanceLock {
    enum State: Equatable {
        /// Not claimed yet.
        case unclaimed
        /// This copy holds the lock until it quits.
        case held(fileDescriptor: Int32)
        /// Another copy of RowHouse is running.
        case heldByAnotherCopy
        /// The lock file could not be opened, so this copy runs without one, as it always has.
        case unavailable
    }

    private(set) static var state = State.unclaimed

    /// Claims the lock, or reports that another copy already holds it.
    @discardableResult
    static func claim() -> State {
        guard state == .unclaimed else { return state }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RowHouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let name = AppInfo.isDevelopmentBuild ? "instance-\(Bundle.main.bundleIdentifier ?? "dev").lock" : "instance.lock"
        let descriptor = open(support.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o644)
        if descriptor < 0 {
            state = .unavailable
        } else if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            state = .held(fileDescriptor: descriptor)
        } else {
            close(descriptor)
            state = .heldByAnotherCopy
        }
        return state
    }

    static func release() {
        guard case .held(let descriptor) = state else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        state = .unclaimed
    }

    /// Called as the app starts. A second copy explains why it cannot open, brings the running copy
    /// forward and quits, before SwiftUI creates a window.
    static func claimOrQuit() {
        guard claim() == .heldByAnotherCopy else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        _ = AppDialogPresenter.runModal(.notice("RowHouse is already running", message: "Only one copy of RowHouse can run at a time on this Mac."))
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0 != NSRunningApplication.current }?
            .activate()
        exit(0)
    }
}
