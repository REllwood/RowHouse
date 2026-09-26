import Foundation
import Testing
@testable import RowHouseCore

struct ParityTestError: Error, CustomStringConvertible {
    var description: String
}

/// Parses a raw request that is expected to be complete.
func completeRequest(_ raw: String) throws -> WebhookRequest {
    let parsed = try WebhookRequest.parse(Data(raw.utf8))
    guard case .complete(let request) = parsed else { throw ParityTestError(description: "Request was incomplete: \(parsed)") }
    return request
}

@Suite("Automation triggers and steps", .serialized) @MainActor
struct AutomationParityTests {
    typealias Harness = AutomationTests.Harness

    func harness() async throws -> Harness { try await AutomationTests().harness() }
    func settle(_ engine: AutomationEngine) async { await AutomationTests().settle(engine) }

    private static var remoteClock: Int64 = 0

    /// A cell edit that arrives from another Mac.
    func remoteEdit(_ recordID: String, _ set: [String: JSONValue]) -> ChangeOperation {
        Self.remoteClock += 1
        let wall = Int64(Date().timeIntervalSince1970 * 1000) + 60_000 + Self.remoteClock
        return ChangeOperation(ts: HLC(wall: wall, counter: 0, node: "devB"), kind: .record, id: recordID, set: set)
    }

    func choice(_ h: Harness, _ name: String) -> JSONValue {
        .string(h.doc.field(h.status)!.choice(named: name)!.id)
    }

    func titles(_ h: Harness, _ table: String) -> [String] {
        h.doc.records(in: table).map { h.doc.primaryTitle($0) }
    }

