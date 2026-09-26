import Foundation
import Testing
@testable import RowHouseCore

@Suite("Trash, history and base maintenance") @MainActor
struct MaintenanceTests {
    @Test func deletedThingsAppearInTheTrashAndCanBeRestored() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Tasks")
        let name = doc.primaryField(of: t)!.id
        let r = doc.records(in: t)[0].id
        doc.updateRecord(r, values: [name: "Write the docs"])
        let notes = doc.field(named: "Notes", in: t)!.id
        doc.deleteRecords([r])
        doc.deleteField(notes)
        let items = doc.trashItems()
        #expect(Set(items.map(\.kind)) == [.record, .field])
        let recordItem = items.first { $0.kind == .record }!
        #expect(recordItem.title == "Write the docs")
        #expect(recordItem.location == "Tasks")
        doc.restore(recordItem)
        #expect(doc.record(r) != nil)
        doc.restore(items.first { $0.kind == .field }!)
        #expect(doc.field(notes) != nil)
        #expect(doc.trashItems().isEmpty)
    }

    @Test func restoringATableBringsBackItsFieldsViewsAndRecords() {
        let doc = TestSupport.document()
        _ = doc.createTable(name: "Keep")
        let t = doc.createTable(name: "Projects")
        let fieldCount = doc.fields(in: t).count
        doc.deleteTable(t)
        let items = doc.trashItems()
        #expect(items.map(\.kind) == [.table])
        doc.restore(items[0])
        #expect(doc.table(t)?.name == "Projects")
        #expect(doc.fields(in: t).count == fieldCount)
        #expect(doc.views(in: t).count == 1)
        #expect(doc.recordCount(in: t) == 3)
    }

    @Test func emptyingTheTrashErasesRecordContents() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T")
        let name = doc.primaryField(of: t)!.id
        let r = doc.records(in: t)[0].id
        doc.updateRecord(r, values: [name: "Secret"])
        doc.deleteRecords([r])
        doc.emptyTrash(doc.trashItems())
        #expect(doc.state.entity(.record, r)?[name] == .null)
        #expect(doc.record(r) == nil)
    }

    @Test func findAndReplace() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let notes = doc.createField(in: t, name: "Notes", type: .multilineText)
        let count = doc.createField(in: t, name: "Count", type: .number)
        let a = doc.createRecord(in: t, values: [name: "Acme Corp", notes: "Call acme about ACME renewal", count: 3])
        let b = doc.createRecord(in: t, values: [name: "Globex", notes: "acme"])
        let ids = [a, b]
        let fields = [name, notes, count]
        #expect(doc.countMatches(FindReplaceOptions(find: "acme", replacement: ""), recordIDs: ids, fieldIDs: fields) == 3)
        #expect(doc.countMatches(FindReplaceOptions(find: "acme", replacement: "", matchCase: true), recordIDs: ids, fieldIDs: fields) == 2)
        #expect(doc.countMatches(FindReplaceOptions(find: "acme", replacement: "", wholeCell: true), recordIDs: ids, fieldIDs: fields) == 1)
        let changed = doc.replaceAll(FindReplaceOptions(find: "acme", replacement: "Initech"), recordIDs: ids, fieldIDs: fields)
        #expect(changed == 3)
        #expect(doc.record(a)![name] == "Initech Corp")
        #expect(doc.record(a)![notes] == "Call Initech about Initech renewal")
        #expect(doc.record(b)![notes] == "Initech")
        #expect(doc.record(a)![count] == 3)
    }

    @Test func draftValuesAreCheckedAgainstFormConditions() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        var o = FieldOptions()
        o.choices = [SelectChoice(name: "Bug", color: .red), SelectChoice(name: "Idea", color: .blue)]
        let kind = doc.createField(in: t, name: "Kind", type: .singleSelect, options: o)
        let bug = doc.field(kind)!.choice(named: "Bug")!.id
        let filter = FilterGroup(conditions: [FilterCondition(fieldID: kind, op: .is, value: [.string(bug)])])
        #expect(doc.matches(draft: [kind: .string(bug)], tableID: t, filter: filter))
        #expect(!doc.matches(draft: [:], tableID: t, filter: filter))
        #expect(doc.matches(draft: [:], tableID: t, filter: FilterGroup()))
    }

    @Test func historyShowsWhoChangedWhat() async throws {
        let entry = try TestSupport.makePackage()
        let a = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "MacBook"))
        let doc = a.document
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        var o = FieldOptions()
        o.choices = [SelectChoice(name: "Todo", color: .gray), SelectChoice(name: "Done", color: .green)]
        let status = doc.createField(in: t, name: "Status", type: .singleSelect, options: o)
        let todo = doc.field(status)!.choice(named: "Todo")!.id
        let done = doc.field(status)!.choice(named: "Done")!.id
        let r = doc.createRecord(in: t, values: [name: "Ship", status: .string(todo)])
        doc.updateRecord(r, values: [status: .string(done)])
        doc.deleteRecords([r])
        a.storage.flush()
        let ops = a.storage.operations(forEntity: r)
        let history = doc.history(of: r, operations: ops)
        #expect(history.map(\.kind) == [.deleted, .updated, .created])
        let update = history[1]
        #expect(update.author == "MacBook")
        #expect(update.changes == [.init(fieldName: "Status", old: "Todo", new: "Done")])
        #expect(history[2].changes.contains(.init(fieldName: "Name", old: "", new: "Ship")))
        a.close()
    }

    @Test func basesCanBeDuplicatedBackedUpAndRestored() async throws {
        let root = TestSupport.tempDirectory()
        let defaults = UserDefaults(suiteName: "rowhouse-tests-\(UUID().uuidString)")!
        defaults.set(root.path, forKey: "RowHouseLibraryPath")
        let library = Library(defaults: defaults)
        let entry = try library.createPackage(named: "Original")
        let session = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "A"))
        let t = session.document.createTable(name: "Things")
        let file = try session.storage.importAttachment(data: Data("photo".utf8), filename: "a.txt")
        let attach = session.document.createField(in: t, name: "Files", type: .attachment)
        session.document.updateRecord(session.document.records(in: t)[0].id, values: [attach: JSONValue(encoding: [file])])
        session.close()

        let copy = try library.duplicate(entry, state: session.document.state, name: "Original copy", deviceID: "devA")
        #expect(copy.baseID != entry.baseID)
        let copied = try await BaseSession.open(entry: copy, identity: DeviceIdentity(id: "devA", name: "A"))
        #expect(copied.document.table(t)?.name == "Things")
        #expect(FileManager.default.fileExists(atPath: copied.storage.url(for: file).path))
        copied.close()

        let zip = root.appendingPathComponent("backup.zip")
        try Library.exportBackup(of: entry.url, to: zip)
        let restored = try library.importBackup(from: zip)
        #expect(restored.baseID != entry.baseID)
        #expect(library.entries.count == 3)
        let reopened = try await BaseSession.open(entry: restored, identity: DeviceIdentity(id: "devA", name: "A"))
        #expect(reopened.document.recordCount(in: t) == 3)
        reopened.close()
    }
}

@Suite("Locked views") @MainActor
struct LockedViewTests {
    @Test func lockedViewsRejectConfigurationChangesUntilUnlocked() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T")
        let v = doc.views(in: t)[0].id
        let name = doc.primaryField(of: t)!.id
        doc.updateViewConfig(v) { $0.locked = true }
        doc.updateViewConfig(v) { $0.sorts = [SortSpec(fieldID: name)] }
        #expect(doc.view(v)!.config.sorts == nil)
        doc.updateViewConfig(v) { $0.locked = false; $0.sorts = [SortSpec(fieldID: name)] }
        #expect(doc.view(v)!.config.sorts == nil)
        doc.updateViewConfig(v) { $0.locked = false }
        doc.updateViewConfig(v) { $0.sorts = [SortSpec(fieldID: name)] }
        #expect(doc.view(v)!.config.sorts?.count == 1)
    }
}
