import Foundation
import Testing
@testable import RowHouseCore

@Suite("Review regressions") @MainActor
struct RegressionTests {
    @Test func undoingATableDeletionBringsTheTableBack() {
        let doc = TestSupport.document()
        let keep = doc.createTable(name: "Keep")
        let t = doc.createTable(name: "Gone")
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        undo.beginUndoGrouping()
        doc.deleteTable(t)
        undo.endUndoGrouping()
        #expect(doc.table(t) == nil)
        undo.undo()
        #expect(doc.table(t)?.name == "Gone")
        #expect(doc.fields(in: t).count == 4)
        #expect(doc.table(keep) != nil)
    }

    @Test func undoingACommentDeletionBringsItBack() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "C")
        let r = doc.records(in: t)[0].id
        doc.addComment(to: r, text: "Hello")
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        undo.beginUndoGrouping()
        doc.deleteComment(doc.comments(for: r)[0].id)
        undo.endUndoGrouping()
        undo.undo()
        #expect(doc.comments(for: r).map(\.text) == ["Hello"])
    }

    @Test func clearingInverseLinksOnSeveralRecordsKeepsEveryChange() {
        let doc = TestSupport.document()
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        let tasks = doc.createTable(name: "Tasks", starterFields: false, emptyRecords: 0)
        var o = FieldOptions()
        o.linkedTableID = tasks
        let owner = doc.createField(in: projects, name: "Tasks", type: .link, options: o)
        let inverse = doc.field(owner)!.options.inverseFieldID!
        let r1 = doc.createRecord(in: tasks)
        let r2 = doc.createRecord(in: tasks)
        let r3 = doc.createRecord(in: tasks)
        let p = doc.createRecord(in: projects, values: [owner: [.string(r1), .string(r2), .string(r3)]])
        doc.updateRecords([r1: [inverse: .null], r2: [inverse: .null]])
        #expect(doc.record(p)![owner].stringArray == [r3])

        // Linking several tasks to one project at once (e.g. a CSV import) keeps them all.
        let q = doc.createRecord(in: projects)
        doc.updateRecords([r1: [inverse: [.string(q)]], r2: [inverse: [.string(q)]]])
        #expect(Set(doc.record(q)![owner].stringArray) == [r1, r2])
    }

    @Test func singleRecordLinksStaySingleWhenEditedFromTheOtherSide() {
        let doc = TestSupport.document()
        let team = doc.createTable(name: "Team", starterFields: false, emptyRecords: 0)
        let projects = doc.createTable(name: "Projects", starterFields: false, emptyRecords: 0)
        var o = FieldOptions()
        o.linkedTableID = team
        o.singleRecordLink = true
        let ownerField = doc.createField(in: projects, name: "Owner", type: .link, options: o)
        let inverse = doc.field(ownerField)!.options.inverseFieldID!
        let a = doc.createRecord(in: team)
        let b = doc.createRecord(in: team)
        let p = doc.createRecord(in: projects, values: [ownerField: [.string(a)]])
        doc.updateRecord(b, values: [inverse: [.string(p)]])
        #expect(doc.record(p)![ownerField].stringArray == [b])
    }

    @Test func linkTextNeverCreatesRecordsAndCommasInNamesMatch() {
        let doc = TestSupport.document()
        let companies = doc.createTable(name: "Companies", starterFields: false, emptyRecords: 0)
        let deals = doc.createTable(name: "Deals", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: companies)!.id
        let acme = doc.createRecord(in: companies, values: [name: "Acme, Inc."])
        var o = FieldOptions()
        o.linkedTableID = companies
        let link = doc.field(doc.createField(in: deals, name: "Company", type: .link, options: o))!
        #expect(doc.parseValue("Acme, Inc.", for: link, createMissingChoices: true).stringArray == [acme])
        #expect(doc.parseValue("Nobody Ltd", for: link, createMissingChoices: true) == .null)
        #expect(doc.recordCount(in: companies) == 1)
    }

    @Test func conditionsWithoutValuesDontMatchEverythingInOrGroups() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let a = doc.createRecord(in: t, values: [name: "Alpha"])
        let b = doc.createRecord(in: t, values: [name: "Beta"])
        let filter = FilterGroup(conjunction: .or, conditions: [
            FilterCondition(fieldID: name, op: .is, value: "Alpha"),
            FilterCondition(fieldID: name, op: .contains),
        ])
        #expect(doc.matches(doc.record(a)!, filter: filter))
        #expect(!doc.matches(doc.record(b)!, filter: filter))
        // Strict mode (automations): an empty value means "is empty", not "anything".
        let strict = FilterGroup(conditions: [FilterCondition(fieldID: name, op: .is, value: "")])
        #expect(!doc.matches(doc.record(a)!, filter: strict, strict: true))
        #expect(doc.matches(doc.record(a)!, filter: strict))
    }

    @Test func groupsAreNeverDuplicated() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        for n in ["Apple", "apple", "Banana", "Apple"] { doc.createRecord(in: t, values: [name: .string(n)]) }
        let view = doc.views(in: t)[0]
        doc.updateViewConfig(view.id) { $0.groups = [SortSpec(fieldID: name)] }
        let rows = doc.evaluate(view: doc.view(view.id)!).rows
        let ids = rows.compactMap { row -> String? in if case .group(let g) = row { return g.id } else { return nil } }
        #expect(ids.count == Set(ids).count)
        #expect(rows.count == 4 + ids.count)
    }

    @Test func negativeDayCountsDontCrash() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let due = doc.createField(in: t, name: "Due", type: .date)
        let r = doc.createRecord(in: t, values: [due: .string(DateCoding.encode(Date(), includeTime: false))])
        for mode in ["pastNumberOfDays", "nextNumberOfDays"] {
            let f = FilterGroup(conditions: [FilterCondition(fieldID: due, op: .isWithin, value: ["mode": .string(mode), "days": -3])])
            #expect(doc.matches(doc.record(r)!, filter: f))
        }
    }

    @Test func scheduledAutomationsElectOneHost() {
        let doc = TestSupport.document(device: "devM")
        doc.deviceName = "M"
        doc.registerDevice()
        let other = ChangeOperation(ts: HLC(wall: 1, counter: 0, node: "devB"), kind: .device, id: "devB", set: ["name": "B", "lastSeen": 1])
        doc.mergeRemote([other])
        #expect(doc.effectiveAutomationHost == "devB")
        doc.setAutomationHost("devM")
        #expect(doc.effectiveAutomationHost == "devM")
    }

    @Test func numbersParseInEitherConvention() {
        let us = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        #expect(ValueParsing.number(from: "1,234.5", locale: us) == 1234.5)
        #expect(ValueParsing.number(from: "1.234,5", locale: us) == 1234.5)
        #expect(ValueParsing.number(from: "3,5", locale: de) == 3.5)
        #expect(ValueParsing.number(from: "1.234", locale: de) == 1234)
        #expect(ValueParsing.number(from: "1,234", locale: us) == 1234)
        #expect(ValueParsing.number(from: "1,5", locale: us) == 1.5)
        #expect(ValueParsing.number(from: "$12 500", locale: us) == 12500)
        #expect(ValueParsing.number(from: "(42)", locale: us) == -42)
        #expect(ValueParsing.number(from: "-0.25", locale: de) == -0.25)
        #expect(ValueParsing.number(from: "2026-09-26", locale: us) == nil)
        #expect(ValueParsing.editableNumber(1234.5) == "1234.5")
        #expect(ValueParsing.editableNumber(3) == "3")
        #expect(ValueParsing.editableNumber(0.1 + 0.2) == "0.3")
    }

    @Test func impossibleDatesAreRejected() {
        #expect(DateCoding.decode("25-12-2026") == nil)
        #expect(DateCoding.decode("2026-02-30") == nil)
        #expect(DateCoding.decode("2026-02-28") != nil)
    }

    @Test func buttonsOnlyOpenSafeURLs() {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        var o = FieldOptions()
        o.buttonURLFormula = "\"file:///Applications/Calculator.app\""
        let bad = doc.field(doc.createField(in: t, name: "Bad", type: .button, options: o))!
        o.buttonURLFormula = "\"https://example.com\""
        let good = doc.field(doc.createField(in: t, name: "Good", type: .button, options: o))!
        let r = doc.record(doc.createRecord(in: t))!
        #expect(doc.compute.buttonURL(record: r, field: bad) == nil)
        #expect(doc.compute.buttonURL(record: r, field: good)?.host == "example.com")
    }

    @Test func anUnreadableOwnSnapshotIsNeverOverwritten() async throws {
        let entry = try TestSupport.makePackage()
        let a = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "A"))
        a.document.createTable(name: "Important")
        a.writeSnapshotNow()
        a.close()
        let snapshot = entry.url.appendingPathComponent("devices/devA/snapshot.json")
        try Data("not json".utf8).write(to: snapshot)

        let storage = BaseStorage(packageURL: entry.url, deviceID: "devA")
        _ = storage.loadAll()
        storage.writeSnapshot(BaseState())
        storage.flush()
        #expect(try Data(contentsOf: snapshot) == Data("not json".utf8))
    }
}

