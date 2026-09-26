import Foundation
import RowHouseCore

/// A Model Context Protocol server exposing the user's RowHouse bases as tools. It speaks JSON-RPC 2.0,
/// one message per line; `handle(_:)` takes one line and returns the reply line (nil for notifications).
///
/// The server is a device of every base it touches: it reads all devices' logs and snapshots but writes
/// only to its own `devices/<id>` folder, so the RowHouse app (and other Macs, through iCloud Drive)
/// merge its edits like any other device's.
@MainActor
public final class MCPServer {
    public struct Configuration: Sendable {
        /// The library folder; nil resolves it the way the app does.
        public var libraryRoot: URL?
        /// Where agent slot locks live.
        public var lockDirectory: URL
        /// This Mac's device id; the server's device id is derived from it.
        public var hostDeviceID: String
        public var version: String

        public init(libraryRoot: URL? = nil, lockDirectory: URL? = nil, hostDeviceID: String? = nil, version: String? = nil) {
            self.libraryRoot = libraryRoot
            self.lockDirectory = lockDirectory ?? AgentIdentity.defaultLockDirectory
            self.hostDeviceID = hostDeviceID ?? DeviceIdentity.current.id
            self.version = version ?? MCPServer.appVersion
        }
    }

    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultDeviceName = "AI assistant (MCP)"

