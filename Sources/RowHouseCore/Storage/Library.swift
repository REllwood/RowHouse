import Foundation
import Observation

public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public var id: String { baseID }
    public var baseID: String
    public var url: URL
    public var initialName: String
    public var createdAt: Date
}

public enum StorageLocation: Equatable, Sendable {
    case iCloudDrive
    case local
    case custom(URL)
}

/// The folder holding every base package. Defaults to `iCloud Drive/RowHouse`.
@MainActor
@Observable
public final class Library {
    public private(set) var rootURL: URL
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var lastError: String?

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private let defaults: UserDefaults
    /// Preference key for the folder chosen in Settings (absent means iCloud Drive).
    public static let customPathKey = "RowHouseLibraryPath"

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(rootURL: Library.resolveRoot(defaults: defaults), defaults: defaults)
    }

    /// A library in a folder chosen by the caller rather than by the storage setting.
    public init(rootURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rootURL = rootURL
        prepareRoot()
        refresh()
        startWatching()
    }

    public static var iCloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url.appendingPathComponent("RowHouse", isDirectory: true) : nil
    }

    public static var localRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("RowHouse/Bases", isDirectory: true)
    }

    public static var isICloudDriveAvailable: Bool { iCloudDriveRoot != nil }

    /// The library folder: `ROWHOUSE_LIBRARY_PATH`, then the folder chosen in Settings (read from
    /// `defaults`), then iCloud Drive, then a folder on this Mac.
    public static func resolveRoot(defaults: UserDefaults) -> URL {
        if let env = ProcessInfo.processInfo.environment["ROWHOUSE_LIBRARY_PATH"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let custom = defaults.string(forKey: customPathKey), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return iCloudDriveRoot ?? localRoot
    }

    public var location: StorageLocation {
        if rootURL.standardizedFileURL == Self.iCloudDriveRoot?.standardizedFileURL { return .iCloudDrive }
        if rootURL.standardizedFileURL == Self.localRoot.standardizedFileURL { return .local }
        return .custom(rootURL)
    }

    public var isInICloudDrive: Bool {
        rootURL.path.contains("/Library/Mobile Documents/")
    }

    public func setLocation(_ location: StorageLocation) {
        switch location {
        case .iCloudDrive:
            defaults.removeObject(forKey: Self.customPathKey)
            rootURL = Self.iCloudDriveRoot ?? Self.localRoot
        case .local:
            defaults.set(Self.localRoot.path, forKey: Self.customPathKey)
            rootURL = Self.localRoot
        case .custom(let url):
            defaults.set(url.path, forKey: Self.customPathKey)
            rootURL = url
        }
        prepareRoot()
        refresh()
        startWatching()
    }

    private func prepareRoot() {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            lastError = nil
        } catch {
            lastError = "Couldn't create \(rootURL.path): \(error.localizedDescription)"
        }
    }

    private func startWatching() {
        watcher?.stop()
        watcher = DirectoryWatcher(url: rootURL, latency: 1.0) { [weak self] paths in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only react to packages appearing or disappearing, not to edits inside them.
                let relevant = paths.contains { path in
                    let rel = path.replacingOccurrences(of: self.rootURL.path, with: "")
                    let parts = rel.split(separator: "/")
                    return parts.count <= 2
                }
                if relevant { self.refresh() }
            }
        }
    }

    public func refresh() {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            if lastError != nil { lastError = nil }
        } catch {
            // Usually macOS privacy settings: the app hasn't been allowed into iCloud Drive yet.
            let message = "RowHouse can't open \(rootURL.path): \(error.localizedDescription)"
            if lastError != message { lastError = message }
            urls = []
        }
        var found: [LibraryEntry] = []
        var seen = Set<String>()
        for url in urls where url.pathExtension == BaseStorage.packageExtension {
            guard let manifest = BaseStorage.readManifest(at: url), !seen.contains(manifest.baseID) else { continue }
            seen.insert(manifest.baseID)
            found.append(LibraryEntry(baseID: manifest.baseID, url: url, initialName: manifest.name, createdAt: manifest.createdAt))
        }
        found.sort { ($0.createdAt, $0.initialName) < ($1.createdAt, $1.initialName) }
        if found != entries { entries = found }
    }

    /// Creates an empty base package and returns its entry.
    public func createPackage(named name: String) throws -> LibraryEntry {
        let baseID = RowID.base()
        let safe = Self.sanitize(name)
        var url = rootURL.appendingPathComponent("\(safe).\(BaseStorage.packageExtension)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rootURL.appendingPathComponent("\(safe) \(n).\(BaseStorage.packageExtension)", isDirectory: true)
            n += 1
        }
        try BaseStorage.createPackage(at: url, baseID: baseID, name: name)
        let entry = LibraryEntry(baseID: baseID, url: url, initialName: name, createdAt: Date())
        refresh()
        return entry
    }

    /// Moves a base to the Trash (recoverable from Finder).
    public func trash(_ entry: LibraryEntry) throws {
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        refresh()
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "Base" : trimmed
    }
}

