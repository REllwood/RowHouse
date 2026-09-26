import Foundation

/// A base the token can read, as listed by Airtable's metadata API.
public struct AirtableBaseSummary: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// Airtable's permission level for the token's owner: "none", "read", "comment", "edit" or "create".
    public let permissionLevel: String

    public init(id: String, name: String, permissionLevel: String) {
        self.id = id
        self.name = name
        self.permissionLevel = permissionLevel
    }
}

public struct ImportReport: Sendable, Equatable {
    public var tables = 0
    public var fields = 0
    public var records = 0
    /// Attachment files downloaded and stored in the base.
    public var attachments = 0
    /// Attachment files that couldn't be downloaded and were left out.
    public var skippedAttachments = 0
    /// Places where the imported base differs from the original, in plain language.
    public var warnings: [String] = []

    public init() {}
}

public enum AirtableImportError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case server(status: Int, message: String?)
    case network(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Airtable didn't accept the token. Check that it was copied in full and that it has the data.records:read and schema.bases:read scopes."
        case .forbidden:
            "The token isn't allowed to read this base. Check the token has the data.records:read and schema.bases:read scopes and that the base is in its list of bases."
        case .notFound:
            "Airtable couldn't find the base or one of its tables. It may have been deleted, or the token may not have access to it."
        case .rateLimited:
            "Airtable is limiting requests right now. Wait a minute, then try again."
        case .server(let status, let message):
            "Airtable returned an error (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        case .network(let description):
            "Couldn't reach Airtable: \(description)"
        case .invalidResponse:
            "Airtable sent a response RowHouse couldn't read."
        }
    }
}

/// Copies an Airtable base — tables, fields, records, links and attachments — into a `BaseDocument`
/// using Airtable's Web API and a personal access token. The token is held in memory only.
public final class AirtableImporter: Sendable {
    private let client: AirtableAPIClient
    private let session: URLSession
    private let policy: AirtableRequestPolicy

    /// Ephemeral, so API responses holding the user's data are never written to the URL cache on disk.
    private static let defaultSession = URLSession(configuration: .ephemeral)

    public convenience init(token: String, session: URLSession? = nil) {
        self.init(token: token, session: session ?? Self.defaultSession, policy: .standard)
    }

    init(token: String, session: URLSession, policy: AirtableRequestPolicy) {
        self.client = AirtableAPIClient(token: token.trimmingCharacters(in: .whitespacesAndNewlines), session: session, policy: policy)
        self.session = session
        self.policy = policy
    }

    public func listBases() async throws -> [AirtableBaseSummary] {
        var bases: [AirtableBaseSummary] = []
        var offset: String?
        repeat {
            try Task.checkCancellation()
            let page = try await client.basesPage(offset: offset)
            bases += page.bases
            offset = page.offset
        } while offset != nil
        return bases
    }

    /// Reads the whole base first (schema, every record, every attachment) and only then writes to
    /// `document`, so a network failure never leaves a partly built base. Records are written in
    /// chunks that check for cancellation. Not undoable: the import is the base's starting state.
    @MainActor
    public func importBase(
        id baseID: String,
        name: String,
        into document: BaseDocument,
        storage: BaseStorage,
        progress: @MainActor (String, Double) -> Void
    ) async throws -> ImportReport {
        try Task.checkCancellation()
        progress("Reading the structure of “\(name)”…", 0)
        let tables = try await client.tables(baseID: baseID)
        guard !tables.isEmpty else {
            var report = ImportReport()
            report.warnings.append("“\(name)” has no tables the token can read.")
            return report
        }

        var records: [String: [AirtableRecord]] = [:]
        let share = 0.6 / Double(tables.count)
        for (index, table) in tables.enumerated() {
            var rows: [AirtableRecord] = []
            var offset: String?
            var pages = 0
            repeat {
                try Task.checkCancellation()
                let within = 1 - pow(0.85, Double(pages))
                progress("Downloading “\(table.name)” — \(rows.count) records…", 0.05 + share * (Double(index) + within))
                let page = try await client.recordsPage(baseID: baseID, tableID: table.id, offset: offset)
                rows += page.records
                offset = page.offset
                pages += 1
            } while offset != nil
            records[table.id] = rows
        }

        let jobs = Self.attachmentJobs(tables: tables, records: records)
        let stored = try await downloadAttachments(jobs, storage: storage, progress: progress)

        try Task.checkCancellation()
        progress("Creating tables and fields…", 0.9)
        let builder = AirtableBaseBuilder(document: document, tables: tables, records: records, attachments: stored)
        var report = try await builder.build(progress: progress)
        report.attachments = stored.count
        report.skippedAttachments = jobs.count - stored.count
        if report.skippedAttachments > 0 {
            let count = report.skippedAttachments
            report.warnings.append(count == 1
                ? "1 attachment couldn't be downloaded and was left out."
                : "\(count) attachments couldn't be downloaded and were left out.")
        }
        progress("Import complete", 1)
        return report
    }

    // MARK: - Attachments