    let configuration: Configuration
    let workspace: Workspace
    private(set) var protocolVersion = MCPServer.supportedProtocolVersions[0]
    private lazy var tools: [String: Tool] = Dictionary(uniqueKeysWithValues: Tools.all.map { ($0.name, $0) })

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let library = Library(rootURL: configuration.libraryRoot ?? Self.libraryRoot(defaults: Self.appDefaults))
        let agent = AgentIdentity(hostDeviceID: configuration.hostDeviceID, lockDirectory: configuration.lockDirectory)
        workspace = Workspace(library: library, agent: agent, deviceName: Self.defaultDeviceName)
        Log.info("library \(library.rootURL.path), device \(agent.deviceID)")
    }

    /// The device id this server writes as.
    public var deviceID: String { workspace.agent.deviceID }

    /// The library folder in use.
    public var libraryURL: URL { workspace.library.rootURL }

    /// The app's preferences (for the storage location chosen in Settings), also when this helper is
    /// run on its own rather than from inside RowHouse.app.
    nonisolated static var appDefaults: UserDefaults {
        let domain = "com.rellwood.RowHouse"
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    /// The app's library folder. When macOS privacy settings stop this process from even looking at
    /// iCloud Drive, the iCloud folder is kept anyway, so tools explain how to grant access instead of
    /// quietly showing a different, local library.
    static func libraryRoot(defaults: UserDefaults) -> URL {
        let resolved = Library.resolveRoot(defaults: defaults)
        let override = ProcessInfo.processInfo.environment["ROWHOUSE_LIBRARY_PATH"] ?? ""
        let chosen = defaults.string(forKey: Library.customPathKey) ?? ""
        guard override.isEmpty, chosen.isEmpty, Library.iCloudDriveRoot == nil else { return resolved }
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: cloudDocs.path)
        } catch {
            if isPermissionError(error) { return cloudDocs.appendingPathComponent("RowHouse", isDirectory: true) }
        }
        return resolved
    }

    private nonisolated static func isPermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError { return true }
            if e.domain == NSPOSIXErrorDomain && (e.code == Int(EPERM) || e.code == Int(EACCES)) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The version of the RowHouse.app this helper ships in.
    nonisolated static var appVersion: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
        let plist = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        if let plist, let info = NSDictionary(contentsOf: plist), let v = info["CFBundleShortVersionString"] as? String { return v }
        return "1.0.0"
    }

    // MARK: - Messages

    /// Handles one line of input: a request, a notification, or a batch of them.
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed) else {
            return JSONText.compact(JSONRPC.error(id: .null, RPCError(RPCError.parseError, "Parse error: not valid JSON")))
        }
        if let batch = message.arrayValue {
            guard !batch.isEmpty else {
                return JSONText.compact(JSONRPC.error(id: .null, RPCError(RPCError.invalidRequest, "Invalid request: empty batch")))
            }
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await handle(message: item) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : JSONText.compact(.array(replies))
        }
        return await handle(message: message).map(JSONText.compact)
    }

    private func handle(message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue else {
            return JSONRPC.error(id: .null, RPCError(RPCError.invalidRequest, "Invalid request: expected a JSON object"))
        }
        let id = object["id"]
        if let id, !Self.isValidID(id) {
            return JSONRPC.error(id: .null, RPCError(RPCError.invalidRequest, "Invalid request: id must be a string or a number, not null"))
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            return JSONRPC.error(id: id ?? .null, RPCError(RPCError.invalidRequest, "Invalid request: jsonrpc must be \"2.0\""))
        }
        guard let method = object["method"]?.stringValue else {
            // A response to a request we never send, or garbage: responses are ignored.
            if object["result"] != nil || object["error"] != nil { return nil }
            return JSONRPC.error(id: id ?? .null, RPCError(RPCError.invalidRequest, "Invalid request: missing method"))
        }
        let params = object["params"]
        if let params, params.objectValue == nil, params.arrayValue == nil, !params.isNull {
            return id.map { JSONRPC.error(id: $0, RPCError(RPCError.invalidParams, "params must be an object")) }
        }
        guard let id else {
            handleNotification(method, params: params)
            return nil
        }
        do {
            return JSONRPC.result(id: id, try await dispatch(method, params: params))
        } catch let error as RPCError {
            return JSONRPC.error(id: id, error)
        } catch {
            return JSONRPC.error(id: id, RPCError(RPCError.internalError, "Internal error: \(error.localizedDescription)"))
        }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: true
        default: false
        }
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        switch method {
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            break
        default:
            Log.info("ignoring notification \(method)")
        }
    }

    private func dispatch(_ method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "initialize":
            return initialize(params)
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(Tools.all.map { $0.definition })])
        case "tools/call":
            return try await callTool(params)
        default:
            throw RPCError(RPCError.methodNotFound, "Method not found: \(method)")
        }
    }

    private func initialize(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        protocolVersion = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
        if let info = params?["clientInfo"] {
            workspace.introduce(client: Self.friendlyClientName(name: info["name"]?.stringValue, title: info["title"]?.stringValue))
        }
        return .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object(["tools": .object(["listChanged": false])]),
            "serverInfo": .object([
                "name": "rowhouse",
                "title": "RowHouse",
                "version": .string(configuration.version),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    /// "Claude Code" for "claude-code" and so on; other clients keep their own title or name.
    static func friendlyClientName(name: String?, title: String?) -> String {
        let known = [
            "claude-code": "Claude Code",
            "claude-ai": "Claude",
            "claude-desktop": "Claude",
            "codex-mcp-client": "Codex",
            "codex": "Codex",
            "cursor-vscode": "Cursor",
            "visual studio code": "VS Code",
            "zed": "Zed",
        ]
        if let name, let friendly = known[name.lowercased()] { return friendly }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return String(title.prefix(60)) }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return String(name.prefix(60)) }
        return "AI assistant"
    }

    private func callTool(_ params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw RPCError(RPCError.invalidParams, "tools/call needs the name of a tool")
        }
        guard let tool = tools[name] else {
            throw RPCError(RPCError.invalidParams, "Unknown tool: \(name). Call tools/list for the available tools.")
        }
        do {
            let arguments = try ToolArguments(params?["arguments"], allowed: tool.argumentNames)
            let result = try await tool.run(arguments, workspace)
            return toolResult(result, isError: false)
        } catch let error as ToolError {
            return toolResult(.object(["error": .string(error.message)]), isError: true, text: error.message)
        } catch let error as RecordValueCoding.Failure {
            return toolResult(.object(["error": .string(error.message)]), isError: true, text: error.message)
        } catch {
            let message = "\(name) failed: \(error.localizedDescription)"
            return toolResult(.object(["error": .string(message)]), isError: true, text: message)
        }
    }

    private func toolResult(_ value: JSONValue, isError: Bool, text: String? = nil) -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array([.object(["type": "text", "text": .string(text ?? JSONText.pretty(value))])]),
        ]
        if isError { result["isError"] = true }
        // Structured results arrived in protocol version 2025-06-18.
        if protocolVersion >= "2025-06-18" { result["structuredContent"] = value }
        return .object(result)
    }

    // MARK: - Lifecycle

    /// Snapshots bases with unsnapshotted edits. Call every few minutes.
    public func performMaintenance() {
        workspace.performMaintenance()
    }

    /// Writes final snapshots, flushes every log and releases the agent slot.
    public func shutdown() {
        workspace.close()
        workspace.agent.release()
    }

    static let instructions = """
        RowHouse is the user's Mac database app, an Airtable alternative. Data lives in bases; a base has tables; a table has typed fields and records.

        How to work:
        - Start with list_bases, then get_base_schema to learn table and field names and types before reading or writing records.
        - Bases, tables, fields, views and records can be given by id or by name (names are case-insensitive).
        - list_records pages with max_records/offset and can apply a view, filter_formula, search and sort. search_records looks for text across a whole base.
        - Record values are JSON keyed by field name: text as strings, numbers as numbers (percent as a fraction, 0.5 = 50%; durations in seconds), checkboxes as true/false, single select as the option name, multiple select as an array of names, dates as "YYYY-MM-DD" or ISO-8601 date-times, links as arrays of record ids or primary field values. describe_field_types gives the exact format of every type and the options create_field accepts.
        - Computed fields (formula, lookup, rollup, count, created/last modified time, autonumber, button) and attachments are read-only.
        - filter_formula uses Airtable formula syntax, e.g. AND({Status} = "Done", {Due} < TODAY()). Records where it is truthy are returned.
        - create_records and update_records take up to 100 records per call; update_records only changes the fields you pass. Unknown select options are an error unless typecast is true, which adds them.

        Changes are written straight to the base's files. They appear in the RowHouse app within a second and on the user's other Macs through iCloud Drive, attributed to this assistant. There is no undo from here, so confirm with the user before deleting records or making large changes. Edits made here don't trigger the base's record automations.
        """
}
