import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-disk layout of a base package (a folder ending in `.rowhouse`):
///
///     manifest.json                     written once when the base is created
///     devices/<deviceID>/log-*.jsonl    append-only operation logs, one writer per folder
///     devices/<deviceID>/snapshot.json  that device's merged state + the log segments it covers
///     devices/<deviceID>/runs.jsonl     automation run history from that device
///     attachments/<sha256>.<ext>        content-addressed files, immutable once written
///
/// Every file has exactly one writer, so iCloud Drive never has to resolve a conflict. Readers merge
/// every device's snapshot and logs; because merging is idempotent, re-reading anything is harmless.
public final class BaseStorage: @unchecked Sendable {
    public struct Manifest: Codable, Sendable {
        public var format: Int
        public var baseID: String
        public var name: String
        public var createdAt: Date
        public var app: String
    }

    public struct Changes: Sendable {
        public var snapshots: [BaseState] = []
        public var ops: [ChangeOperation] = []
        public var runs: [AutomationRun] = []

        public var isEmpty: Bool { snapshots.isEmpty && ops.isEmpty && runs.isEmpty }
    }

    public static let packageExtension = "rowhouse"
    static let formatVersion = 1
    static let segmentLimit = 5_000
    /// Log segments are kept this long after a snapshot covers them, which is also how far back
    /// record revision history reaches.
    static let compactionAge: TimeInterval = 14 * 24 * 3600

    public let packageURL: URL
    public let deviceID: String
    private let queue = DispatchQueue(label: "app.rowhouse.storage", qos: .utility)
    private let fm = FileManager.default

    // Queue-confined state
    private var segmentURL: URL?
    private var segmentOps = 0
    private var logOffsets: [String: UInt64] = [:]
    private var snapshotDates: [String: Date] = [:]
    private var ownSnapshotSegments: [String] = []
    private var ownSnapshotWritten: Date?
    private var loadedOnce = false
    private var opsReadAtLoad = 0
    /// Set when this device's snapshot exists but couldn't be read. Until it's recovered we never
    /// write a snapshot or compact, because the file may hold history the logs no longer have.
    private var ownSnapshotUnreadable = false
    private var lastWriteError: Error?
    /// Log segments seen per remote device, so a remote snapshot is only merged when that device
    /// has compacted segments away (otherwise its logs already delivered every change).
    private var seenSegments: [String: Set<String>] = [:]

    public init(packageURL: URL, deviceID: String) {
        self.packageURL = packageURL
        self.deviceID = deviceID
    }

    var devicesURL: URL { packageURL.appendingPathComponent("devices", isDirectory: true) }
    var ownURL: URL { devicesURL.appendingPathComponent(deviceID, isDirectory: true) }
    public var attachmentsURL: URL { packageURL.appendingPathComponent("attachments", isDirectory: true) }

    // MARK: - Package lifecycle

    public static func createPackage(at url: URL, baseID: String, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("devices", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("attachments", isDirectory: true), withIntermediateDirectories: true)
        let manifest = Manifest(format: formatVersion, baseID: baseID, name: name, createdAt: Date(), app: "RowHouse")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try coordinatedWrite(try encoder.encode(manifest), to: url.appendingPathComponent("manifest.json"))
    }

