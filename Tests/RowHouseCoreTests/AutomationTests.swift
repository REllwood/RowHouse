import Foundation
import Testing
@testable import RowHouseCore

@Suite("Automations", .serialized) @MainActor
struct AutomationTests {
    struct Harness {
        let session: BaseSession
        let engine: AutomationEngine
        let services: FakeServices
        let table: String
        let name: String
        let status: String
        let done: String
        @MainActor var doc: BaseDocument { session.document }
    }

    func harness() async throws -> Harness {
        let entry = try TestSupport.makePackage()
        let session = try await BaseSession.open(entry: entry, identity: DeviceIdentity(id: "devA", name: "Mac A"))
        let doc = session.document
        let t = doc.createTable(name: "Tasks", starterFields: true, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let status = doc.field(named: "Status", in: t)!.id
        let done = doc.createField(in: t, name: "Done", type: .checkbox)
        let services = FakeServices()
        let defaults = UserDefaults(suiteName: "rowhouse-tests-\(UUID().uuidString)")!
        let engine = AutomationEngine(session: session, services: services, defaults: defaults)
        return Harness(session: session, engine: engine, services: services, table: t, name: name, status: status, done: done)
    }

    /// Lets detached automation runs finish.
    func settle(_ engine: AutomationEngine) async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            if engine.activeRuns == 0 { try? await Task.sleep(for: .milliseconds(20)); if engine.activeRuns == 0 { return } }
        }
    }

    @Test func recordCreatedSendsANotificationWithTemplates() async throws {
        let h = try await harness()
        var action = AutomationAction(kind: .sendNotification)
        action.title = "New: {{trigger.record.Name}}"
        action.body = "in {{trigger.table.name}}"
        h.doc.createAutomation(name: "Notify", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [action], enabled: true)
        h.doc.createRecord(in: h.table, values: [h.name: "Buy milk"])
        await settle(h.engine)
        #expect(h.services.notifications.count == 1)
        #expect(h.services.notifications.first?.0 == "New: Buy milk")
        #expect(h.services.notifications.first?.1 == "in Tasks")
        #expect(h.session.runs.first?.status == .succeeded)
        h.session.close()
    }

    @Test func disabledAutomationsAndRemoteChangesDoNotRun() async throws {
        let h = try await harness()
        h.doc.createAutomation(name: "Off", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [AutomationAction(kind: .sendNotification)], enabled: false)
        h.doc.createRecord(in: h.table)
        let on = h.doc.createAutomation(name: "On", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [AutomationAction(kind: .sendNotification)], enabled: true)
        _ = on
        // A record arriving from another Mac must not fire here.
        let remote = ChangeOperation(ts: HLC(wall: Int64(Date().timeIntervalSince1970 * 1000) + 10_000, counter: 0, node: "devB"), kind: .record, id: RowID.record(), set: ["_table": .string(h.table), "_order": 99, "_created": 1, "_deleted": false])
        h.doc.mergeRemote([remote])
        await settle(h.engine)
        #expect(h.services.notifications.isEmpty)
        h.session.close()
    }

    @Test func recordUpdatedOnlyFiresForWatchedFields() async throws {
        let h = try await harness()
        var trigger = AutomationTrigger(kind: .recordUpdated, tableID: h.table)
        trigger.watchedFieldIDs = [h.done]
        h.doc.createAutomation(name: "Watch done", trigger: trigger, actions: [AutomationAction(kind: .sendNotification)], enabled: true)
        let r = h.doc.createRecord(in: h.table)
        h.doc.updateRecord(r, values: [h.name: "Renamed"])
        await settle(h.engine)
        #expect(h.services.notifications.isEmpty)
        h.doc.updateRecord(r, values: [h.done: true])
        await settle(h.engine)
        #expect(h.services.notifications.count == 1)
        h.session.close()
    }

    @Test func matchesConditionsFiresOncePerTransition() async throws {
        let h = try await harness()
        let doneChoice = h.doc.field(h.status)!.choice(named: "Done")!.id
        let todoChoice = h.doc.field(h.status)!.choice(named: "Todo")!.id
        var trigger = AutomationTrigger(kind: .recordMatchesConditions, tableID: h.table)
        trigger.filter = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .is, value: [.string(doneChoice)])])
        let already = h.doc.createRecord(in: h.table, values: [h.status: .string(doneChoice)])
        h.doc.createAutomation(name: "Done", trigger: trigger, actions: [AutomationAction(kind: .sendNotification)], enabled: true)
        // Records that already matched when the automation was created don't fire.
        h.doc.updateRecord(already, values: [h.name: "Still done"])
        let r = h.doc.createRecord(in: h.table, values: [h.status: .string(todoChoice)])
        h.doc.updateRecord(r, values: [h.status: .string(doneChoice)])
        h.doc.updateRecord(r, values: [h.name: "edit while done"])
        await settle(h.engine)
        #expect(h.services.notifications.count == 1)
        h.doc.updateRecord(r, values: [h.status: .string(todoChoice)])
        h.doc.updateRecord(r, values: [h.status: .string(doneChoice)])
        await settle(h.engine)
        #expect(h.services.notifications.count == 2)
        h.session.close()
    }

    @Test func recordActionsAndStepOutputs() async throws {
        let h = try await harness()
        let log = h.doc.createTable(name: "Log", starterFields: false, emptyRecords: 0)
        let logName = h.doc.primaryField(of: log)!.id
        var create = AutomationAction(kind: .createRecord)
        create.tableID = log
        create.fieldValues = [logName: "Created {{trigger.record.Name}}"]
        var update = AutomationAction(kind: .updateRecord)
        update.tableID = h.table
        update.recordIDTemplate = "{{trigger.record.id}}"
        update.fieldValues = [h.status: "Done", h.done: "true"]
        var find = AutomationAction(kind: .findRecords)
        find.tableID = log
        var http = AutomationAction(kind: .httpRequest)
        http.url = "https://example.com/hook?n={{trigger.record.Name | url}}"
        http.method = "POST"
        http.body = "{\"found\": {{steps.3.count}}, \"log\": {{steps.1.Name | json}}}"
        var notify = AutomationAction(kind: .sendNotification)
        notify.title = "{{steps.4.status}} {{steps.4.json.ok}}"
        h.doc.createAutomation(name: "Chain", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [create, update, find, http, notify], enabled: true)

        let r = h.doc.createRecord(in: h.table, values: [h.name: "A & B"])
        await settle(h.engine)
        #expect(h.doc.recordCount(in: log) == 1)
        #expect(h.doc.primaryTitle(h.doc.records(in: log)[0]) == "Created A & B")
        #expect(h.doc.displayString(h.doc.record(r)!, h.doc.field(h.status)!) == "Done")
        #expect(h.doc.value(h.doc.record(r)!, h.doc.field(h.done)!) == .bool(true))
        let request = try #require(h.services.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/hook?n=A%20%26%20B")
        #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == "{\"found\": 1, \"log\": \"Created A & B\"}")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(h.services.notifications.first?.0 == "200 true")
        h.session.close()
    }

    @Test func stepConditionsSkipAndFailuresStopTheRun() async throws {
        let h = try await harness()
        var conditional = AutomationAction(kind: .sendNotification)
        conditional.title = "only when done"
        conditional.condition = FilterGroup(conditions: [FilterCondition(fieldID: h.done, op: .is, value: true)])
        var failing = AutomationAction(kind: .httpRequest)
        failing.url = "not a url"
        let after = AutomationAction(kind: .sendNotification)
        h.doc.createAutomation(name: "Cond", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [conditional, failing, after], enabled: true)
        h.doc.createRecord(in: h.table)
        await settle(h.engine)
        let run = try #require(h.session.runs.first { $0.automationName == "Cond" })
        #expect(run.status == .failed)
        #expect(run.steps.map(\.status) == [.skipped, .failed])
        #expect(h.services.notifications.isEmpty)
        h.session.close()
    }

    @Test func automationChainsStopAtTheDepthLimit() async throws {
        let h = try await harness()
        // Each run creates another record in the same table, which would trigger forever.
        var create = AutomationAction(kind: .createRecord)
        create.tableID = h.table
        create.fieldValues = [h.name: "child"]
        h.doc.createAutomation(name: "Loop", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [create], enabled: true)
        h.doc.createRecord(in: h.table, values: [h.name: "root"])
        await settle(h.engine)
        try? await Task.sleep(for: .milliseconds(200))
        await settle(h.engine)
        #expect(h.doc.recordCount(in: h.table) == 1 + AutomationEngine.maxChainDepth)
        h.session.close()
    }

    @Test func runNowUsesTheFirstRecordAndShortcutsReceiveInput() async throws {
        let h = try await harness()
        h.doc.createRecord(in: h.table, values: [h.name: "First"])
        var shortcut = AutomationAction(kind: .runShortcut)
        shortcut.shortcutName = "Log It"
        shortcut.body = "{{trigger.record.Name}}"
        let id = h.doc.createAutomation(name: "Manual", trigger: AutomationTrigger(kind: .manual, tableID: h.table), actions: [shortcut], enabled: false)
        var trigger = h.doc.automation(id)!.trigger
        trigger.kind = .buttonClicked
        h.doc.updateAutomation(id) { $0.trigger = trigger }
        let run = await h.engine.runNow(id)
        #expect(run?.status == .succeeded)
        #expect(h.services.shortcuts.first?.0 == "Log It")
        #expect(h.services.shortcuts.first?.1 == "First")
        h.session.close()
    }
}