    /// A "Finished" view showing records whose status is Done, and an enabled automation that fires
    /// when records enter it.
    func entersViewSetup(_ h: Harness) -> (view: String, automation: String) {
        let view = h.doc.createView(in: h.table, name: "Finished", type: .grid)
        h.doc.updateViewConfig(view) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .is, value: [choice(h, "Done")])]) }
        var trigger = AutomationTrigger(kind: .recordEntersView, tableID: h.table)
        trigger.viewID = view
        let id = h.doc.createAutomation(name: "Entered", trigger: trigger, actions: [AutomationAction(kind: .sendNotification)], enabled: true)
        return (view, id)
    }

    func firedRecords(_ h: Harness) -> [String] {
        h.session.runs.filter { $0.automationName == "Entered" }.compactMap(\.recordID)
    }

    // MARK: - When a record enters a view

    @Test func recordEntersViewFiresOnlyWhenARecordStartsAppearing() async throws {
        let h = try await harness()
        let already = h.doc.createRecord(in: h.table, values: [h.name: "Old", h.status: choice(h, "Done")])
        _ = entersViewSetup(h)
        // Records already in the view when the automation was created don't count as entering.
        h.doc.updateRecord(already, values: [h.name: "Old, edited"])
        let r = h.doc.createRecord(in: h.table, values: [h.name: "New", h.status: choice(h, "Todo")])
        h.doc.updateRecord(r, values: [h.status: choice(h, "Done")])
        h.doc.updateRecord(r, values: [h.name: "New, edited"])
        await settle(h.engine)
        #expect(firedRecords(h) == [r])
        #expect(h.session.runs.first?.trigger == "Record entered view “Finished”")

        // Leaving and coming back is a new entry, and so is a record created inside the view.
        h.doc.updateRecord(r, values: [h.status: choice(h, "Todo")])
        h.doc.updateRecord(r, values: [h.status: choice(h, "Done")])
        let born = h.doc.createRecord(in: h.table, values: [h.name: "Born done", h.status: choice(h, "Done")])
        await settle(h.engine)
        #expect(Set(firedRecords(h)) == [r, born])
        #expect(firedRecords(h).count == 3)
        h.session.close()
    }

    @Test func recordEntersViewIgnoresRemoteChangesAndViewEdits() async throws {
        let h = try await harness()
        let (view, _) = entersViewSetup(h)
        let r = h.doc.createRecord(in: h.table, values: [h.name: "Moved elsewhere", h.status: choice(h, "Todo")])
        // Another Mac moves the record into the view: that Mac runs its automations, this one doesn't.
        h.doc.mergeRemote([remoteEdit(r, [h.status: choice(h, "Done")])])
        #expect(h.doc.displayString(h.doc.record(r)!, h.doc.field(h.status)!) == "Done")
        // It's now known to be in the view, so a local edit afterwards isn't an entry either.
        h.doc.updateRecord(r, values: [h.name: "Edited here"])
        await settle(h.engine)
        #expect(firedRecords(h).isEmpty)

        // Widening the view's filter brings records in without running anything.
        let todo = h.doc.createRecord(in: h.table, values: [h.name: "Todo", h.status: choice(h, "Todo")])
        h.doc.updateViewConfig(view) { $0.filter = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .isNotEmpty)]) }
        h.doc.updateRecord(todo, values: [h.name: "Still todo"])
        await settle(h.engine)
        #expect(firedRecords(h).isEmpty)

        // A local edit that brings a record into the widened view does run.
        let blank = h.doc.createRecord(in: h.table, values: [h.name: "No status"])
        h.doc.updateRecord(blank, values: [h.status: choice(h, "In progress")])
        await settle(h.engine)
        #expect(firedRecords(h) == [blank])

        // Test runs pick a record that is in the view.
        let entered = try #require(h.doc.automations.first { $0.name == "Entered" })
        let test = await h.engine.runNow(entered.id)
        #expect(test.flatMap { h.doc.record($0.recordID) }.map { h.doc.matches($0, filter: h.doc.view(view)!.config.filter!) } == true)
        h.session.close()
    }

    // MARK: - When a webhook is received

    @Test func webhooksRunWithTheirDataAndRejectBadRequests() async throws {
        let h = try await harness()
        var create = AutomationAction(kind: .createRecord)
        create.tableID = h.table
        create.fieldValues = [h.name: "{{trigger.body.name}} from {{trigger.query.source}} via {{trigger.headers.user-agent}}"]
        let id = h.doc.createAutomation(name: "Hook", trigger: AutomationTrigger(kind: .webhookReceived), actions: [create], enabled: true)
        let token = try #require(h.doc.automation(id)?.trigger.webhookToken)
        #expect(token.count == 32)
        #expect(Webhooks.url(automationID: id, token: token, port: 8738) == "http://127.0.0.1:8738/hooks/\(id)/\(token)")

        let body = #"{"name":"Ada","tags":["a","b"]}"#
        let request = try completeRequest("POST /hooks/\(id)/\(token)?source=cli HTTP/1.1\r\nHost: 127.0.0.1:8738\r\nUser-Agent: tester\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        let response = await AutomationEngine.respond(to: request, engines: [h.engine])
        #expect(response.status == 200)
        #expect(response.body["ok"] == .bool(true))
        let runID = try #require(response.body["runId"]?.stringValue)
        await settle(h.engine)
        #expect(titles(h, h.table) == ["Ada from cli via tester"])
        let run = try #require(h.session.runs.first { $0.id == runID })
        #expect(run.status == .succeeded)
        #expect(run.trigger == "Webhook received (POST)")

        func status(_ r: WebhookRequest) async -> Int { await AutomationEngine.respond(to: r, engines: [h.engine]).status }
        var wrongToken = request
        wrongToken.path = Webhooks.path(automationID: id, token: String(token.reversed()))
        #expect(await status(wrongToken) == 401)
        var shortToken = request
        shortToken.path = Webhooks.path(automationID: id, token: String(token.prefix(8)))
        #expect(await status(shortToken) == 401)
        var unknown = request
        unknown.path = Webhooks.path(automationID: "autMissing000000", token: token)
        #expect(await status(unknown) == 404)
        var elsewhere = request
        elsewhere.path = "/other"
        #expect(await status(elsewhere) == 404)
        var put = request
        put.method = "PUT"
        let refused = await AutomationEngine.respond(to: put, engines: [h.engine])
        #expect(refused.status == 405)
        #expect(refused.headers["Allow"] == "GET, POST")
        #expect(await h.engine.webhookReceived(automationID: id, token: "nope", request: request) == .unauthorized)
        await settle(h.engine)
        #expect(h.doc.recordCount(in: h.table) == 1)

        // A GET with a query string works too.
        let get = try completeRequest("GET /hooks/\(id)/\(token)?source=browser HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(await status(get) == 200)
        await settle(h.engine)
        #expect(titles(h, h.table).last == " from browser via ")

        // Turned off: refused, but kept as the sample that test runs and the token menu use.
        h.doc.updateAutomation(id) { $0.enabled = false }
        var second = request
        second.body = ["name": "Grace", "role": "admiral"]
        #expect(await status(second) == 409)
        await settle(h.engine)
        #expect(h.doc.recordCount(in: h.table) == 2)
        let tokens = h.engine.availableTokens(for: try #require(h.doc.automation(id)), stepIndex: 0).map(\.path)
        #expect(tokens.contains("trigger.body.name"))
        #expect(tokens.contains("trigger.body.role"))
        #expect(tokens.contains("trigger.query.source"))
        let test = await h.engine.runNow(id)
        #expect(test?.status == .succeeded)
        #expect(titles(h, h.table).last == "Grace from cli via tester")

        // Duplicates get their own secret.
        let copy = try #require(h.doc.duplicateAutomation(id))
        #expect(h.doc.automation(copy)?.trigger.webhookToken != token)
        h.session.close()
    }

    // MARK: - Repeat for each

    /// Tasks A (Todo), B (Done), C (Todo) plus a Log table.
    func repeatSetup(_ h: Harness) -> (a: String, b: String, c: String, log: String) {
        let a = h.doc.createRecord(in: h.table, values: [h.name: "A", h.status: choice(h, "Todo")])
        let b = h.doc.createRecord(in: h.table, values: [h.name: "B", h.status: choice(h, "Done")])
        let c = h.doc.createRecord(in: h.table, values: [h.name: "C", h.status: choice(h, "Todo")])
        let log = h.doc.createTable(name: "Log", starterFields: false, emptyRecords: 0)
        return (a, b, c, log)
    }

    func findTodo(_ h: Harness) -> AutomationAction {
        var find = AutomationAction(kind: .findRecords)
        find.tableID = h.table
        find.filter = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .is, value: [choice(h, "Todo")])])
        return find
    }

    @Test func repeatCreatesAndUpdatesOncePerFoundRecord() async throws {
        let h = try await harness()
        let (a, b, c, log) = repeatSetup(h)
        let logName = h.doc.primaryField(of: log)!.id
        var create = AutomationAction(kind: .createRecord)
        create.repeatFrom = 1
        create.tableID = log
        create.fieldValues = [logName: "{{index}}. {{item.Name}} ({{item.Status}}) {{item.id}}"]
        var update = AutomationAction(kind: .updateRecord)
        update.repeatFrom = 1
        update.tableID = h.table
        update.fieldValues = [h.done: "true", h.name: "{{item.Name}} done"]
        var summary = AutomationAction(kind: .sendNotification)
        summary.title = "{{steps.2.count}}: {{steps.2.items.title}}"
        summary.body = "{{steps.3.items.id}}"
        // Records the repeat creates are ordinary automation writes, so they trigger other automations.
        h.doc.createAutomation(name: "Log watcher", trigger: AutomationTrigger(kind: .recordCreated, tableID: log), actions: [AutomationAction(kind: .runShortcut)], enabled: true)
        let id = h.doc.createAutomation(name: "Close todos", trigger: AutomationTrigger(kind: .manual), actions: [findTodo(h), create, update, summary], enabled: true)

        let run = try #require(await h.engine.runNow(id))
        await settle(h.engine)
        #expect(run.status == .succeeded)
        #expect(Array(run.steps.map(\.message)[1...2]) == ["Ran 2 times", "Ran 2 times"])
        #expect(run.steps[1].logs.count == 2)
        #expect(titles(h, log) == ["1. A (Todo) \(a)", "2. C (Todo) \(c)"])
        #expect(titles(h, h.table) == ["A done", "B", "C done"])
        #expect(h.doc.value(h.doc.record(a)!, h.doc.field(h.done)!) == .bool(true))
        #expect(h.doc.value(h.doc.record(b)!, h.doc.field(h.done)!).isEmpty)
        #expect(h.services.notifications.first?.0 == "2: 1. A (Todo) \(a), 2. C (Todo) \(c)")
        #expect(h.services.notifications.first?.1 == "\(a), \(c)")
        #expect(h.session.runs.filter { $0.automationName == "Log watcher" }.count == 2)
        h.session.close()
    }

    @Test func repeatedWritesStillStopAtTheChainDepthLimit() async throws {
        let h = try await harness()
        var find = AutomationAction(kind: .findRecords)
        find.tableID = h.table
        find.limit = 1
        var create = AutomationAction(kind: .createRecord)
        create.repeatFrom = 1
        create.tableID = h.table
        create.fieldValues = [h.name: "child of {{item.Name}}"]
        h.doc.createAutomation(name: "Loop", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [find, create], enabled: true)
        h.doc.createRecord(in: h.table, values: [h.name: "root"])
        for _ in 0..<3 {
            await settle(h.engine)
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(h.doc.recordCount(in: h.table) == 1 + AutomationEngine.maxChainDepth)
        h.session.close()
    }

    @Test func repeatOverPlainValuesStopsAtTheItemLimit() async throws {
        let h = try await harness()
        var script = AutomationAction(kind: .runScript)
        script.script = "output.set('values', Array.from({ length: 150 }, (_, i) => 'v' + i));"
        var notify = AutomationAction(kind: .sendNotification)
        notify.repeatFrom = 1
        notify.repeatPath = "values"
        notify.title = "{{index}}:{{item}}"
        let id = h.doc.createAutomation(name: "Many", trigger: AutomationTrigger(kind: .manual), actions: [script, notify], enabled: true)
        let run = try #require(await h.engine.runNow(id))
        #expect(run.status == .succeeded)
        #expect(h.services.notifications.count == AutomationEngine.maxRepeatItems)
        #expect(h.services.notifications.first?.0 == "1:v0")
        #expect(h.services.notifications.last?.0 == "100:v99")
        #expect(run.steps[1].message.hasPrefix("Ran 100 times. Only the first 100 of 150 items ran"))
        h.session.close()
    }

    @Test func repeatConditionsApplyToEachItem() async throws {
        let h = try await harness()
        let (_, b, _, _) = repeatSetup(h)
        var findAll = AutomationAction(kind: .findRecords)
        findAll.tableID = h.table
        var perRecord = AutomationAction(kind: .sendNotification)
        perRecord.repeatFrom = 1
        perRecord.title = "{{item.Name}}"
        perRecord.condition = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .is, value: [choice(h, "Done")])])
        var script = AutomationAction(kind: .runScript)
        script.script = "output.set('items', ['x', 'y']);"
        // Plain values have no record, so their conditions check the trigger record.
        var perValue = AutomationAction(kind: .sendNotification)
        perValue.repeatFrom = 3
        perValue.repeatPath = "items"
        perValue.title = "value {{item}}"
        perValue.condition = FilterGroup(conditions: [FilterCondition(fieldID: h.status, op: .is, value: [choice(h, "Done")])])
        let id = h.doc.createAutomation(name: "Conditional", trigger: AutomationTrigger(kind: .buttonClicked, tableID: h.table), actions: [findAll, perRecord, script, perValue], enabled: true)

        let withDoneTrigger = try #require(await h.engine.runNow(id, recordID: b))
        #expect(withDoneTrigger.steps[1].message == "Ran once, skipped 2 (conditions not met)")
        #expect(withDoneTrigger.steps[3].message == "Ran 2 times")
        #expect(h.services.notifications.map(\.0) == ["B", "value x", "value y"])

        let first = try #require(h.doc.records(in: h.table).first?.id)
        let withTodoTrigger = try #require(await h.engine.runNow(id, recordID: first))
        #expect(withTodoTrigger.status == .succeeded)
        #expect(withTodoTrigger.steps[3].status == .skipped)
        #expect(withTodoTrigger.steps[3].message == "Skipped all 2 items: conditions not met")
        #expect(h.services.notifications.count == 4)
        h.session.close()
    }

    @Test func repeatHandlesEmptyListsAndBadSources() async throws {
        let h = try await harness()
        var findNone = AutomationAction(kind: .findRecords)
        findNone.tableID = h.table
        var each = AutomationAction(kind: .sendNotification)
        each.repeatFrom = 1
        var after = AutomationAction(kind: .sendNotification)
        after.title = "found {{steps.2.count}}"
        let empty = h.doc.createAutomation(name: "Empty", trigger: AutomationTrigger(kind: .manual), actions: [findNone, each, after], enabled: true)
        let emptyRun = try #require(await h.engine.runNow(empty))
        #expect(emptyRun.status == .succeeded)
        #expect(emptyRun.steps.map(\.status) == [.succeeded, .skipped, .succeeded])
        #expect(h.services.notifications.map(\.0) == ["found 0"])

        var selfReference = AutomationAction(kind: .sendNotification)
        selfReference.repeatFrom = 1
        let badSource = h.doc.createAutomation(name: "Bad", trigger: AutomationTrigger(kind: .manual), actions: [selfReference], enabled: true)
        let badRun = try #require(await h.engine.runNow(badSource))
        #expect(badRun.status == .failed)
        #expect(badRun.steps.first?.message == "Choose an earlier step to repeat for")

        var notAList = AutomationAction(kind: .sendNotification)
        notAList.repeatFrom = 1
        notAList.repeatPath = "count"
        let scalar = h.doc.createAutomation(name: "Scalar", trigger: AutomationTrigger(kind: .manual), actions: [findNone, notAList], enabled: true)
        let scalarRun = try #require(await h.engine.runNow(scalar))
        #expect(scalarRun.status == .failed)
        #expect(scalarRun.steps.last?.message == "“count” in the output of step 1 isn't a list")
        h.session.close()
    }

    @Test func repeatFailuresAreCountedAndLogged() async throws {
        let h = try await harness()
        let (a, _, _, _) = repeatSetup(h)
        var script = AutomationAction(kind: .runScript)
        script.inputs = ["id": "{{trigger.record.id}}"]
        script.script = "output.set('ids', [input.config().id, 'recMissing', input.config().id]);"
        var update = AutomationAction(kind: .updateRecord)
        update.repeatFrom = 1
        update.repeatPath = "ids"
        update.tableID = h.table
        update.fieldValues = [h.done: "true"]
        let id = h.doc.createAutomation(name: "Partial", trigger: AutomationTrigger(kind: .buttonClicked, tableID: h.table), actions: [script, update, AutomationAction(kind: .sendNotification)], enabled: true)
        let run = try #require(await h.engine.runNow(id, recordID: a))
        #expect(run.status == .failed)
        #expect(run.steps.count == 2)
        #expect(run.steps[1].message == "Ran 3 times (1 failed)")
        #expect(run.steps[1].logs.contains("Item 2 failed: Couldn't find record “recMissing” in Tasks"))
        #expect(h.doc.value(h.doc.record(a)!, h.doc.field(h.done)!) == .bool(true))
        #expect(h.services.notifications.isEmpty)
        h.session.close()
    }

    @Test func repeatingStepsOfferItemTokensAndSources() async throws {
        let h = try await harness()
        _ = repeatSetup(h)
        var create = AutomationAction(kind: .createRecord)
        create.repeatFrom = 1
        create.tableID = h.table
        var notify = AutomationAction(kind: .sendNotification)
        notify.repeatFrom = 2
        let id = h.doc.createAutomation(name: "Tokens", trigger: AutomationTrigger(kind: .manual), actions: [findTodo(h), create, notify, AutomationAction(kind: .sendEmail)])
        let automation = try #require(h.doc.automation(id))

        let createTokens = h.engine.availableTokens(for: automation, stepIndex: 1).map(\.path)
        #expect(createTokens.contains("item"))
        #expect(createTokens.contains("index"))
        #expect(createTokens.contains("item.id"))
        #expect(createTokens.contains("item.Status"))
        let lastTokens = h.engine.availableTokens(for: automation, stepIndex: 3).map(\.path)
        #expect(lastTokens.contains("steps.2.items.id"))
        #expect(lastTokens.contains("steps.3.count"))
        #expect(!lastTokens.contains("item"))

        let sources = h.engine.repeatSources(for: automation, before: 3)
        #expect(sources.map(\.step) == [1, 2, 3])
        #expect(sources.map(\.path) == ["records", "items", "items"])
        #expect(sources.map(\.tableID) == [h.table, h.table, nil])
        #expect(h.engine.repeatItemTableID(for: automation, stepIndex: 2) == h.table)
        #expect(h.engine.repeatPath(for: automation.actions[2], in: automation) == "items")
        h.session.close()
    }

    // MARK: - Send email

    @Test func sendEmailPassesRenderedFieldsToMail() async throws {
        let h = try await harness()
        var email = AutomationAction(kind: .sendEmail)
        email.to = "{{trigger.record.Name}}@example.com, Grace Hopper <grace@example.org>"
        email.cc = "team@example.com; TEAM@example.com"
        email.subject = "New task:\n{{trigger.record.Name}}"
        email.body = "Hello {{trigger.record.Name}},\n\"quoted\" \\ done"
        let id = h.doc.createAutomation(name: "Mail", trigger: AutomationTrigger(kind: .recordCreated, tableID: h.table), actions: [email], enabled: true)
        h.doc.createRecord(in: h.table, values: [h.name: "ada"])
        await settle(h.engine)
        #expect(h.services.emails == [FakeServices.SentEmail(to: ["ada@example.com", "grace@example.org"], cc: ["team@example.com"], bcc: [],
                                                              subject: "New task: ada", body: "Hello ada,\n\"quoted\" \\ done")])
        let sent = try #require(h.session.runs.first { $0.automationName == "Mail" })
        #expect(sent.status == .succeeded)
        #expect(sent.steps.first?.message == "Sent “New task: ada” to ada@example.com, grace@example.org")

        func runAgain(_ change: (inout AutomationAction) -> Void) async throws -> StepResult {
            h.doc.updateAutomation(id) { change(&$0.actions[0]) }
            let run = try #require(await h.engine.runNow(id))
            return try #require(run.steps.first)
        }
        let invalid = try await runAgain { $0.to = "ada@example.com, not an address" }
        #expect(invalid.status == .failed)
        #expect(invalid.message == "“not an address” isn't a valid email address")
        let missing = try await runAgain { $0.to = "{{trigger.record.Nothing}}" }
        #expect(missing.message == "Add at least one recipient in To")
        h.services.emailError = ParityTestError(description: "offline")
        let failing = try await runAgain { $0.to = "ada@example.com" }
        #expect(failing.status == .failed)
        #expect(failing.message.hasPrefix("Email failed:"))
        #expect(h.services.emails.count == 1)
        h.session.close()
    }
}