    public static func readManifest(at url: URL) -> Manifest? {
        let file = url.appendingPathComponent("manifest.json")
        guard let data = coordinatedRead(file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    // MARK: - Loading

    /// Reads everything on disk. Blocking — call from a background task.
    public func loadAll() -> (state: BaseState, runs: [AutomationRun]) {
        queue.sync {
            var state = BaseState()
            var runs: [AutomationRun] = []
            let changes = readLocked(includeOwnLogs: true)
            for s in changes.snapshots { state.merge(s) }
            for op in changes.ops { state.apply(op) }
            runs = changes.runs
            opsReadAtLoad = changes.ops.count
            loadedOnce = true
            return (state, runs)
        }
    }

    /// True when the last load replayed many log lines, so writing a snapshot would speed up the next one.
    public var needsInitialSnapshot: Bool {
        queue.sync { opsReadAtLoad > 500 }
    }

    /// Reads anything new written by other devices since the last read.
    public func pollChanges() -> Changes {
        queue.sync { readLocked(includeOwnLogs: false) }
    }

    private func readLocked(includeOwnLogs: Bool) -> Changes {
        var changes = Changes()
        let deviceDirs = (try? fm.contentsOfDirectory(at: devicesURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for dir in deviceDirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let device = dir.lastPathComponent
            let isOwn = device == deviceID
            if isOwn && !includeOwnLogs && !ownSnapshotUnreadable { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
            var covered: Set<String> = []
            let segmentNames = Set(files.map(\.lastPathComponent).filter { $0.hasPrefix("log-") && $0.hasSuffix(".jsonl") })

            if let snapshotURL = files.first(where: { $0.lastPathComponent == "snapshot.json" }) {
                let key = device + "/snapshot.json"
                let mtime = (try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                // After the first load a remote snapshot only adds something if that device deleted
                // log segments we had been reading; otherwise the logs already carried every change.
                let lostSegments = !(seenSegments[device] ?? []).isSubset(of: segmentNames)
                let wanted = !loadedOnce || isOwn || lostSegments
                if snapshotDates[key] != mtime && wanted {
                    if let data = Self.coordinatedRead(snapshotURL), let json = try? JSONValue.parse(data) {
                        snapshotDates[key] = mtime
                        changes.snapshots.append(BaseState(json: json["state"] ?? .null))
                        let segments = json["segments"]?.stringArray ?? []
                        if !loadedOnce { covered = Set(segments) }
                        if isOwn {
                            ownSnapshotSegments = segments
                            ownSnapshotWritten = json["written"]?.stringValue.flatMap(DateCoding.parseISO)
                            ownSnapshotUnreadable = false
                        }
                    } else if isOwn {
                        ownSnapshotUnreadable = true
                        NSLog("RowHouse: couldn't read this Mac's snapshot; snapshots and compaction are paused until it can be read")
                    }
                }
            }
            if isOwn && !includeOwnLogs { continue }
            if !isOwn { seenSegments[device, default: []].formUnion(segmentNames) }

            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                    // Evicted by "Optimize Mac Storage": ask iCloud to bring it back; a later poll reads it.
                    let original = file.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    try? fm.startDownloadingUbiquitousItem(at: original)
                    continue
                }
                if name.hasPrefix("log-") && name.hasSuffix(".jsonl") {
                    let key = device + "/" + name
                    if covered.contains(name) {
                        // Already folded into this device's snapshot: skip its contents but remember its size.
                        logOffsets[key] = (try? fm.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
                        continue
                    }
                    for line in readNewLines(file, key: key) {
                        if let json = try? JSONValue.parse(line), let op = ChangeOperation(json: json) {
                            changes.ops.append(op)
                        }
                    }
                } else if name == "runs.jsonl" {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for line in readNewLines(file, key: device + "/" + name) {
                        if let run = try? decoder.decode(AutomationRun.self, from: line) { changes.runs.append(run) }
                    }
                }
            }
        }
        return changes
    }

    /// Returns complete lines appended since the last read of `url`.
    private func readNewLines(_ url: URL, key: String) -> [Data] {
        let offset = logOffsets[key] ?? 0
        var result: [Data] = []
        var consumed: UInt64 = offset
        Self.coordinate(reading: url) { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset {
                // File was replaced by a shorter version (e.g. restored from iCloud); read it again.
                consumed = 0
            }
            guard size > consumed else { return }
            try? handle.seek(toOffset: consumed)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                result.append(Data(line))
            }
            consumed += UInt64(complete.count)
        }
        logOffsets[key] = consumed
        return result
    }

    // MARK: - History

    /// Every logged operation that touched one entity, from all devices, oldest first. Reads the
    /// logs directly (including segments already folded into snapshots), so it can take a moment
    /// on large bases — call it off the main thread.
    public func operations(forEntity id: String) -> [ChangeOperation] {
        let needle = Data("\"\(id)\"".utf8)
        var ops: [ChangeOperation] = []
        let deviceDirs = (try? fm.contentsOfDirectory(at: devicesURL, includingPropertiesForKeys: nil)) ?? []
        for dir in deviceDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("log-") && file.pathExtension == "jsonl" {
                guard let data = Self.coordinatedRead(file) else { continue }
                for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
                    if let json = try? JSONValue.parse(Data(line)), let op = ChangeOperation(json: json), op.id == id {
                        ops.append(op)
                    }
                }
            }
        }
        return ops.sorted { $0.ts < $1.ts }
    }

    // MARK: - Writing

    public func append(_ ops: [ChangeOperation]) {
        guard !ops.isEmpty else { return }
        var payload = Data()
        for op in ops {
            payload.append(op.json.serialized())
            payload.append(UInt8(ascii: "\n"))
        }
        let count = ops.count
        let data = payload
        queue.async { [self] in
            do {
                try fm.createDirectory(at: ownURL, withIntermediateDirectories: true)
                if segmentURL == nil || segmentOps >= Self.segmentLimit {
                    segmentURL = ownURL.appendingPathComponent(Self.newSegmentName())
                    segmentOps = 0
                }
                try Self.coordinatedAppend(data, to: segmentURL!)
                segmentOps += count
                logOffsets[deviceID + "/" + segmentURL!.lastPathComponent, default: 0] += UInt64(data.count)
            } catch {
                lastWriteError = error
                NSLog("RowHouse: failed to append to log: \(error)")
            }
        }
    }

    public func appendRun(_ run: AutomationRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var encoded = try? encoder.encode(run) else { return }
        encoded.append(UInt8(ascii: "\n"))
        let line = encoded
        queue.async { [self] in
            do {
                try fm.createDirectory(at: ownURL, withIntermediateDirectories: true)
                let url = ownURL.appendingPathComponent("runs.jsonl")
                try trimRunsIfNeeded(url)
                try Self.coordinatedAppend(line, to: url)
                logOffsets[deviceID + "/runs.jsonl", default: 0] += UInt64(line.count)
            } catch {
                NSLog("RowHouse: failed to record automation run: \(error)")
            }
        }
    }

    private func trimRunsIfNeeded(_ url: URL) throws {
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64, size > 2_000_000,
              let data = Self.coordinatedRead(url) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        var kept = Data()
        for line in lines.suffix(lines.count / 2) {
            kept.append(contentsOf: line)
            kept.append(UInt8(ascii: "\n"))
        }
        try Self.coordinatedWrite(kept, to: url)
        logOffsets[deviceID + "/runs.jsonl"] = UInt64(kept.count)
    }

    /// Writes this device's snapshot and compacts old log segments. The current segment is closed first
    /// so the snapshot never claims to cover operations that are appended after it.
    public func writeSnapshot(_ state: BaseState) {
        queue.async { [self] in
            guard !ownSnapshotUnreadable else { return }
            do {
                try fm.createDirectory(at: ownURL, withIntermediateDirectories: true)
                segmentURL = nil
                segmentOps = 0
                let files = (try? fm.contentsOfDirectory(atPath: ownURL.path)) ?? []
                var segments = files.filter { $0.hasPrefix("log-") && $0.hasSuffix(".jsonl") }.sorted()

                // Delete segments that were already covered by a snapshot written long enough ago that
                // every device has had time to receive it.
                if let written = ownSnapshotWritten, Date().timeIntervalSince(written) > Self.compactionAge {
                    let removable = Set(ownSnapshotSegments)
                    for name in segments where removable.contains(name) {
                        try? Self.coordinatedDelete(ownURL.appendingPathComponent(name))
                    }
                    segments.removeAll { removable.contains($0) }
                }

                let now = Date()
                let root: JSONValue = .object([
                    "format": .number(Double(Self.formatVersion)),
                    "device": .string(deviceID),
                    "written": .string(DateCoding.iso8601String(now)),
                    "segments": .array(segments.map(JSONValue.string)),
                    "state": state.json,
                ])
                try Self.coordinatedWrite(root.serialized(), to: ownURL.appendingPathComponent("snapshot.json"))
                // Only advance the compaction clock when the covered set actually changes.
                if segments != ownSnapshotSegments || ownSnapshotWritten == nil {
                    ownSnapshotSegments = segments
                    ownSnapshotWritten = now
                }
            } catch {
                lastWriteError = error
                NSLog("RowHouse: failed to write snapshot: \(error)")
            }
        }
    }

    /// Blocks until queued writes have finished.
    public func flush() {
        queue.sync {}
    }

    /// The latest failure to append to this device's log or write its snapshot, cleared once read.
    public func takeWriteError() -> Error? {
        queue.sync {
            defer { lastWriteError = nil }
            return lastWriteError
        }
    }

    private static func newSegmentName() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "log-%013lld-%@.jsonl", ms, String(UUID().uuidString.prefix(6)))
    }

    // MARK: - Attachments

    public func url(for attachment: AttachmentInfo) -> URL {
        attachmentsURL.appendingPathComponent(attachment.storedFileName)
    }

    /// Copies a file into the base, de-duplicating by content hash.
    public func importAttachment(from source: URL) throws -> AttachmentInfo {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return try importAttachment(data: data, filename: source.lastPathComponent)
    }

    public func importAttachment(data: Data, filename: String) throws -> AttachmentInfo {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        var info = AttachmentInfo(filename: filename, hash: hash, size: data.count, mimeType: type.preferredMIMEType ?? "application/octet-stream")
        if type.conforms(to: .image), let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            info.width = props[kCGImagePropertyPixelWidth] as? Int
            info.height = props[kCGImagePropertyPixelHeight] as? Int
        }
        try fm.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        let dest = url(for: info)
        if !fm.fileExists(atPath: dest.path) {
            try Self.coordinatedWrite(data, to: dest)
        }
        return info
    }

    // MARK: - File coordination helpers

    static func coordinate(reading url: URL, _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { body($0) }
    }

    static func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        coordinate(reading: url) { data = try? Data(contentsOf: $0) }
        return data
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    static func coordinatedAppend(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                writeError = error
            }
        }
        if let e = coordError ?? writeError { throw e }
    }

    static func coordinatedDelete(_ url: URL) throws {
        var coordError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { deleteError = error }
        }
        if let e = coordError ?? deleteError { throw e }
    }
}
