import Foundation
import Testing
@testable import RowHouseCore

@Suite("Hybrid logical clock")
struct ClockTests {
    @Test func timestampsRoundTripThroughText() {
        let t = HLC(wall: 1_790_000_000_123, counter: 7, node: "devAbc")
        #expect(HLC(t.description) == t)
        #expect(HLC("garbage") == nil)
    }

    @Test func ticksAreStrictlyIncreasingEvenWhenTheWallClockStalls() {
        let clock = HybridClock(node: "a", physicalTime: { 1_000 })
        let a = clock.tick()
        let b = clock.tick()
        let c = clock.tick()
        #expect(a < b && b < c)
        #expect(c.wall == 1_000 && c.counter == 2)
    }

    @Test func observingARemoteTimestampMovesTheClockPastIt() {
        let clock = HybridClock(node: "a", physicalTime: { 1_000 })
        clock.observe(HLC(wall: 5_000, counter: 3, node: "b"))
        let next = clock.tick()
        #expect(next > HLC(wall: 5_000, counter: 3, node: "b"))
    }

    @Test func nodeBreaksTiesDeterministically() {
        let a = HLC(wall: 1, counter: 0, node: "a")
        let b = HLC(wall: 1, counter: 0, node: "b")
        #expect(a < b)
    }
}

@Suite("Mergeable base state")
struct BaseStateTests {
    private func op(_ wall: Int64, _ node: String, _ id: String, _ set: [String: JSONValue], counter: Int32 = 0) -> ChangeOperation {
        ChangeOperation(ts: HLC(wall: wall, counter: counter, node: node), kind: .record, id: id, set: set)
    }

    @Test func laterWriteWinsPerProperty() {
        var state = BaseState()
        state.apply(op(2, "b", "r1", ["name": "B"]))
        state.apply(op(1, "a", "r1", ["name": "A", "color": "red"]))
        #expect(state.entity(.record, "r1")?["name"] == "B")
        #expect(state.entity(.record, "r1")?["color"] == "red")
    }

    @Test func applyIsOrderIndependentAndIdempotent() {
        var ops: [ChangeOperation] = []
        var rng = SystemRandomNumberGenerator()
        for i in 0..<300 {
            let node = ["a", "b", "c"][Int.random(in: 0..<3, using: &rng)]
            let id = "r\(Int.random(in: 0..<10, using: &rng))"
            let key = ["x", "y", "z"][Int.random(in: 0..<3, using: &rng)]
            // A real clock never issues the same timestamp twice, so each op gets its own counter.
            ops.append(op(Int64(i / 3), node, id, [key: JSONValue.number(Double(i))], counter: Int32(i)))
        }
        var forward = BaseState()
        ops.forEach { forward.apply($0) }
        var shuffled = BaseState()
        ops.shuffled().forEach { shuffled.apply($0) }
        ops.shuffled().forEach { shuffled.apply($0) }
        #expect(forward.json == shuffled.json)
    }

    @Test func mergingSnapshotsConverges() {
        var a = BaseState()
        var b = BaseState()
        a.apply(op(1, "a", "r1", ["x": 1]))
        a.apply(op(3, "a", "r2", ["y": 2]))
        b.apply(op(2, "b", "r1", ["x": 10]))
        b.apply(op(2, "b", "r3", ["z": 3]))
        var ab = a
        ab.merge(b)
        var ba = b
        ba.merge(a)
        ba.merge(a)
        #expect(ab.json == ba.json)
        #expect(ab.entity(.record, "r1")?["x"] == 10)
    }

    @Test func snapshotJSONRoundTrips() {
        var state = BaseState()
        state.apply(op(5, "a", "r1", ["text": "hello\nworld", "n": 3.5, "flag": true, "list": ["a", "b"], "none": nil]))
        let restored = BaseState(json: state.json)
        #expect(restored.json == state.json)
        #expect(restored.latest == state.latest)
    }

    @Test func operationsRoundTripThroughJSONLines() throws {
        let original = op(42, "devX", "rec1", ["fld": JSONValue.object(["a": [1, 2]])])
        let line = original.json.serialized()
        #expect(!line.contains(UInt8(ascii: "\n")))
        let parsed = ChangeOperation(json: try JSONValue.parse(line))
        #expect(parsed == original)
    }
}