@Suite("Webhook requests")
struct WebhookRequestTests {
    @Test func getRequestsParseTheQueryAndHeaders() throws {
        let request = try completeRequest("GET /hooks/aut1/tok1?name=Ada+Lovelace&tag=a&tag=b&empty=&pct=%26%3D%C3%A9 HTTP/1.1\r\nHost: 127.0.0.1:8738\r\nUser-Agent: curl/8.7\r\nX-Custom: one\r\nx-custom:  two \r\n\r\n")
        #expect(request.method == "GET")
        #expect(request.path == "/hooks/aut1/tok1")
        #expect(request.query == ["name": "Ada Lovelace", "tag": ["a", "b"], "empty": "", "pct": "&=é"])
        #expect(request.headers["host"] == "127.0.0.1:8738")
        #expect(request.headers["user-agent"] == "curl/8.7")
        #expect(request.headers["x-custom"] == "one, two")
        #expect(request.body == .null)
        #expect(request.rawBody.isEmpty)
    }

    @Test func postBodiesDecodeByContentType() throws {
        func post(_ body: String, type: String?) throws -> WebhookRequest {
            let typeHeader = type.map { "Content-Type: \($0)\r\n" } ?? ""
            return try completeRequest("POST /hooks/a/b HTTP/1.1\r\nHost: x\r\n\(typeHeader)Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
        let json = try post(#"{"name":"Ada","n":3,"nested":{"ok":true}}"#, type: "application/json; charset=utf-8")
        #expect(json.body == ["name": "Ada", "n": 3, "nested": ["ok": true]])
        #expect(try post(#"[1,2]"#, type: "application/vnd.api+json").body == [1, 2])
        #expect(try post("name=Ada+L&city=L%C3%B8nd&x=1&x=2", type: "application/x-www-form-urlencoded").body == ["name": "Ada L", "city": "Lønd", "x": ["1", "2"]])
        // `curl -d '{…}'` labels JSON as a form; it's still read as JSON.
        #expect(try post(#"{"a":1}"#, type: "application/x-www-form-urlencoded").body == ["a": 1])
        #expect(try post("hello\nworld", type: "text/plain").body == "hello\nworld")
        #expect(try post("[not json", type: nil).body == "[not json")
        let text = try post("héllo", type: "text/plain")
        #expect(text.rawBody == Data("héllo".utf8))
        #expect(throws: WebhookRequest.ParseError(status: 400, message: "The body isn't valid JSON")) {
            try post("{broken", type: "application/json")
        }
    }

    @Test func requestsArriveInPieces() throws {
        let body = #"{"a":1}"#
        let full = "POST /hooks/a/b HTTP/1.1\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let bytes = Data(full.utf8)
        #expect(try WebhookRequest.parse(bytes.prefix(20)) == .incomplete(total: nil, expectsContinue: false))
        let headerLength = bytes.count - body.utf8.count
        #expect(try WebhookRequest.parse(bytes.prefix(headerLength)) == .incomplete(total: bytes.count, expectsContinue: true))
        #expect(try WebhookRequest.parse(bytes.prefix(bytes.count - 1)) == .incomplete(total: bytes.count, expectsContinue: true))
        guard case .complete(let request) = try WebhookRequest.parse(bytes + Data("GET / HTTP/1.1\r\n".utf8)) else {
            throw ParityTestError(description: "expected a complete request")
        }
        #expect(request.body == ["a": 1])
        // Bare line feeds and absolute-form targets are accepted.
        let loose = try completeRequest("POST http://127.0.0.1:8738/hooks/a/b?x=1 HTTP/1.0\nContent-Length: 2\n\nhi")
        #expect(loose.path == "/hooks/a/b")
        #expect(loose.query == ["x": "1"])
        #expect(loose.body == "hi")
    }

    @Test func invalidRequestsAreRejected() throws {
        func status(_ raw: String) -> Int? {
            do {
                _ = try WebhookRequest.parse(Data(raw.utf8))
                return nil
            } catch let error as WebhookRequest.ParseError {
                return error.status
            } catch {
                return -1
            }
        }
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nHost: x\r\n\r\n") == 411)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n") == 411)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nContent-Length: \(Webhooks.maxBodyBytes + 1)\r\n\r\n") == 413)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd") == 400)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nContent-Length: -3\r\n\r\n") == 400)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n") == 400)
        #expect(status("GET /hooks/a/b\r\n\r\n") == 400)
        #expect(status("get /hooks/a/b HTTP/1.1\r\n\r\n") == 400)
        #expect(status("GET /hooks/a/b HTTP/2.0\r\n\r\n") == 505)
        #expect(status("GET /hooks/a/b HTTP/1.1\r\nBad Header: x\r\n\r\n") == 400)
        #expect(status("GET /hooks/a/b HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n") == 400)
        #expect(status("GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: Webhooks.maxHeaderBytes)) == 431)
        #expect(status("POST /hooks/a/b HTTP/1.1\r\nContent-Length: 5, 5\r\n\r\nhello") == nil)
    }

    @Test func routesAndTokens() {
        #expect(Webhooks.route("/hooks/autA1/tok9").map { [$0.automationID, $0.token] } == ["autA1", "tok9"])
        #expect(Webhooks.route("/hooks/autA1/tok9/").map { [$0.automationID, $0.token] } == ["autA1", "tok9"])
        #expect(Webhooks.route("/hooks/autA1") == nil)
        #expect(Webhooks.route("/hooks/autA1/tok9/extra") == nil)
        #expect(Webhooks.route("/hook/autA1/tok9") == nil)
        #expect(Webhooks.route("/hooks/aut A1/tok9") == nil)
        #expect(Webhooks.route("/hooks/../tok9") == nil)
        #expect(Webhooks.constantTimeEquals("abc123", "abc123"))
        #expect(!Webhooks.constantTimeEquals("abc124", "abc123"))
        #expect(!Webhooks.constantTimeEquals("abc12", "abc123"))
        #expect(!Webhooks.constantTimeEquals("abc1234", "abc123"))
        #expect(!Webhooks.constantTimeEquals("", "abc123"))
        let a = Webhooks.makeToken(), b = Webhooks.makeToken()
        #expect(a.count == 32 && a != b)
        #expect(a.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }

    @Test func responsesAreSerializedAsHTTP() throws {
        let data = WebhookResponse.error(405, "Use GET or POST", headers: ["Allow": "GET, POST"]).serialized()
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        let head = parts[0].components(separatedBy: "\r\n")
        #expect(head.first == "HTTP/1.1 405 Method Not Allowed")
        #expect(head.contains("Allow: GET, POST"))
        #expect(head.contains("Connection: close"))
        #expect(head.contains("Content-Length: \(parts[1].utf8.count)"))
        #expect(try JSONValue.parse(parts[1]) == ["ok": false, "error": "Use GET or POST"])
    }
}

