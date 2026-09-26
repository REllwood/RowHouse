import Foundation
@testable import RowHouseCore
import Testing
@testable import RowHouseMCPKit

@Suite("MCP device and sync", .serialized) @MainActor
struct MCPSyncTests {
    func entry(in library: URL) throws -> LibraryEntry {
        let package = try #require(try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil).first { $0.pathExtension == "rowhouse" })
        let manifest = try #require(BaseStorage.readManifest(at: package))
        return LibraryEntry(baseID: manifest.baseID, url: package, initialName: manifest.name, createdAt: manifest.createdAt)
    }

    @Test func editsReachAnotherDeviceAndItsEditsComeBack() async throws {
        let h = MCPHarness()
        defer { h.cleanUp() }
        _ = await h.initialize(client: "claude-code")
        _ = await h.call("create_base", ["name": "Shared"])
        let created = await h.call("create_records", ["base": "Shared", "table": "Table 1", "records": [
            ["fields": ["Name": "From the assistant", "Status": "Done", "Notes": "Written over MCP"]],
        ]])
        let recordID = try #require(created["records"]?.arrayValue?.first?["id"]?.stringValue)

        // The server writes only to its own device folder.
        let package = try entry(in: h.libraryURL)
        let devices = try FileManager.default.contentsOfDirectory(atPath: package.url.appendingPathComponent("devices").path)
        #expect(devices == ["devHost-agent0"])
        #expect(h.server.deviceID == "devHost-agent0")

        // The app on another Mac reads it like any other device's edits.
        let mac = try await BaseSession.open(entry: package, identity: DeviceIdentity(id: "devMac", name: "Mac"))
        defer { mac.close() }
        let doc = mac.document
        let table = try #require(doc.table(named: "Table 1"))
        let record = try #require(doc.record(recordID))
        #expect(doc.primaryTitle(record) == "From the assistant")
        #expect(doc.displayString(record, doc.field(named: "Status", in: table.id)!) == "Done")
        #expect(doc.agents.map(\.name) == ["Claude Code (MCP)"])
        #expect(doc.devices.map(\.id) == ["devMac"])
        #expect(doc.deviceName(for: record.cellStamps.values.max()!.node) == "Claude Code (MCP)")

        // Edits made on the Mac are pulled in before the next tool call.
        doc.updateRecord(recordID, values: [doc.field(named: "Notes", in: table.id)!.id: "Edited on the Mac"])
        doc.createRecord(in: table.id, values: [doc.primaryField(of: table.id)!.id: "From the Mac"])
        mac.storage.flush()
        let fetched = await h.call("get_record", ["base": "Shared", "record_id": .string(recordID)])
        #expect(fetched["fields"]?["Notes"] == "Edited on the Mac")
        let listed = await h.call("list_records", ["base": "Shared", "table": "Table 1", "search": "From the Mac"])
        #expect(listed["total"] == 1)

        // And the server's next edit reaches the Mac when it polls. The session's own file watcher may
        // get there first, so wait for whichever does.
        _ = await h.call("update_records", ["base": "Shared", "table": "Table 1", "records": [["id": .string(recordID), "fields": ["Status": "Todo"]]]])
        let status = doc.field(named: "Status", in: table.id)!
        let deadline = Date().addingTimeInterval(5)
        while doc.displayString(doc.record(recordID)!, status) != "Todo" && Date() < deadline {
            doc.mergeRemote(mac.storage.pollChanges().ops)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(doc.displayString(doc.record(recordID)!, status) == "Todo")
    }

    @Test func shutdownLeavesASnapshotThatReloads() async throws {
        let h = MCPHarness()
        _ = await h.initialize()
        _ = await h.call("create_base", ["name": "Durable"])
        _ = await h.call("create_records", ["base": "Durable", "table": "Table 1", "records": [["fields": ["Name": "Kept"]]]])
        h.server.shutdown()

        let package = try entry(in: h.libraryURL)
        let snapshot = package.url.appendingPathComponent("devices/devHost-agent0/snapshot.json")
        #expect(FileManager.default.fileExists(atPath: snapshot.path))

        let again = MCPHarness(root: h.root)
        defer { again.cleanUp() }
        #expect(again.server.deviceID == "devHost-agent0")
        let listed = await again.call("list_records", ["base": "Durable", "table": "Table 1", "search": "Kept"])
        #expect(listed["total"] == 1)
    }

    @Test func concurrentServersGetTheirOwnSlots() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rowhouse-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        let first = MCPHarness(root: root)
        let second = MCPHarness(root: root)
        #expect(first.server.deviceID == "devHost-agent0")
        #expect(second.server.deviceID == "devHost-agent1")
        first.server.shutdown()
        let third = MCPHarness(root: root)
        #expect(third.server.deviceID == "devHost-agent0")
        third.server.shutdown()
        second.cleanUp()
    }

    @Test func anUnreadableLibraryExplainsHowToGrantAccess() async throws {
        let h = MCPHarness()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.libraryURL.path)
            h.cleanUp()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.libraryURL.path)
        let message = await h.callError("list_bases")
        #expect(message.contains("Can't read the RowHouse library at \(h.libraryURL.path)"))
        #expect(message.contains("Privacy & Security › Files & Folders"))
        let create = await h.callError("create_base", ["name": "Nope"])
        #expect(create.contains("Privacy & Security"))
    }

    @Test func basesResolveByIDOrNameAndAmbiguityIsReported() async throws {
        let h = MCPHarness()
        defer { h.cleanUp() }
        let one = await h.call("create_base", ["name": "Twin"])
        _ = await h.call("create_base", ["name": "twin"])
        let id = try #require(one["id"]?.stringValue)
        #expect(await h.call("get_base_schema", ["base": .string(id)])["id"]?.stringValue == id)
        let exact = await h.call("get_base_schema", ["base": "Twin"])
        #expect(exact["id"]?.stringValue == id)
        let ambiguous = await h.callError("get_base_schema", ["base": "TWIN"])
        #expect(ambiguous.contains("Several bases are named TWIN"))
    }
}