@Suite("Automation regressions", .serialized) @MainActor
struct AutomationRegressionTests {
    @Test func undoDoesNotRefireRecordCreatedAutomations() async throws {
        let entry = try TestSupport.makePackage()
        let session = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "A"))
        let doc = session.document
        let t = doc.createTable(name: "T", starterFields: false, emptyRecords: 0)
        let services = FakeServices()
        let engine = AutomationEngine(session: session, services: services, defaults: UserDefaults(suiteName: "rh-\(UUID().uuidString)")!)
        doc.createAutomation(name: "N", trigger: AutomationTrigger(kind: .recordCreated, tableID: t), actions: [AutomationAction(kind: .sendNotification)], enabled: true)
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        undo.beginUndoGrouping()
        let r = doc.createRecord(in: t)
        undo.endUndoGrouping()
        // Wait for the real "created" run to finish before deleting and undoing.
        for _ in 0..<500 where services.notifications.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(services.notifications.count == 1)
        undo.beginUndoGrouping()
        doc.deleteRecords([r])
        undo.endUndoGrouping()
        undo.undo()
        #expect(doc.record(r) != nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(services.notifications.count == 1)
        _ = engine
        session.close()
    }
}

@Suite("Library errors") @MainActor
struct LibraryErrorTests {
    @Test func unreadableFoldersAreReported() throws {
        let root = TestSupport.tempDirectory()
        let defaults = UserDefaults(suiteName: "rowhouse-tests-\(UUID().uuidString)")!
        defaults.set(root.path, forKey: "RowHouseLibraryPath")
        let library = Library(defaults: defaults)
        #expect(library.lastError == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        library.refresh()
        #expect(library.lastError != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        library.refresh()
        #expect(library.lastError == nil)
    }
}