@Suite("Mail and templates")
struct MailScriptTests {
    @Test func appleScriptStringsEscapeQuotesBackslashesAndNewlines() {
        #expect(MailScript.quoted("plain") == #""plain""#)
        #expect(MailScript.quoted(#"say "hi""#) == #""say \"hi\"""#)
        #expect(MailScript.quoted(#"C:\path\"#) == #""C:\\path\\""#)
        #expect(MailScript.quoted("a\nb\r\nc\td") == #""a\nb\r\nc\td""#)
        #expect(MailScript.quoted("bell\u{07}\u{7F}end") == #""bellend""#)
        #expect(MailScript.quoted("é 🚀") == "\"é 🚀\"")
        let hostile = #"" & (do shell script "echo pwned") & ""#
        let script = MailScript.sendScript(to: ["a@b.co"], cc: ["c@d.co"], bcc: [], subject: hostile, body: "line\nline")
        #expect(script.contains(#"subject:"\" & (do shell script \"echo pwned\") & \"""#))
        #expect(script.contains(#"content:"line\nline""#))
        #expect(script.contains(#"make new to recipient at end of to recipients with properties {address:"a@b.co"}"#))
        #expect(script.contains(#"make new cc recipient at end of cc recipients with properties {address:"c@d.co"}"#))
        #expect(!script.contains("bcc recipient"))
    }