    private static func attachmentJobs(tables: [AirtableTable], records: [String: [AirtableRecord]]) -> [AirtableAttachment] {
        var jobs: [AirtableAttachment] = []
        var seen: Set<String> = []
        for table in tables {
            let fieldIDs = table.fields.filter { $0.type == "multipleAttachments" }.map(\.id)
            guard !fieldIDs.isEmpty else { continue }
            for record in records[table.id] ?? [] {
                for fieldID in fieldIDs {
                    for item in record.fields[fieldID]?.arrayValue ?? [] {
                        guard let id = item["id"]?.stringValue, !seen.contains(id),
                              let link = item["url"]?.stringValue, let url = URL(string: link),
                              url.scheme == "https" || url.scheme == "http"
                        else { continue }
                        seen.insert(id)
                        let filename = item["filename"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
                        jobs.append(AirtableAttachment(id: id, url: url, filename: filename))
                    }
                }
            }
        }
        return jobs
    }

    @MainActor
    private func downloadAttachments(
        _ jobs: [AirtableAttachment],
        storage: BaseStorage,
        progress: @MainActor (String, Double) -> Void
    ) async throws -> [String: AttachmentInfo] {
        guard !jobs.isEmpty else { return [:] }
        let fetcher = AirtableAttachmentFetcher(session: session, storage: storage, retryDelay: policy.retryDelay)
        var stored: [String: AttachmentInfo] = [:]
        var done = 0
        progress("Downloading attachments — 0 of \(jobs.count)…", 0.65)
        await withTaskGroup(of: (String, AttachmentInfo?).self) { group in
            var next = 0
            while next < min(policy.attachmentConcurrency, jobs.count) {
                let job = jobs[next]
                group.addTask { (job.id, await fetcher.fetch(job)) }
                next += 1
            }
            while let (id, info) = await group.next() {
                done += 1
                if let info { stored[id] = info }
                progress("Downloading attachments — \(done) of \(jobs.count)…", 0.65 + 0.25 * Double(done) / Double(jobs.count))
                if next < jobs.count, !Task.isCancelled {
                    let job = jobs[next]
                    group.addTask { (job.id, await fetcher.fetch(job)) }
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        return stored
    }
}

// MARK: - Airtable data

struct AirtableField: Sendable {
    let id: String
    let name: String
    let type: String
    let description: String
    let options: JSONValue
}

struct AirtableTable: Sendable {
    let id: String
    let name: String
    let description: String
    let primaryFieldID: String
    /// Primary field first, then Airtable's field order.
    let fields: [AirtableField]
    let gridViewName: String?
}

struct AirtableRecord: Sendable {
    let id: String
    let createdTime: Date?
    let fields: [String: JSONValue]
}

struct AirtableAttachment: Sendable {
    let id: String
    let url: URL
    let filename: String
}

// MARK: - HTTP

struct AirtableRequestPolicy: Sendable {
    /// Airtable allows 5 requests per second per base; spacing calls keeps comfortably under it.
    var minimumInterval: Duration = .milliseconds(220)
    var maxAttempts = 5
    var retryDelay: Duration = .seconds(1)
    /// Airtable asks clients to wait 30 seconds after a 429 before trying again.
    var rateLimitDelay: Duration = .seconds(30)
    var maxRetryAfter: Duration = .seconds(60)
    var attachmentConcurrency = 4

    static let standard = AirtableRequestPolicy()
}

/// Authenticated, throttled, retrying access to api.airtable.com.
actor AirtableAPIClient {
    private let token: String
    private let session: URLSession
    private let policy: AirtableRequestPolicy
    private let clock = ContinuousClock()
    private var nextSlot: ContinuousClock.Instant?

    init(token: String, session: URLSession, policy: AirtableRequestPolicy) {
        self.token = token
        self.session = session
        self.policy = policy
    }

    func basesPage(offset: String?) async throws -> (bases: [AirtableBaseSummary], offset: String?) {
        let json = try await get(["meta", "bases"], query: offset.map { [("offset", $0)] } ?? [])
        guard let items = json["bases"]?.arrayValue else { throw AirtableImportError.invalidResponse }
        let bases = items.compactMap { item -> AirtableBaseSummary? in
            guard let id = item["id"]?.stringValue else { return nil }
            return AirtableBaseSummary(
                id: id,
                name: item["name"]?.stringValue ?? id,
                permissionLevel: item["permissionLevel"]?.stringValue ?? "none"
            )
        }
        return (bases, json["offset"]?.stringValue)
    }

    func tables(baseID: String) async throws -> [AirtableTable] {
        let json = try await get(["meta", "bases", baseID, "tables"])
        guard let items = json["tables"]?.arrayValue else { throw AirtableImportError.invalidResponse }
        return items.compactMap { item -> AirtableTable? in
            guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else { return nil }
            var fields = (item["fields"]?.arrayValue ?? []).compactMap { f -> AirtableField? in
                guard let fid = f["id"]?.stringValue, let fname = f["name"]?.stringValue, let type = f["type"]?.stringValue else { return nil }
                return AirtableField(id: fid, name: fname, type: type, description: f["description"]?.stringValue ?? "", options: f["options"] ?? .null)
            }
            let primaryID = item["primaryFieldId"]?.stringValue ?? fields.first?.id
            guard let primaryID, let primaryIndex = fields.firstIndex(where: { $0.id == primaryID }) else { return nil }
            fields.insert(fields.remove(at: primaryIndex), at: 0)
            let grid = item["views"]?.arrayValue?.first { $0["type"]?.stringValue == "grid" }
            return AirtableTable(
                id: id,
                name: name,
                description: item["description"]?.stringValue ?? "",
                primaryFieldID: primaryID,
                fields: fields,
                gridViewName: grid?["name"]?.stringValue
            )
        }
    }

    func recordsPage(baseID: String, tableID: String, offset: String?) async throws -> (records: [AirtableRecord], offset: String?) {
        var query: [(String, String)] = [("pageSize", "100"), ("returnFieldsByFieldId", "true"), ("cellFormat", "json")]
        if let offset { query.append(("offset", offset)) }
        let json = try await get([baseID, tableID], query: query)
        guard let items = json["records"]?.arrayValue else { throw AirtableImportError.invalidResponse }
        let records = items.compactMap { item -> AirtableRecord? in
            guard let id = item["id"]?.stringValue else { return nil }
            return AirtableRecord(
                id: id,
                createdTime: item["createdTime"]?.stringValue.flatMap(DateCoding.parseISO),
                fields: item["fields"]?.objectValue ?? [:]
            )
        }
        return (records, json["offset"]?.stringValue)
    }

    private func get(_ path: [String], query: [(String, String)] = []) async throws -> JSONValue {
        var request = URLRequest(url: Self.url(path, query: query))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var attempt = 1
        while true {
            try await waitForSlot()
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < policy.maxAttempts, Self.isTransient(error) else {
                    throw AirtableImportError.network(error.localizedDescription)
                }
                try await Task.sleep(for: policy.retryDelay * (1 << (attempt - 1)))
                attempt += 1
                continue
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw AirtableImportError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                guard let json = try? JSONValue.parse(data) else { throw AirtableImportError.invalidResponse }
                return json
            case 429, 500...599:
                guard attempt < policy.maxAttempts else {
                    throw http.statusCode == 429
                        ? AirtableImportError.rateLimited
                        : AirtableImportError.server(status: http.statusCode, message: Self.errorMessage(data))
                }
                try await Task.sleep(for: retryDelay(after: http, attempt: attempt))
                attempt += 1
            case 401:
                throw AirtableImportError.unauthorized
            case 403:
                throw AirtableImportError.forbidden
            case 404:
                throw AirtableImportError.notFound
            default:
                throw AirtableImportError.server(status: http.statusCode, message: Self.errorMessage(data))
            }
        }
    }

    /// Spacing is measured from when each request is actually sent. The check and the reservation
    /// happen without a suspension point between them, so concurrent callers can't share a slot.
    private func waitForSlot() async throws {
        while let next = nextSlot, clock.now < next {
            try await clock.sleep(until: next)
        }
        nextSlot = clock.now.advanced(by: policy.minimumInterval)
    }

    private func retryDelay(after response: HTTPURLResponse, attempt: Int) -> Duration {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header), seconds >= 0 {
            return min(.milliseconds(Int(seconds * 1000)), policy.maxRetryAfter)
        }
        if response.statusCode == 429 { return policy.rateLimitDelay }
        return policy.retryDelay * (1 << (attempt - 1))
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse].contains(code)
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONValue.parse(data), let error = json["error"] else { return nil }
        return error["message"]?.stringValue ?? error.stringValue
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(_ path: [String], query: [(String, String)]) -> URL {
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        var text = "https://api.airtable.com/v0/" + path.map(encode).joined(separator: "/")
        if !query.isEmpty {
            text += "?" + query.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        }
        // Every component is percent-encoded to unreserved ASCII, so this always parses.
        return URL(string: text)!
    }
}

extension AirtableAPIClient: CustomReflectable {
    /// Keeps the token out of `dump()` and debugger descriptions.
    nonisolated var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

/// Downloads attachment files. Airtable serves them from pre-signed URLs, so requests never carry the API token.
struct AirtableAttachmentFetcher: Sendable {
    let session: URLSession
    let storage: BaseStorage
    let retryDelay: Duration
    let maxAttempts = 3

    func fetch(_ attachment: AirtableAttachment) async -> AttachmentInfo? {
        var request = URLRequest(url: attachment.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for attempt in 1...maxAttempts {
            if attempt > 1 { try? await Task.sleep(for: retryDelay * (attempt - 1)) }
            if Task.isCancelled { return nil }
            let result: (URL, URLResponse)
            do {
                result = try await session.download(for: request)
            } catch {
                continue
            }
            let (file, response) = result
            defer { try? FileManager.default.removeItem(at: file) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if (200..<300).contains(status) {
                return try? storage.importAttachment(data: Data(contentsOf: file, options: .mappedIfSafe), filename: attachment.filename)
            }
            if status != 429 && status < 500 { return nil }
        }
        return nil
    }
}

// MARK: - Building the base

/// Turns fetched Airtable data into RowHouse tables, fields and records.
@MainActor
final class AirtableBaseBuilder {
    private enum ValueMode {
        /// Convert Airtable's cell JSON into the field type's stored form.
        case value
        /// Owning side of a link: an array of record ids.
        case link
        /// Store Airtable's value as display text.
        case text
        /// Computed or derived in RowHouse: nothing is stored.
        case none
    }

    private struct Plan {
        var type: FieldType
        var options = FieldOptions()
        var mode: ValueMode
        /// Airtable choice name → RowHouse choice id.
        var choiceIDs: [String: String] = [:]
    }

    private struct RollupCandidate {
        let formula: String
        let evaluate: ([JSONValue]) -> JSONValue
    }

    static let chunkSize = 1_000

    private let document: BaseDocument
    private let tables: [AirtableTable]
    private let records: [String: [AirtableRecord]]
    private let attachments: [String: AttachmentInfo]

    private var tablesByID: [String: AirtableTable] = [:]
    private var fieldsByID: [String: (field: AirtableField, table: AirtableTable)] = [:]
    private var recordsByID: [String: AirtableRecord] = [:]
    private var plans: [String: Plan] = [:]
    /// Airtable id → RowHouse id, for tables, fields and records.
    private var tableIDs: [String: String] = [:]
    private var fieldIDs: [String: String] = [:]
    private var recordIDs: [String: String] = [:]
    private var warnings: [String] = []

    init(document: BaseDocument, tables: [AirtableTable], records: [String: [AirtableRecord]], attachments: [String: AttachmentInfo]) {
        self.document = document
        self.tables = tables
        self.records = records
        self.attachments = attachments
    }

    func build(progress: @MainActor (String, Double) -> Void) async throws -> ImportReport {
        for table in tables {
            tablesByID[table.id] = table
            for field in table.fields { fieldsByID[field.id] = (field, table) }
            for record in records[table.id] ?? [] {
                recordsByID[record.id] = record
                recordIDs[record.id] = RowID.record()
            }
        }
        for table in tables {
            for field in table.fields { plans[field.id] = plan(field, in: table) }
        }

        withoutUndo {
            document.batch("Import from Airtable") {
                createTables()
                createFields()
                configureComputedFields()
                applyFieldOrder()
            }
        }

        let total = max(1, records.values.reduce(0) { $0 + $1.count })
        var written = 0
        for table in tables {
            guard let tableID = tableIDs[table.id] else { continue }
            let mutations = recordMutations(for: table, tableID: tableID)
            for start in stride(from: 0, to: mutations.count, by: Self.chunkSize) {
                try Task.checkCancellation()
                progress("Adding records to “\(table.name)”…", 0.9 + 0.1 * Double(written) / Double(total))
                await Task.yield()
                let chunk = Array(mutations[start..<min(start + Self.chunkSize, mutations.count)])
                withoutUndo { document.commit(chunk, actionName: "Import from Airtable") }
                written += chunk.count
            }
        }

        var report = ImportReport()
        report.tables = tableIDs.count
        report.fields = tableIDs.values.reduce(0) { $0 + document.fields(in: $1).count }
        report.records = written
        var seen: Set<String> = []
        report.warnings = warnings.filter { seen.insert($0).inserted }
        return report
    }

    private func withoutUndo(_ body: () -> Void) {
        let manager = document.undoManager
        document.undoManager = nil
        body()
        document.undoManager = manager
    }

    // MARK: Schema

    private func createTables() {
        for table in tables {
            let id = document.createTable(name: table.name, starterFields: false, emptyRecords: 0)
            tableIDs[table.id] = id
            if !table.description.isEmpty { document.updateTableDescription(id, table.description) }
            if let viewName = table.gridViewName, let grid = document.views(in: id).first {
                document.renameView(grid.id, to: viewName)
            }
            // Name every primary field up front so auto-named inverse link fields can't take their names.
            if let primary = document.primaryField(of: id), let field = table.fields.first {
                fieldIDs[field.id] = primary.id
                document.renameField(primary.id, to: field.name)
            }
        }
    }

    private func createFields() {
        for table in tables {
            guard let tableID = tableIDs[table.id] else { continue }
            for field in table.fields {
                guard let plan = plans[field.id] else { continue }
                if field.id == table.primaryFieldID {
                    guard let id = fieldIDs[field.id] else { continue }
                    if !plan.type.isComputed && (plan.type != .singleLineText || plan.options != FieldOptions()) {
                        document.updateField(id, type: plan.type, options: plan.options)
                    }
                    if !field.description.isEmpty { document.updateField(id, description: field.description) }
                    continue
                }
                if let existing = fieldIDs[field.id] {
                    // Already created as the inverse side of a link defined earlier.
                    if !field.description.isEmpty { document.updateField(existing, description: field.description) }
                    continue
                }
                if plan.mode == .link {
                    createLink(field, in: table, tableID: tableID)
                } else {
                    fieldIDs[field.id] = document.createField(in: tableID, name: field.name, type: plan.type, options: plan.options, description: field.description)
                }
            }
        }
    }

    /// Creates the owning side of a link. RowHouse adds the inverse field automatically; it becomes
    /// Airtable's paired field, or is removed when the Airtable link is one-way.
    private func createLink(_ field: AirtableField, in table: AirtableTable, tableID: String) {
        guard let linkedTable = field.options["linkedTableId"]?.stringValue, let target = tableIDs[linkedTable] else { return }
        var options = FieldOptions()
        options.linkedTableID = target
        if field.options["prefersSingleRecordLink"]?.boolValue == true { options.singleRecordLink = true }
        let id = document.createField(in: tableID, name: field.name, type: .link, options: options, description: field.description)
        fieldIDs[field.id] = id
        guard let inverseID = document.field(id)?.options.inverseFieldID else { return }

        if let pairID = field.options["inverseLinkFieldId"]?.stringValue,
           let pair = fieldsByID[pairID]?.field, fieldsByID[pairID]?.table.id == linkedTable,
           pair.type == "multipleRecordLinks", pair.options["linkedTableId"]?.stringValue == table.id,
           fieldIDs[pairID] == nil {
            fieldIDs[pairID] = inverseID
            plans[pairID]?.mode = .none
            document.renameField(inverseID, to: pair.name)
            if pair.options["prefersSingleRecordLink"]?.boolValue == true, var inverseOptions = document.field(inverseID)?.options {
                inverseOptions.singleRecordLink = true
                document.updateField(inverseID, options: inverseOptions)
            }
        } else {
            document.deleteField(inverseID)
        }
    }

    private func configureComputedFields() {
        for table in tables {
            for field in table.fields {
                guard let plan = plans[field.id], plan.type.isComputed, let id = fieldIDs[field.id] else { continue }
                var options = plan.options
                let o = field.options
                switch plan.type {
                case .formula:
                    options.formula = rewriteFieldReferences(o["formula"]?.stringValue ?? "", in: table)
                    Self.applyResult(o["result"], to: &options)
                case .lookup:
                    options.linkFieldID = o["recordLinkFieldId"]?.stringValue.flatMap { fieldIDs[$0] }
                    options.targetFieldID = o["fieldIdInLinkedTable"]?.stringValue.flatMap { fieldIDs[$0] }
                case .rollup:
                    options.linkFieldID = o["recordLinkFieldId"]?.stringValue.flatMap { fieldIDs[$0] }
                    options.targetFieldID = o["fieldIdInLinkedTable"]?.stringValue.flatMap { fieldIDs[$0] }
                    options.rollupFormula = rollupFormula(for: field, in: table)
                    Self.applyResult(o["result"], to: &options)
                case .count:
                    options.linkFieldID = o["recordLinkFieldId"]?.stringValue.flatMap { fieldIDs[$0] }
                case .lastModifiedTime:
                    let referenced = Set(o["referencedFieldIds"]?.stringArray ?? [])
                    let others = Set(table.fields.map(\.id)).subtracting([field.id])
                    if !referenced.isEmpty && !others.isSubset(of: referenced) {
                        options.watchedFieldIDs = table.fields.filter { referenced.contains($0.id) }.compactMap { fieldIDs[$0.id] }
                    }
                case .button:
                    configureButton(field, in: table, options: &options)
                default:
                    break
                }
                let isPrimary = field.id == table.primaryFieldID
                document.updateField(id, type: isPrimary ? plan.type : nil, options: options)
            }
        }
    }

    private func configureButton(_ field: AirtableField, in table: AirtableTable, options: inout FieldOptions) {
        let rows = records[table.id] ?? []
        let cells = rows.compactMap { $0.fields[field.id] }
        options.buttonAction = .openURL
        options.buttonLabel = field.options["label"]?.stringValue
            ?? cells.lazy.compactMap { $0["label"]?.stringValue }.first
            ?? "Open"
        if let formula = field.options["url"]?["formula"]?.stringValue ?? field.options["urlFormula"]?.stringValue {
            options.buttonURLFormula = rewriteFieldReferences(formula, in: table)
            return
        }
        let urls = cells.compactMap { $0["url"]?.stringValue }
        guard let first = urls.first else { return }
        if urls.count == rows.count && urls.allSatisfy({ $0 == first }) {
            let escaped = first.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            options.buttonURLFormula = "\"\(escaped)\""
        } else {
            warnings.append("“\(field.name)” in “\(table.name)”: Airtable doesn't share button URL formulas, so the button has no link yet. Set one in the field settings.")
        }
    }

    /// Fields are created in Airtable order, but inverse link fields appear in their table when the
    /// owning side is created; this puts every table's fields back in Airtable's order.
    private func applyFieldOrder() {
        for table in tables {
            guard let tableID = tableIDs[table.id] else { continue }
            var mutations: [Mutation] = []
            for (index, field) in table.fields.enumerated() {
                guard let id = fieldIDs[field.id], let current = document.field(id), current.tableID == tableID,
                      current.order != Double(index) else { continue }
                mutations.append(Mutation(.field, id, ["order": .number(Double(index))]))
            }
            document.commit(mutations, actionName: "Import from Airtable")
        }
    }

    // MARK: Planning

    private func plan(_ field: AirtableField, in table: AirtableTable) -> Plan {
        let o = field.options
        var options = FieldOptions()
        var plan: Plan
        switch field.type {
        case "singleLineText":
            plan = Plan(type: .singleLineText, mode: .value)
        case "multilineText", "richText":
            plan = Plan(type: .multilineText, mode: .value)
        case "email":
            plan = Plan(type: .email, mode: .value)
        case "url":
            plan = Plan(type: .url, mode: .value)
        case "phoneNumber":
            plan = Plan(type: .phoneNumber, mode: .value)
        case "number":
            options.precision = Self.int(o["precision"])
            plan = Plan(type: .number, options: options, mode: .value)
        case "currency":
            options.precision = Self.int(o["precision"])
            options.currencySymbol = o["symbol"]?.stringValue
            plan = Plan(type: .currency, options: options, mode: .value)
        case "percent":
            options.precision = Self.int(o["precision"])
            plan = Plan(type: .percent, options: options, mode: .value)
        case "duration":
            options.durationFormat = Self.durationFormat(o["durationFormat"])
            plan = Plan(type: .duration, options: options, mode: .value)
        case "rating":
            options.ratingMax = Self.int(o["max"])
            plan = Plan(type: .rating, options: options, mode: .value)
        case "checkbox":
            plan = Plan(type: .checkbox, mode: .value)
        case "singleSelect", "multipleSelects":
            plan = selectPlan(field, in: table)
        case "date":
            options.includeTime = false
            options.dateFormat = Self.dateFormat(o["dateFormat"])
            plan = Plan(type: .date, options: options, mode: .value)
        case "dateTime":
            options.includeTime = true
            options.dateFormat = Self.dateFormat(o["dateFormat"])
            options.use24HourClock = Self.uses24HourClock(o["timeFormat"])
            plan = Plan(type: .date, options: options, mode: .value)
        case "multipleAttachments":
            plan = Plan(type: .attachment, mode: .value)
        case "multipleRecordLinks":
            if let linked = o["linkedTableId"]?.stringValue, tablesByID[linked] != nil {
                plan = Plan(type: .link, mode: .link)
            } else {
                warnings.append("“\(field.name)” in “\(table.name)” links to a table the token can't read, so its values were imported as text.")
                plan = textPlan(field, in: table)
            }
        case "multipleLookupValues", "rollup":
            let kind: FieldType = field.type == "rollup" ? .rollup : .lookup
            if relationIsImportable(field, in: table, needsTarget: true) {
                plan = Plan(type: kind, mode: .none)
            } else {
                warnings.append("“\(field.name)” in “\(table.name)” isn't a working \(kind == .rollup ? "rollup" : "lookup") in Airtable or depends on a table the token can't read, so its values were imported as text.")
                plan = textPlan(field, in: table)
            }
        case "count":
            if relationIsImportable(field, in: table, needsTarget: false) {
                plan = Plan(type: .count, mode: .none)
            } else {
                warnings.append("“\(field.name)” in “\(table.name)” isn't a working count in Airtable or depends on a table the token can't read, so its values were imported as numbers.")
                plan = Plan(type: .number, options: options, mode: .value)
            }
        case "formula":
            plan = Plan(type: .formula, mode: .none)
        case "createdTime", "lastModifiedTime":
            let result = o["result"]
            options.includeTime = result?["type"]?.stringValue != "date"
            options.dateFormat = Self.dateFormat(result?["options"]?["dateFormat"])
            options.use24HourClock = Self.uses24HourClock(result?["options"]?["timeFormat"])
            plan = Plan(type: field.type == "createdTime" ? .createdTime : .lastModifiedTime, options: options, mode: .none)
        case "autoNumber":
            plan = Plan(type: .autoNumber, mode: .none)
        case "button":
            plan = Plan(type: .button, mode: .none)
        case "aiText":
            warnings.append("“\(field.name)” in “\(table.name)” is an AI field; its current text was imported as long text.")
            plan = Plan(type: .multilineText, mode: .text)
        default:
            warnings.append("“\(field.name)” in “\(table.name)” is \(Self.describe(field.type)) field, which RowHouse doesn't have; its values were imported as text.")
            plan = textPlan(field, in: table)
        }
        if field.id == table.primaryFieldID && !plan.type.canBePrimary {
            warnings.append("“\(field.name)”, the primary field of “\(table.name)”, can't be a primary field in RowHouse as \(Self.describe(field.type)) field; its values were imported as text.")
            plan = textPlan(field, in: table)
        }
        return plan
    }

    private func textPlan(_ field: AirtableField, in table: AirtableTable) -> Plan {
        let multiline = (records[table.id] ?? []).contains { record in
            record.fields[field.id].map { Self.displayText($0).contains("\n") } ?? false
        }
        return Plan(type: multiline ? .multilineText : .singleLineText, mode: .text)
    }

    private func selectPlan(_ field: AirtableField, in table: AirtableTable) -> Plan {
        var choices: [SelectChoice] = []
        var ids: [String: String] = [:]
        func add(_ name: String, color: String?) {
            guard !name.isEmpty, ids[name] == nil else { return }
            let choice = SelectChoice(name: name, color: Self.choiceColor(color, index: choices.count))
            choices.append(choice)
            ids[name] = choice.id
        }
        for choice in field.options["choices"]?.arrayValue ?? [] {
            if let name = choice["name"]?.stringValue { add(name, color: choice["color"]?.stringValue) }
        }
        // Values can name options that were since removed from the field; keep them rather than drop data.
        for record in records[table.id] ?? [] {
            guard let value = record.fields[field.id] else { continue }
            for name in Self.selectNames(value) { add(name, color: nil) }
        }
        var options = FieldOptions()
        options.choices = choices
        return Plan(type: field.type == "singleSelect" ? .singleSelect : .multipleSelects, options: options, mode: .value, choiceIDs: ids)
    }

    /// True when a lookup/rollup/count points at an imported link field (and, if needed, a field of the linked table).
    private func relationIsImportable(_ field: AirtableField, in table: AirtableTable, needsTarget: Bool) -> Bool {
        let o = field.options
        guard o["isValid"]?.boolValue != false,
              let linkID = o["recordLinkFieldId"]?.stringValue,
              let link = fieldsByID[linkID], link.table.id == table.id, link.field.type == "multipleRecordLinks",
              let linkedTable = link.field.options["linkedTableId"]?.stringValue, tablesByID[linkedTable] != nil
        else { return false }
        guard needsTarget else { return true }
        guard let targetID = o["fieldIdInLinkedTable"]?.stringValue, let target = fieldsByID[targetID] else { return false }
        return target.table.id == linkedTable
    }

    // MARK: Formulas

    /// Rewrites `{fldXXXX}` (how the API returns references) and `{Field Name}` references to RowHouse
    /// field ids, leaving string literals untouched.
    private func rewriteFieldReferences(_ source: String, in table: AirtableTable) -> String {
        Self.rewriteBraces(in: source) { reference in
            if let entry = fieldsByID[reference], entry.table.id == table.id { return fieldIDs[reference] }
            if let named = table.fields.first(where: { $0.name == reference }) { return fieldIDs[named.id] }
            return nil
        }
    }

    nonisolated static func rewriteBraces(in source: String, _ resolve: (String) -> String?) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var quote: Character?
        var index = source.startIndex
        while index < source.endIndex {
            let c = source[index]
            if let q = quote {
                out.append(c)
                if c == "\\" {
                    let next = source.index(after: index)
                    if next < source.endIndex {
                        out.append(source[next])
                        index = source.index(after: next)
                        continue
                    }
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
                out.append(c)
            } else if c == "{", let close = source[index...].firstIndex(of: "}") {
                let reference = String(source[source.index(after: index)..<close])
                if let replacement = resolve(reference) {
                    out += "{\(replacement)}"
                } else {
                    out += source[index...close]
                }
                index = source.index(after: close)
                continue
            } else {
                out.append(c)
            }
            index = source.index(after: index)
        }
        return out
    }

    /// Airtable's API doesn't expose rollup aggregation formulas, so the formula is inferred by
    /// checking which aggregation reproduces Airtable's computed values from the linked records.
    private func rollupFormula(for field: AirtableField, in table: AirtableTable) -> String {
        if let explicit = field.options["formula"]?.stringValue, let known = Self.recognisedRollup(explicit) {
            return known
        }
        let resultType = field.options["result"]?["type"]?.stringValue
        let linkID = field.options["recordLinkFieldId"]?.stringValue ?? ""
        let targetID = field.options["fieldIdInLinkedTable"]?.stringValue ?? ""
        var remaining = Self.rollupCandidates(resultType: resultType)
        var evidence = 0
        for record in records[table.id] ?? [] {
            let linked = Self.linkedIDs(record.fields[linkID])
            guard !linked.isEmpty, let actual = record.fields[field.id] else { continue }
            let values = linked.map { recordsByID[$0]?.fields[targetID] ?? .null }
            remaining.removeAll { !Self.sameValue($0.evaluate(values), actual) }
            evidence += 1
            if remaining.isEmpty || evidence >= 500 { break }
        }
        if evidence > 0, let match = remaining.first { return match.formula }
        let fallback = Self.defaultRollup(resultType: resultType)
        warnings.append("“\(field.name)” in “\(table.name)”: Airtable doesn't share rollup formulas and it couldn't be worked out from the data, so it was set to \(fallback). Check it in the field settings.")
        return fallback
    }

    nonisolated private static let rollupFunctions: Set<String> = [
        "SUM", "MAX", "MIN", "AVERAGE", "COUNT", "COUNTA", "COUNTALL", "AND", "OR", "XOR",
        "ARRAYJOIN", "ARRAYUNIQUE", "ARRAYCOMPACT", "ARRAYFLATTEN", "CONCATENATE",
    ]

    nonisolated static func recognisedRollup(_ formula: String) -> String? {
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces).uppercased()
        let argument = trimmed[trimmed.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
        guard rollupFunctions.contains(name), argument == "values" || argument.hasPrefix("values,") || argument.hasPrefix("values ,") else { return nil }
        return trimmed
    }

    nonisolated private static func defaultRollup(resultType: String?) -> String {
        switch resultType {
        case "number", "currency", "percent", "duration", "rating": "SUM(values)"
        case "checkbox": "AND(values)"
        case "date", "dateTime": "MAX(values)"
        default: "ARRAYJOIN(values)"
        }
    }

    nonisolated private static func rollupCandidates(resultType: String?) -> [RollupCandidate] {
        func numbers(_ values: [JSONValue]) -> [Double] { flatten(values).compactMap(\.numberValue) }
        func dates(_ values: [JSONValue]) -> [Date] { flatten(values).compactMap { $0.stringValue.flatMap { DateCoding.decode($0, timeZone: .gmt) } } }
        func number(_ n: Double?) -> JSONValue { n.map(JSONValue.number) ?? .null }
        func date(_ d: Date?) -> JSONValue { d.map { .string(DateCoding.iso8601String($0)) } ?? .null }
        switch resultType {
        case "checkbox":
            return [
                RollupCandidate(formula: "AND(values)") { .bool(!flatten($0).isEmpty && flatten($0).allSatisfy(isTruthy)) },
                RollupCandidate(formula: "OR(values)") { .bool(flatten($0).contains(where: isTruthy)) },
            ]
        case "date", "dateTime":
            return [
                RollupCandidate(formula: "MAX(values)") { date(dates($0).max()) },
                RollupCandidate(formula: "MIN(values)") { date(dates($0).min()) },
            ]
        case "number", "currency", "percent", "duration", "rating", nil:
            let numeric = [
                RollupCandidate(formula: "SUM(values)") { .number(numbers($0).reduce(0, +)) },
                RollupCandidate(formula: "MAX(values)") { number(numbers($0).max()) },
                RollupCandidate(formula: "MIN(values)") { number(numbers($0).min()) },
                RollupCandidate(formula: "AVERAGE(values)") { let n = numbers($0); return number(n.isEmpty ? nil : n.reduce(0, +) / Double(n.count)) },
                RollupCandidate(formula: "COUNTA(values)") { .number(Double(flatten($0).filter { !$0.isEmptyCell }.count)) },
                RollupCandidate(formula: "COUNT(values)") { .number(Double(numbers($0).count)) },
                RollupCandidate(formula: "COUNTALL(values)") { .number(Double(flatten($0).count)) },
            ]
            return resultType == nil ? numeric + textRollupCandidates : numeric
        default:
            return textRollupCandidates
        }
    }

    nonisolated private static var textRollupCandidates: [RollupCandidate] {
        [
            RollupCandidate(formula: "ARRAYJOIN(values)") { .string(flatten($0).map(displayText).filter { !$0.isEmpty }.joined(separator: ", ")) },
            RollupCandidate(formula: "CONCATENATE(values)") { .string(flatten($0).map(displayText).joined()) },
        ]
    }

    nonisolated private static func flatten(_ values: [JSONValue]) -> [JSONValue] {
        values.flatMap { value -> [JSONValue] in
            if case .array(let items) = value { return flatten(items) }
            return [value]
        }
    }

    nonisolated private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): !s.isEmpty
        case .array(let a): !a.isEmpty
        case .object: true
        case .null: false
        }
    }

    nonisolated private static func sameValue(_ computed: JSONValue, _ actual: JSONValue) -> Bool {
        switch (computed, actual) {
        case (.number(let a), .number(let b)):
            return abs(a - b) <= 1e-6 * max(1, abs(a), abs(b))
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            if a == b { return true }
            guard let da = DateCoding.decode(a, timeZone: .gmt), let db = DateCoding.decode(b, timeZone: .gmt) else { return false }
            return abs(da.timeIntervalSince(db)) < 1
        default:
            return false
        }
    }

    // MARK: Records

    private func recordMutations(for table: AirtableTable, tableID: String) -> [Mutation] {
        let rows = Array((records[table.id] ?? []).enumerated())
        // Autonumbers follow the order records are created in, so create them in Airtable's numbering order.
        var creationOrder = rows
        if let autoNumber = table.fields.first(where: { $0.type == "autoNumber" })?.id {
            creationOrder.sort { a, b in
                let x = a.element.fields[autoNumber]?.numberValue ?? .infinity
                let y = b.element.fields[autoNumber]?.numberValue ?? .infinity
                return x != y ? x < y : a.offset < b.offset
            }
        }
        let now = Date().timeIntervalSince1970 * 1000
        var mutations: [Mutation] = []
        mutations.reserveCapacity(rows.count)
        for (index, record) in creationOrder {
            guard let id = recordIDs[record.id] else { continue }
            var set: [String: JSONValue] = [
                "_table": .string(tableID),
                "_order": .number(Double(index + 1)),
                "_created": .number(record.createdTime.map { $0.timeIntervalSince1970 * 1000 } ?? now),
                "_deleted": .bool(false),
            ]
            for (airtableFieldID, raw) in record.fields {
                guard let fieldID = fieldIDs[airtableFieldID], let plan = plans[airtableFieldID],
                      let value = storedValue(raw, plan: plan) else { continue }
                set[fieldID] = value
            }
            mutations.append(Mutation(.record, id, set))
        }
        return mutations
    }

    private func storedValue(_ raw: JSONValue, plan: Plan) -> JSONValue? {
        switch plan.mode {
        case .none:
            return nil
        case .text:
            let text = Self.displayText(raw)
            return text.isEmpty ? nil : .string(text)
        case .link:
            let ids = Self.linkedIDs(raw).compactMap { recordIDs[$0] }
            return ids.isEmpty ? nil : .array(ids.map(JSONValue.string))
        case .value:
            break
        }
        switch plan.type {
        case .singleLineText, .multilineText, .email, .url, .phoneNumber:
            let text = raw.stringValue ?? Self.displayText(raw)
            return text.isEmpty ? nil : .string(text)
        case .number, .currency, .percent, .duration, .rating:
            if let n = raw.numberValue, n.isFinite { return .number(n) }
            return raw.stringValue.flatMap { ValueParsing.number(from: $0) }.map(JSONValue.number)
        case .checkbox:
            return raw.boolValue == true ? .bool(true) : nil
        case .singleSelect:
            return Self.selectNames(raw).first.flatMap { plan.choiceIDs[$0] }.map(JSONValue.string)
        case .multipleSelects:
            let ids = Self.selectNames(raw).compactMap { plan.choiceIDs[$0] }
            return ids.isEmpty ? nil : .array(ids.map(JSONValue.string))
        case .date:
            guard let text = raw.stringValue else { return nil }
            if plan.options.includeTime == true {
                return DateCoding.parseISO(text).map { .string(DateCoding.encode($0, includeTime: true)) }
            }
            if text.count == 10, DateCoding.dayDate(text) != nil { return .string(text) }
            return DateCoding.parseISO(text).map { .string(DateCoding.encode($0, includeTime: false, timeZone: .gmt)) }
        case .attachment:
            let infos = (raw.arrayValue ?? []).compactMap { $0["id"]?.stringValue.flatMap { attachments[$0] } }
            return infos.isEmpty ? nil : JSONValue(encoding: infos)
        case .link, .lookup, .rollup, .count, .formula, .createdTime, .lastModifiedTime, .autoNumber, .button:
            return nil
        }
    }

    // MARK: Value helpers

    nonisolated private static func selectNames(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .array(let items): return items.flatMap(selectNames)
        case .object(let o): return o["name"]?.stringValue.map { [$0] } ?? []
        default: return []
        }
    }

    nonisolated static func linkedIDs(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["id"]?.stringValue }
    }

