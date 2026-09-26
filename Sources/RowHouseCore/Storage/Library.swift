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
    static let customPathKey = "RowHouseLibraryPath"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rootURL = Library.resolveRoot(defaults: defaults)
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

    static func resolveRoot(defaults: UserDefaults) -> URL {
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
        let urls = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
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