// MARK: - Duplicate, back up and restore

public enum LibraryError: LocalizedError, Sendable {
    case notABackup
    case unzipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notABackup: "That file isn't a RowHouse backup."
        case .unzipFailed(let message): "Couldn't open the backup: \(message)"
        }
    }
}

extension Library {
    /// Copies a base into a new package with its own id. The copy starts from `state` (the source's
    /// merged state) written as this device's snapshot, plus every attachment file.
    public func duplicate(_ entry: LibraryEntry, state: BaseState, name: String, deviceID: String) throws -> LibraryEntry {
        let copy = try createPackage(named: name)
        let fm = FileManager.default
        let sourceAttachments = entry.url.appendingPathComponent("attachments", isDirectory: true)
        let targetAttachments = copy.url.appendingPathComponent("attachments", isDirectory: true)
        for file in (try? fm.contentsOfDirectory(at: sourceAttachments, includingPropertiesForKeys: nil)) ?? [] {
            let dest = targetAttachments.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: file, to: dest) }
        }
        let storage = BaseStorage(packageURL: copy.url, deviceID: deviceID)
        storage.writeSnapshot(state)
        storage.flush()
        refresh()
        return copy
    }

    /// Writes a zip of the whole base package (every device's logs, snapshots and attachments).
    public nonisolated static func exportBackup(of packageURL: URL, to destination: URL) throws {
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: packageURL, options: .forUploading, error: &coordError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let e = coordError ?? copyError { throw e }
    }

    /// Restores a backup zip as a new base (with a new id, so it can sit alongside the original).
    public func importBackup(from zipURL: URL) throws -> LibraryEntry {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("rowhouse-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, temp.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LibraryError.unzipFailed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let candidates = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        guard let package = candidates.first(where: { $0.pathExtension == BaseStorage.packageExtension }) ?? (BaseStorage.readManifest(at: temp) != nil ? temp : nil),
              var manifest = BaseStorage.readManifest(at: package)
        else { throw LibraryError.notABackup }
        manifest.baseID = RowID.base()
        let baseName = package.deletingPathExtension().lastPathComponent
        var dest = rootURL.appendingPathComponent("\(Self.sanitize(baseName)).\(BaseStorage.packageExtension)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = rootURL.appendingPathComponent("\(Self.sanitize(baseName)) \(n).\(BaseStorage.packageExtension)", isDirectory: true)
            n += 1
        }
        try fm.copyItem(at: package, to: dest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try BaseStorage.coordinatedWrite(try encoder.encode(manifest), to: dest.appendingPathComponent("manifest.json"))
        refresh()
        guard let entry = entries.first(where: { $0.baseID == manifest.baseID }) else { throw LibraryError.notABackup }
        return entry
    }
}