    /// Readable text for any Airtable cell: collaborators by name or email, barcodes by their text,
    /// AI fields by their value, arrays joined with commas.
    nonisolated static func displayText(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .string(let s):
            return s
        case .number(let n):
            return CellFormatter.number(n, precision: nil)
        case .bool(let b):
            return b ? "true" : "false"
        case .array(let items):
            return items.map(displayText).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object(let o):
            for key in ["name", "text", "value", "label", "filename", "email", "url", "id"] {
                if let v = o[key], !v.isNull {
                    let text = displayText(v)
                    if !text.isEmpty { return text }
                }
            }
            return ""
        }
    }

    nonisolated static func choiceColor(_ airtableColor: String?, index: Int) -> ChoiceColor {
        // Airtable colours are a hue plus a shade, e.g. "blueLight2", "greenBright", "grayDark1".
        if let name = airtableColor?.lowercased(), let match = ChoiceColor.allCases.first(where: { name.hasPrefix($0.rawValue) }) {
            return match
        }
        return .cycling(index)
    }

    nonisolated private static func int(_ value: JSONValue?) -> Int? {
        value?.numberValue.map { Int($0) }
    }

    nonisolated private static func durationFormat(_ value: JSONValue?) -> DurationFormat {
        value?.stringValue == "h:mm" ? .hoursMinutes : .hoursMinutesSeconds
    }

    nonisolated private static func dateFormat(_ value: JSONValue?) -> DateDisplayFormat? {
        value?["name"]?.stringValue.flatMap(DateDisplayFormat.init(rawValue:))
    }

    nonisolated private static func uses24HourClock(_ value: JSONValue?) -> Bool? {
        value?["name"]?.stringValue.map { $0 == "24hour" }
    }

    nonisolated private static func applyResult(_ result: JSONValue?, to options: inout FieldOptions) {
        let resultOptions = result?["options"]
        switch result?["type"]?.stringValue {
        case "number":
            options.resultFormat = .number
            options.precision = int(resultOptions?["precision"])
        case "currency":
            options.resultFormat = .currency
            options.precision = int(resultOptions?["precision"])
            options.currencySymbol = resultOptions?["symbol"]?.stringValue
        case "percent":
            options.resultFormat = .percent
            options.precision = int(resultOptions?["precision"])
        case "duration":
            options.resultFormat = .duration
            options.durationFormat = durationFormat(resultOptions?["durationFormat"])
        case "date":
            options.resultFormat = .date
            options.dateFormat = dateFormat(resultOptions?["dateFormat"])
        case "dateTime":
            options.resultFormat = .dateTime
            options.dateFormat = dateFormat(resultOptions?["dateFormat"])
            options.use24HourClock = uses24HourClock(resultOptions?["timeFormat"])
        default:
            options.resultFormat = .automatic
        }
    }

    nonisolated private static func describe(_ airtableType: String) -> String {
        switch airtableType {
        case "singleCollaborator", "multipleCollaborators": "a collaborator"
        case "createdBy": "a created-by"
        case "lastModifiedBy": "a last-modified-by"
        case "barcode": "a barcode"
        case "externalSyncSource": "a sync source"
        case "aiText": "an AI"
        case "multipleLookupValues": "a lookup"
        case "rollup": "a rollup"
        case "count": "a count"
        case "multipleRecordLinks": "a link"
        case "multipleAttachments": "an attachment"
        case "multipleSelects": "a multiple select"
        case "checkbox": "a checkbox"
        case "rating": "a rating"
        case "button": "a button"
        default: "an “\(airtableType)”"
        }
    }
}