@Suite("Storage and multi-device sync")
struct StorageTests {
    @Test @MainActor func twoDevicesSeeEachOthersEdits() async throws {
        let entry = try TestSupport.makePackage()
        let a = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "Mac A"))
        let tableID = a.document.createTable(name: "Tasks")
        let primary = a.document.primaryField(of: tableID)!.id
        let recordID = a.document.createRecord(in: tableID, values: [primary: "Write tests"])
        a.storage.flush()

        let b = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devB", name: "Mac B"))
        #expect(b.document.table(tableID)?.name == "Tasks")
        #expect(b.document.displayString(b.document.record(recordID)!, b.document.field(primary)!) == "Write tests")

        // Concurrent edits to different fields both survive; the same field resolves to the later write.
        let notes = b.document.fields(in: tableID).first { $0.name == "Notes" }!.id
        b.document.updateRecord(recordID, values: [notes: "From B"])
        a.document.updateRecord(recordID, values: [primary: "Write more tests"])
        a.storage.flush()
        b.storage.flush()
        a.document.mergeRemote(a.storage.pollChanges().ops)
        let bChanges = b.storage.pollChanges()
        b.document.mergeRemote(bChanges.ops)

        for doc in [a.document, b.document] {
            let r = doc.record(recordID)!
            #expect(doc.displayString(r, doc.field(primary)!) == "Write more tests")
            #expect(doc.displayString(r, doc.field(notes)!) == "From B")
        }
        #expect(a.document.state.json == b.document.state.json)
        a.close()
        b.close()
    }

    @Test @MainActor func snapshotsReplaceLogReplayOnLoad() async throws {
        let entry = try TestSupport.makePackage()
        let a = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "Mac A"))
        let tableID = a.document.createTable(name: "Numbers", starterFields: false, emptyRecords: 0)
        let primary = a.document.primaryField(of: tableID)!.id
        a.document.createRecords(in: tableID, values: (0..<50).map { [primary: .string("Row \($0)")] })
        a.writeSnapshotNow()
        a.document.createRecord(in: tableID, values: [primary: "After snapshot"])
        a.close()

        let files = try FileManager.default.contentsOfDirectory(atPath: entry.url.appendingPathComponent("devices/devA").path)
        #expect(files.contains("snapshot.json"))
        #expect(files.filter { $0.hasPrefix("log-") }.count >= 2)

        let reopened = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "Mac A"))
        #expect(reopened.document.recordCount(in: tableID) == 51)
        #expect(reopened.document.findRecord(titled: "After snapshot", in: tableID) != nil)
        reopened.close()
    }

    @Test func partialTrailingLinesAreIgnoredUntilComplete() throws {
        let entry = try TestSupport.makePackage()
        let dir = entry.url.appendingPathComponent("devices/devB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("log-0000000000001-AAAAAA.jsonl")
        let op1 = ChangeOperation(ts: HLC(wall: 1, counter: 0, node: "devB"), kind: .table, id: "tbl1", set: ["name": "One"])
        let op2 = ChangeOperation(ts: HLC(wall: 2, counter: 0, node: "devB"), kind: .table, id: "tbl2", set: ["name": "Two"])
        var data = op1.json.serialized()
        data.append(UInt8(ascii: "\n"))
        let second = op2.json.serialized()
        data.append(second.prefix(10))
        try data.write(to: log)

        let storage = BaseStorage(packageURL: entry.url, deviceID: "devA")
        let loaded = storage.loadAll()
        #expect(loaded.state.entity(.table, "tbl1") != nil)
        #expect(loaded.state.entity(.table, "tbl2") == nil)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        var rest = Data(second.dropFirst(10))
        rest.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: rest)
        try handle.close()
        let changes = storage.pollChanges()
        #expect(changes.ops.map(\.id) == ["tbl2"])
    }

    @Test func attachmentsAreContentAddressed() throws {
        let entry = try TestSupport.makePackage()
        let storage = BaseStorage(packageURL: entry.url, deviceID: "devA")
        let a = try storage.importAttachment(data: Data("hello".utf8), filename: "a.txt")
        let b = try storage.importAttachment(data: Data("hello".utf8), filename: "copy.txt")
        #expect(a.hash == b.hash)
        #expect(a.id != b.id)
        #expect(FileManager.default.fileExists(atPath: storage.url(for: a).path))
        #expect(a.mimeType == "text/plain")
    }

    @Test func libraryListsPackagesAndSanitisesNames() async throws {
        let root = TestSupport.tempDirectory()
        let defaults = UserDefaults(suiteName: "rowhouse-tests-\(UUID().uuidString)")!
        defaults.set(root.path, forKey: "RowHouseLibraryPath")
        await MainActor.run {
            let library = Library(defaults: defaults)
            #expect(library.entries.isEmpty)
            let entry = try! library.createPackage(named: "Q3/Q4: Plans")
            let second = try! library.createPackage(named: "Q3/Q4: Plans")
            #expect(entry.url.lastPathComponent == "Q3-Q4- Plans.rowhouse")
            #expect(second.url.lastPathComponent == "Q3-Q4- Plans 2.rowhouse")
            #expect(library.entries.count == 2)
        }
    }
}