    @Test @MainActor func quotedTextRoundTripsThroughAppleScript() throws {
        let samples = ["plain", #"say "hi""#, #"back\slash\"#, "two\nlines", "crlf\r\nend", "tab\there", "émoji 🚀", #"" & (do shell script "echo pwned") & ""#]
        for text in samples {
            let script = try #require(NSAppleScript(source: "return " + MailScript.quoted(text)))
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            #expect(error == nil)
            #expect(result.stringValue == text)
        }
    }

    @Test func recipientListsAreValidated() throws {
        #expect(try MailScript.addresses(from: " a@example.com, B <b@example.org>;c@sub.example.co.uk\n\n") == ["a@example.com", "b@example.org", "c@sub.example.co.uk"])
        #expect(try MailScript.addresses(from: "a@example.com, A@EXAMPLE.com") == ["a@example.com"])
        #expect(try MailScript.addresses(from: "  , ;") == [])
        for bad in ["plain", "a@b", "a@@b.com", "a b@c.com", "a@b..com", ".a@b.com", "a@-b.com", "\"a\"@b.com", "a@b.com\r\nBcc: x@y.z"] {
            #expect(throws: MailScript.InvalidAddress.self) { try MailScript.addresses(from: bad) }
        }
    }

    @Test func templatesReadFieldsAcrossLists() {
        let scope: JSONValue = ["list": [["name": "a", "id": 1], ["name": "b"], "plain"]]
        #expect(TemplateRenderer.render("{{list.name}}", scope: scope) == "a, b")
        #expect(TemplateRenderer.render("{{list.id}}", scope: scope) == "1")
        #expect(TemplateRenderer.render("{{list.0.name}}|{{list.count}}|{{list.7.name}}|{{list.-1}}", scope: scope) == "a|3||")
    }
}
