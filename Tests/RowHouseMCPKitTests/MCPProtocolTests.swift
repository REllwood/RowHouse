import Foundation
import RowHouseCore
import Testing
@testable import RowHouseMCPKit

@Suite("MCP protocol") @MainActor
struct MCPProtocolTests {
    @Test func initializeNegotiatesTheProtocolVersion() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        for version in MCPServer.supportedProtocolVersions {
            let reply = await h.initialize(version: version)
            #expect(reply["result"]?["protocolVersion"]?.stringValue == version)
        }
        let unknown = await h.initialize(version: "1999-01-01")
        #expect(unknown["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        let result = unknown["result"]
        #expect(result?["serverInfo"]?["name"] == "rowhouse")
        #expect(result?["serverInfo"]?["version"] == "9.9.9")
        #expect(result?["capabilities"] == ["tools": ["listChanged": false]])
        #expect(result?["instructions"]?.stringValue?.contains("list_bases") == true)
        #expect(unknown["id"] != nil)
        #expect(unknown["jsonrpc"] == "2.0")
    }

    @Test func pingAndNotifications() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        #expect(await h.request("ping")["result"] == [:])
        #expect(await h.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await h.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#) == nil)
        #expect(await h.server.handle("   ") == nil)
    }

    @Test func protocolErrorsUseJSONRPCCodes() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        let unknownMethod = await h.request("resources/list")
        #expect(unknownMethod["error"]?["code"] == -32601)
        #expect(unknownMethod["id"] == 1)

        let malformed = await h.send("{not json")
        #expect(malformed?["error"]?["code"] == -32700)
        #expect(malformed?["id"] == .null)

        let noVersion = await h.send(#"{"id":7,"method":"ping"}"#)
        #expect(noVersion?["error"]?["code"] == -32600)
        #expect(noVersion?["id"] == 7)

        let nullID = await h.send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        #expect(nullID?["error"]?["code"] == -32600)

        let notAnObject = await h.send("42")
        #expect(notAnObject?["error"]?["code"] == -32600)

        let badParams = await h.send(#"{"jsonrpc":"2.0","id":"x","method":"tools/list","params":"nope"}"#)
        #expect(badParams?["error"]?["code"] == -32602)
        #expect(badParams?["id"] == "x")

        let unknownTool = await h.request("tools/call", ["name": "drop_everything", "arguments": [:]])
        #expect(unknownTool["error"]?["code"] == -32602)

        let emptyBatch = await h.send("[]")
        #expect(emptyBatch?["error"]?["code"] == -32600)
    }

    @Test func batchesGetOneReplyPerRequest() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        let reply = await h.send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"nope"}]"#)
        let items = reply?.arrayValue ?? []
        #expect(items.count == 2)
        #expect(items.first?["result"] == [:])
        #expect(items.last?["error"]?["code"] == -32601)
    }

    @Test func toolsListDescribesEveryTool() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        let tools = await h.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == [
            "list_bases", "get_base_schema", "list_records", "get_record", "search_records",
            "create_records", "update_records", "delete_records", "create_table", "update_table",
            "create_field", "update_field", "list_comments", "add_comment", "create_base", "describe_field_types",
        ])
        #expect(names.count == Set(names).count)
        for tool in tools {
            let name = tool["name"]?.stringValue ?? "?"
            #expect((tool["description"]?.stringValue?.count ?? 0) > 20, "\(name)")
            let schema = tool["inputSchema"]
            #expect(schema?["type"] == "object", "\(name)")
            #expect(schema?["additionalProperties"] == false, "\(name)")
            let properties = Set(schema?["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let required = Set(schema?["required"]?.stringArray ?? [])
            #expect(required.isSubset(of: properties), "\(name)")
            for (key, property) in schema?["properties"]?.objectValue ?? [:] {
                #expect(property["type"]?.stringValue != nil, "\(name).\(key)")
            }
            #expect(tool["annotations"]?["readOnlyHint"]?.boolValue != nil, "\(name)")
        }
        let readOnly = tools.filter { $0["annotations"]?["readOnlyHint"] == true }.compactMap { $0["name"]?.stringValue }
        #expect(Set(readOnly) == ["list_bases", "get_base_schema", "list_records", "get_record", "search_records", "list_comments", "describe_field_types"])
        let destructive = tools.filter { $0["annotations"]?["destructiveHint"] == true }.compactMap { $0["name"]?.stringValue }
        #expect(Set(destructive) == ["update_records", "delete_records", "update_table", "update_field"])
    }

    @Test func toolResultsCarryTextAndStructuredContent() async throws {
        let h = MCPHarness()
        defer { h.cleanUp() }
        _ = await h.initialize(version: "2025-06-18")
        let result = await h.callResult("list_bases")
        let text = result["content"]?.arrayValue?.first
        #expect(text?["type"] == "text")
        #expect(try JSONValue.parse(text?["text"]?.stringValue ?? "") == result["structuredContent"])
        #expect(result["structuredContent"] == ["bases": []])
        #expect(result["isError"] == nil)

        _ = await h.initialize(version: "2024-11-05")
        let old = await h.callResult("list_bases")
        #expect(old["structuredContent"] == nil)
        #expect(old["content"] != nil)
    }

    @Test func toolFailuresAreResultsNotProtocolErrors() async {
        let h = MCPHarness()
        defer { h.cleanUp() }
        let missing = await h.callError("get_base_schema", [:])
        #expect(missing == "Missing required argument base")
        let unknownBase = await h.callError("get_base_schema", ["base": "Nope"])
        #expect(unknownBase.contains("No base named Nope"))
        let unknownArgument = await h.callError("list_bases", ["verbose": true])
        #expect(unknownArgument.contains("Unknown argument verbose"))
        let reply = await h.request("tools/call", ["name": "get_base_schema", "arguments": ["base": "Nope"]])
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == true)
    }

    @Test func numbersAreWrittenCompactly() {
        #expect(JSONText.compact(["a": 3.3, "b": 1, "c": -0.5, "d": 1e21, "e": .number(.nan)]) == #"{"a":3.3,"b":1,"c":-0.5,"d":1e+21,"e":null}"#)
        #expect(JSONText.compact("line\nbreak \"quoted\" \u{1}") == #""line\nbreak \"quoted\" \u0001""#)
        #expect(JSONText.pretty(["k": [1, 2]]) == "{\n  \"k\": [\n    1,\n    2\n  ]\n}")
    }

    @Test func clientNamesBecomeFriendlyDeviceNames() {
        #expect(MCPServer.friendlyClientName(name: "claude-code", title: nil) == "Claude Code")
        #expect(MCPServer.friendlyClientName(name: "codex-mcp-client", title: nil) == "Codex")
        #expect(MCPServer.friendlyClientName(name: "some-client", title: "Some Client") == "Some Client")
        #expect(MCPServer.friendlyClientName(name: "some-client", title: nil) == "some-client")
        #expect(MCPServer.friendlyClientName(name: nil, title: nil) == "AI assistant")
    }
}