@Suite("Scripts", .serialized) @MainActor
struct ScriptTests {
    func document() -> (BaseDocument, String, String, String) {
        let doc = TestSupport.document()
        let t = doc.createTable(name: "Inventory", starterFields: false, emptyRecords: 0)
        let name = doc.primaryField(of: t)!.id
        let qty = doc.createField(in: t, name: "Qty", type: .number)
        var s = FieldOptions()
        s.choices = [SelectChoice(name: "Low", color: .red), SelectChoice(name: "OK", color: .green)]
        let status = doc.createField(in: t, name: "Level", type: .singleSelect, options: s)
        doc.createRecord(in: t, values: [name: "Pens", qty: 3])
        doc.createRecord(in: t, values: [name: "Paper", qty: 40])
        return (doc, t, qty, status)
    }

    @Test func scriptsReadAndWriteRecords() async {
        let (doc, t, _, status) = document()
        let source = """
        const table = base.getTable("Inventory");
        const query = await table.selectRecordsAsync();
        let total = 0;
        for (const r of query.records) {
          const qty = r.getCellValue("Qty");
          total += qty;
          await table.updateRecordAsync(r, { "Level": qty < 10 ? "Low" : "OK" });
        }
        const id = await table.createRecordAsync({ "Name": "Stapler", "Qty": 7, "Level": { name: "Low" } });
        console.log("total", total, input.config().who);
        output.set("total", total);
        output.set("newId", id);
        """
        let result = await ScriptRunner.run(source: source, inputs: ["who": "tester"], document: doc, origin: .automation(depth: 1))
        #expect(result.error == nil)
        #expect(result.output["total"] == .number(43))
        #expect(result.logs == ["total 43 tester"])
        let levels = doc.records(in: t).map { doc.displayString($0, doc.field(status)!) }
        #expect(levels == ["Low", "OK", "Low"])
        #expect(doc.record(result.output["newId"]?.stringValue ?? "") != nil)
    }

    @Test func scriptErrorsAreReported() async {
        let (doc, _, _, _) = document()
        let missing = await ScriptRunner.run(source: "base.getTable('Nope');", inputs: [:], document: doc, origin: .local)
        #expect(missing.error?.contains("No table named Nope") == true)
        let thrown = await ScriptRunner.run(source: "throw new Error('boom');", inputs: [:], document: doc, origin: .local)
        #expect(thrown.error?.contains("boom") == true)
        let syntax = await ScriptRunner.run(source: "let x = ;", inputs: [:], document: doc, origin: .local)
        #expect(syntax.error != nil)
        let computed = await ScriptRunner.run(source: "base.getTable('Inventory').createRecord({ 'Missing': 1 });", inputs: [:], document: doc, origin: .local)
        #expect(computed.error?.contains("No field named Missing") == true)
    }

    @Test(.enabled(if: ScriptRunner.supportsTimeLimit)) func runawayScriptsAreStopped() async {
        let (doc, _, _, _) = document()
        let start = Date()
        let result = await ScriptRunner.run(source: "while (true) {}", inputs: [:], document: doc, origin: .local, timeLimit: 1)
        #expect(result.error != nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
