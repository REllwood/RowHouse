import Foundation
import RowHouseCore
import Testing
@testable import RowHouseMCPKit

/// An in-process server over a temporary library, driven with JSON-RPC text like a real client.
@MainActor
final class MCPHarness {
    let root: URL
    let libraryURL: URL
    let server: MCPServer
    private var nextID = 1

    init(root: URL? = nil, hostDeviceID: String = "devHost") {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("rowhouse-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        libraryURL = root.appendingPathComponent("Library", isDirectory: true)
        server = MCPServer(configuration: MCPServer.Configuration(
            libraryRoot: libraryURL,
            lockDirectory: root.appendingPathComponent("agents", isDirectory: true),
            hostDeviceID: hostDeviceID,
            version: "9.9.9"
        ))
    }

    /// Sends one raw line and parses the reply.
    func send(_ line: String) async -> JSONValue? {
        guard let reply = await server.handle(line) else { return nil }
        return try? JSONValue.parse(reply)
    }

    func request(_ method: String, _ params: JSONValue? = nil) async -> JSONValue {
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        return await send(JSONText.compact(.object(message))) ?? .null
    }

    func initialize(client: String = "claude-code", version: String = "2025-06-18") async -> JSONValue {
        let reply = await request("initialize", [
            "protocolVersion": .string(version),
            "capabilities": [:],
            "clientInfo": ["name": .string(client), "version": "1.0"],
        ])
        _ = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return reply
    }

    /// Calls a tool and returns its whole `result`.
    func callResult(_ tool: String, _ arguments: JSONValue = [:]) async -> JSONValue {
        let reply = await request("tools/call", ["name": .string(tool), "arguments": arguments])
        return reply["result"] ?? reply
    }

    /// Calls a tool that is expected to succeed and returns its structured content.
    func call(_ tool: String, _ arguments: JSONValue = [:], sourceLocation: SourceLocation = #_sourceLocation) async -> JSONValue {
        let result = await callResult(tool, arguments)
        if result["isError"]?.boolValue == true {
            let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "?"
            Issue.record("\(tool) failed: \(text)", sourceLocation: sourceLocation)
        }
        return result["structuredContent"] ?? .null
    }

    /// Calls a tool that is expected to fail and returns its error text.
    func callError(_ tool: String, _ arguments: JSONValue = [:], sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        let result = await callResult(tool, arguments)
        if result["isError"]?.boolValue != true {
            Issue.record("\(tool) unexpectedly succeeded: \(JSONText.compact(result))", sourceLocation: sourceLocation)
        }
        return result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    func cleanUp() {
        server.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
