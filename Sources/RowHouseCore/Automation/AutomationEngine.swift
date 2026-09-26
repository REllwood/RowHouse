import Foundation
import Observation

/// Side effects that leave the app. The app provides real implementations; tests provide fakes.
public protocol AutomationServices: Sendable {
    func sendNotification(title: String, body: String) async throws
    func perform(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data)
    func runShortcut(named name: String, input: String) async throws -> String
    /// Sends an email; recipients are already validated addresses.
    func sendEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws
}

/// Runs a base's automations.
///
/// To make sure an automation runs exactly once even with several Macs sharing a base:
/// record triggers fire only on the Mac where the change was made (remote changes never fire),
/// scheduled triggers fire only on the base's automation host, and webhooks run on the Mac that
/// received them (the server only listens on the loopback interface).
@MainActor
@Observable
public final class AutomationEngine {
    public let session: BaseSession
    public var document: BaseDocument { session.document }
    public private(set) var activeRuns = 0
    /// The latest request each webhook automation received, used for test runs and the editor's tokens.
    public private(set) var lastWebhookRequests: [String: WebhookRequest] = [:]

    @ObservationIgnored private let services: AutomationServices
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var scheduleTimer: Timer?
    /// Records currently matching each "matches conditions" / "enters view" trigger.
    @ObservationIgnored private var matching: [String: Set<String>] = [:]
    @ObservationIgnored private var matchingKeys: [String: String] = [:]
    @ObservationIgnored private var recentRuns: [String: [Date]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    public static let maxChainDepth = 5
    public static let maxRunsPerMinute = 60
    /// A repeating step runs for at most this many items per run.
    public static let maxRepeatItems = 100

    public init(session: BaseSession, services: AutomationServices, defaults: UserDefaults = .standard) {
        self.session = session
        self.services = services
        self.defaults = defaults
        rebuildMatchingCache()
        observer = document.addObserver { [weak self] changes in
            self?.handle(changes)
        }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedules() }
        }
        checkSchedules()
    }

    public func stop() {
        if let observer { document.removeObserver(observer) }
        observer = nil
        scheduleTimer?.invalidate()
        scheduleTimer = nil
    }

    public var isScheduleHost: Bool {
        document.effectiveAutomationHost == document.deviceID
    }

    // MARK: - Triggers

    func handle(_ changes: ChangeSet) {
        // View edits change which records an "enters view" trigger sees, so re-baseline on schema changes too.
        if changes.automationsChanged || changes.schemaChanged { rebuildMatchingCache() }
        guard changes.hasRecordChanges else { return }
        let fire = !changes.origin.isRemote && changes.origin.automationDepth < Self.maxChainDepth
        let depth = changes.origin.automationDepth

        for automation in document.automations {
            let trigger = automation.trigger
            guard let tableID = trigger.tableID else { continue }
            switch trigger.kind {
            case .recordCreated:
                guard fire, automation.enabled else { continue }
                for (recordID, t) in changes.createdRecords where t == tableID {
                    start(automation, recordID: recordID, trigger: "Record created", depth: depth)
                }
            case .recordUpdated:
                guard fire, automation.enabled else { continue }
                let watched = Set(trigger.watchedFieldIDs ?? [])
                for (recordID, fieldIDs) in changes.updatedRecords {
                    guard document.record(recordID)?.tableID == tableID else { continue }
                    if !watched.isEmpty && watched.isDisjoint(with: fieldIDs) { continue }
                    start(automation, recordID: recordID, trigger: "Record updated", depth: depth)
                }
            case .recordMatchesConditions, .recordEntersView:
                guard let filter = membershipFilter(of: automation) else { continue }
                var current = matching[automation.id] ?? []
                for recordID in changes.deletedRecords.keys { current.remove(recordID) }
                // Records brought back by undo rejoin silently, like records that were already there.
                for (recordID, t) in changes.restoredRecords where t == tableID {
                    if let record = document.record(recordID), document.matches(record, filter: filter) { current.insert(recordID) }
                }
                let label = trigger.kind == .recordEntersView
                    ? "Record entered view “\(document.view(trigger.viewID)?.name ?? "")”"
                    : "Record matched conditions"
                let candidates = Array(changes.createdRecords.keys) + Array(changes.updatedRecords.keys)
                for recordID in candidates {
                    guard let record = document.record(recordID), record.tableID == tableID else { continue }
                    let nowMatches = document.matches(record, filter: filter)
                    let wasMatching = current.contains(recordID)
                    if nowMatches {
                        current.insert(recordID)
                        if !wasMatching && fire && automation.enabled {
                            start(automation, recordID: recordID, trigger: label, depth: depth)
                        }
                    } else {
                        current.remove(recordID)
                    }
                }
                matching[automation.id] = current
            default:
                continue
            }
        }
    }

    /// The filter a record must match to count as "in" a conditions or view trigger.
    private func membershipFilter(of automation: AutomationModel) -> FilterGroup? {
        let trigger = automation.trigger
        switch trigger.kind {
        case .recordMatchesConditions:
            return trigger.filter
        case .recordEntersView:
            // Only the view's filter counts; search text and collapsed groups are per-window state.
            guard let view = document.view(trigger.viewID), view.tableID == trigger.tableID else { return nil }
            return view.config.filter ?? FilterGroup()
        default:
            return nil
        }
    }

    private func rebuildMatchingCache() {
        var fresh: [String: Set<String>] = [:]
        var keys: [String: String] = [:]
        for automation in document.automations {
            guard let tableID = automation.trigger.tableID, let filter = membershipFilter(of: automation) else { continue }
            let key = JSONValue(encoding: automation.trigger).jsonString + "|" + JSONValue(encoding: filter).jsonString
            keys[automation.id] = key
            // Keep what we already knew so edits elsewhere don't re-arm this trigger.
            if let existing = matching[automation.id], matchingKeys[automation.id] == key {
                fresh[automation.id] = existing
                continue
            }
            fresh[automation.id] = Set(document.records(in: tableID).filter { document.matches($0, filter: filter) }.map(\.id))
        }
        matching = fresh
        matchingKeys = keys
    }

    public func formSubmitted(viewID: String, recordID: String) {
        for automation in document.automations where automation.enabled && automation.trigger.kind == .formSubmitted && automation.trigger.viewID == viewID {
            start(automation, recordID: recordID, trigger: "Form submitted", depth: 0)
        }
    }

    public func buttonClicked(automationID: String, recordID: String) {
        guard let automation = document.automation(automationID), automation.enabled else { return }
        start(automation, recordID: recordID, trigger: "Button clicked", depth: 0)
    }

    public enum WebhookResult: Sendable, Equatable {
        case accepted(runID: String)
        case notFound
        case unauthorized
        case disabled
        case rateLimited
    }

    /// Starts a webhook automation for a request whose URL carried `token`. The request is kept as the
    /// automation's sample even when it's turned off, so it can be set up with real data.
    public func webhookReceived(automationID: String, token: String, request: WebhookRequest) async -> WebhookResult {
        guard let automation = document.automation(automationID), automation.trigger.kind == .webhookReceived else { return .notFound }
        guard let expected = automation.trigger.webhookToken, !expected.isEmpty, Webhooks.constantTimeEquals(token, expected) else {
            return .unauthorized
        }
        lastWebhookRequests[automationID] = request
        guard automation.enabled else { return .disabled }
        guard let runID = start(automation, recordID: nil, trigger: "Webhook received (\(request.method))", depth: 0, webhook: request) else {
            return .rateLimited
        }
        return .accepted(runID: runID)
    }

    /// Answers a request received by the app's webhook server, routing it to whichever open base
    /// owns the automation in its URL.
    public static func respond(to request: WebhookRequest, engines: [AutomationEngine]) async -> WebhookResponse {
        guard let route = Webhooks.route(request.path) else { return .error(404, "Not found") }
        guard request.method == "GET" || request.method == "POST" else {
            return .error(405, "Use GET or POST", headers: ["Allow": "GET, POST"])
        }
        guard let engine = engines.first(where: { $0.document.automation(route.automationID) != nil }) else {
            return .error(404, "No automation matches this URL")
        }
        switch await engine.webhookReceived(automationID: route.automationID, token: route.token, request: request) {
        case .accepted(let runID):
            return WebhookResponse(status: 200, body: .object(["ok": .bool(true), "runId": .string(runID)]))
        case .notFound:
            return .error(404, "No automation matches this URL")
        case .unauthorized:
            return .error(401, "The webhook token doesn't match")
        case .disabled:
            return .error(409, "This automation is turned off")
        case .rateLimited:
            return .error(429, "This automation ran more than \(maxRunsPerMinute) times in the last minute")
        }
    }

    /// Runs an automation now (the editor's "Test" button). Uses `recordID` or the first record the
    /// trigger could fire for; webhook automations reuse the last request they received.
    @discardableResult
    public func runNow(_ automationID: String, recordID: String? = nil) async -> AutomationRun? {
        guard let automation = document.automation(automationID) else { return nil }
        var rid = recordID
        if rid == nil, automation.trigger.kind.providesRecord, let t = automation.trigger.tableID {
            if automation.trigger.kind == .recordEntersView, let filter = membershipFilter(of: automation) {
                rid = document.records(in: t).first { document.matches($0, filter: filter) }?.id
            }
            rid = rid ?? document.records(in: t).first?.id
        }
        let webhook = automation.trigger.kind == .webhookReceived ? lastWebhookRequests[automationID] : nil
        return await execute(automation, runID: RowID.run(), recordID: rid, trigger: "Run manually", depth: 0, webhook: webhook)
    }

    // MARK: - Scheduling

    private func scheduleKey(_ id: String) -> String { "RowHouse.lastScheduledRun.\(document.baseID).\(id)" }

    func checkSchedules(now: Date = Date()) {
        guard isScheduleHost else { return }
        for automation in document.automations where automation.enabled && automation.trigger.kind == .scheduled {
            guard let schedule = automation.trigger.schedule else { continue }
            let key = scheduleKey(automation.id)
            guard let last = defaults.object(forKey: key) as? Date else {
                // First time we see this automation: start counting from now rather than firing immediately.
                defaults.set(now, forKey: key)
                continue
            }
            let next = schedule.nextFireDate(after: last)
            if next <= now {
                defaults.set(now, forKey: key)
                start(automation, recordID: nil, trigger: "Scheduled: \(schedule.summary)", depth: 0)
            }
        }
    }

    public func nextScheduledRun(for automation: AutomationModel) -> Date? {
        guard automation.trigger.kind == .scheduled, let schedule = automation.trigger.schedule else { return nil }
        let last = defaults.object(forKey: scheduleKey(automation.id)) as? Date ?? Date()
        return schedule.nextFireDate(after: last)
    }

    // MARK: - Execution

    /// Starts a run in the background and returns its id, or nil when the rate limit skipped it.
    @discardableResult
    private func start(_ automation: AutomationModel, recordID: String?, trigger: String, depth: Int, webhook: WebhookRequest? = nil) -> String? {
        let now = Date()
        var times = (recentRuns[automation.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard times.count < Self.maxRunsPerMinute else {
            var run = AutomationRun(automationID: automation.id, automationName: automation.name, deviceID: document.deviceID, deviceName: document.deviceName, trigger: trigger, recordID: recordID)
            run.status = .skipped
            run.finishedAt = now
            run.steps = [StepResult(id: "limit", name: "Rate limit", status: .skipped, message: "Skipped: more than \(Self.maxRunsPerMinute) runs in one minute")]
            session.record(run: run)
            return nil
        }
        times.append(now)
        recentRuns[automation.id] = times
        let runID = RowID.run()
        Task { await execute(automation, runID: runID, recordID: recordID, trigger: trigger, depth: depth, webhook: webhook) }
        return runID
    }

    private func execute(_ automation: AutomationModel, runID: String, recordID: String?, trigger: String, depth: Int, webhook: WebhookRequest?) async -> AutomationRun {
        var run = AutomationRun(id: runID, automationID: automation.id, automationName: automation.name, deviceID: document.deviceID, deviceName: document.deviceName, trigger: trigger, recordID: recordID)
        activeRuns += 1
        defer { activeRuns -= 1 }
        session.record(run: run)

        var scope = baseScope(automation: automation, recordID: recordID, webhook: webhook)
        var stepsScope: [String: JSONValue] = [:]
        var failed = false
        for (index, action) in automation.actions.enumerated() {
            let name = action.label?.isEmpty == false ? action.label! : action.kind.displayName
            if action.repeatFrom != nil {
                scope = scope.setting("steps", .object(stepsScope))
                let result = await performRepeating(action, in: automation, stepNumber: index + 1, scope: scope, triggerRecordID: recordID, depth: depth + 1)
                run.steps.append(StepResult(id: action.id, name: name, status: result.status, message: result.message, logs: result.logs))
                if let output = result.output { stepsScope["\(index + 1)"] = output }
                if result.status == .failed {
                    failed = true
                    break
                }
                continue
            }
            if let condition = action.condition, !condition.isEmpty {
                let ok = recordID.flatMap { document.record($0) }.map { document.matches($0, filter: condition) } ?? false
                if !ok {
                    run.steps.append(StepResult(id: action.id, name: name, status: .skipped, message: "Conditions not met"))
                    continue
                }
            }
            scope = scope.setting("steps", .object(stepsScope))
            let result = await perform(action, scope: scope, depth: depth + 1)
            run.steps.append(StepResult(id: action.id, name: name, status: result.ok ? .succeeded : .failed, message: result.message, logs: result.logs))
            stepsScope["\(index + 1)"] = result.output
            if !result.ok {
                failed = true
                break
            }
        }
        run.status = failed ? .failed : .succeeded
        run.finishedAt = Date()
        session.record(run: run)
        return run
    }

    struct StepOutcome {
        var ok: Bool
        var message: String
        var output: JSONValue = .object([:])
        var logs: [String] = []
    }

    struct RepeatOutcome {
        var status: RunStatus
        var message: String
        var output: JSONValue?
        var logs: [String] = []
    }

    /// Runs `action` once per item of an earlier step's list, exposing `{{item}}` and `{{index}}`.
    private func performRepeating(_ action: AutomationAction, in automation: AutomationModel, stepNumber: Int, scope: JSONValue, triggerRecordID: String?, depth: Int) async -> RepeatOutcome {
        guard let source = action.repeatFrom, source >= 1, source < stepNumber else {
            return RepeatOutcome(status: .failed, message: "Choose an earlier step to repeat for")
        }
        let path = repeatPath(for: action, in: automation)
        let list: [JSONValue]
        switch TemplateRenderer.lookup("steps.\(source).\(path)", in: scope) {
        case nil, .null?: list = []
        case .array(let items)?: list = items
        default: return RepeatOutcome(status: .failed, message: "“\(path)” in the output of step \(source) isn't a list")
        }
        guard !list.isEmpty else {
            return RepeatOutcome(status: .skipped, message: "Nothing to repeat: the list from step \(source) is empty",
                                 output: .object(["items": .array([]), "count": .number(0)]))
        }

        let items = list.prefix(Self.maxRepeatItems)
        var outputs: [JSONValue] = []
        var logs: [String] = []
        var ran = 0, failures = 0, skipped = 0
        func log(_ line: String) { if logs.count < 300 { logs.append(line) } }
        for (offset, item) in items.enumerated() {
            let number = offset + 1
            let itemRecordID = liveRecordID(of: item)
            if let condition = action.condition, !condition.isEmpty {
                guard let record = document.record(itemRecordID ?? triggerRecordID), document.matches(record, filter: condition) else {
                    skipped += 1
                    log("Item \(number): skipped, conditions not met")
                    continue
                }
            }
            var itemScope = item
            if case .object = item, let itemRecordID {
                // Fresh values, so earlier steps' edits to these records show up.
                itemScope = recordScope(itemRecordID)
            }
            // Update and delete steps act on the item unless told otherwise.
            let defaultRecordID = item.objectValue != nil ? "{{item.id}}" : "{{item}}"
            let itemContext = scope.setting("item", itemScope).setting("index", .number(Double(number)))
            let result = await perform(action, scope: itemContext, depth: depth, defaultRecordID: defaultRecordID)
            ran += 1
            if result.ok {
                outputs.append(result.output)
                log("Item \(number): \(result.message)")
            } else {
                failures += 1
                log("Item \(number) failed: \(result.message)")
            }
            for line in result.logs { log("  " + line) }
        }

        var message: String
        if ran == 0 {
            message = skipped == 1 ? "Skipped the only item: conditions not met" : "Skipped all \(skipped) items: conditions not met"
        } else {
            message = ran == 1 ? "Ran once" : "Ran \(ran) times"
            if failures > 0 { message += " (\(failures) failed)" }
            if skipped > 0 { message += ", skipped \(skipped) (conditions not met)" }
        }
        if list.count > items.count {
            message += ". Only the first \(Self.maxRepeatItems) of \(list.count) items ran: a step repeats at most \(Self.maxRepeatItems) times per run"
        }
        let status: RunStatus = failures > 0 ? .failed : (ran == 0 ? .skipped : .succeeded)
        return RepeatOutcome(status: status, message: message, output: .object(["items": .array(outputs), "count": .number(Double(outputs.count))]), logs: logs)
    }

    /// The id of the record an item stands for: a record object (with an `id`) or a bare record id.
    private func liveRecordID(of item: JSONValue) -> String? {
        guard let id = item.stringValue ?? item["id"]?.stringValue, document.record(id) != nil else { return nil }
        return id
    }

    private func perform(_ action: AutomationAction, scope: JSONValue, depth: Int, defaultRecordID: String = "{{trigger.record.id}}") async -> StepOutcome {
        let origin = ChangeOrigin.automation(depth: depth)
        func render(_ s: String?) -> String { TemplateRenderer.render(s ?? "", scope: scope) }

        switch action.kind {
        case .createRecord:
            guard let tableID = action.tableID, let table = document.table(tableID) else {
                return StepOutcome(ok: false, message: "Choose a table to create the record in")
            }
            let values = renderedValues(action.fieldValues, tableID: tableID, scope: scope)
            let id = document.createRecord(in: tableID, values: values, origin: origin)
            return StepOutcome(ok: true, message: "Created a record in \(table.name)", output: recordScope(id))

        case .updateRecord:
            guard let tableID = action.tableID else { return StepOutcome(ok: false, message: "Choose a table") }
            let rid = render(action.recordIDTemplate?.isEmpty == false ? action.recordIDTemplate : defaultRecordID).trimmingCharacters(in: .whitespaces)
            guard let record = document.record(rid), record.tableID == tableID else {
                return StepOutcome(ok: false, message: "Couldn't find record “\(rid)” in \(document.table(tableID)?.name ?? "the table")")
            }
            let values = renderedValues(action.fieldValues, tableID: tableID, scope: scope)
            document.updateRecord(rid, values: values, actionName: "Automation Update", origin: origin)
            return StepOutcome(ok: true, message: "Updated \(document.primaryTitle(recordID: rid))", output: recordScope(rid))

        case .deleteRecord:
            let rid = render(action.recordIDTemplate?.isEmpty == false ? action.recordIDTemplate : defaultRecordID).trimmingCharacters(in: .whitespaces)
            guard document.record(rid) != nil else { return StepOutcome(ok: false, message: "Couldn't find record “\(rid)”") }
            let title = document.primaryTitle(recordID: rid)
            document.deleteRecords([rid], origin: origin)
            return StepOutcome(ok: true, message: "Deleted \(title)", output: .object(["id": .string(rid)]))

        case .findRecords:
            guard let tableID = action.tableID, document.table(tableID) != nil else { return StepOutcome(ok: false, message: "Choose a table") }
            var records = document.records(in: tableID)
            if let filter = action.filter, !filter.isEmpty {
                let rendered = renderFilter(filter, scope: scope)
                records = records.filter { document.matches($0, filter: rendered, strict: true) }
            }
            if let limit = action.limit, limit > 0 { records = Array(records.prefix(limit)) }
            let items = records.map { recordScope($0.id) }
            return StepOutcome(ok: true, message: "Found \(records.count) record\(records.count == 1 ? "" : "s")", output: .object([
                "count": .number(Double(records.count)),
                "records": .array(items),
                "ids": .array(records.map { .string($0.id) }),
                "titles": .array(records.map { .string(document.primaryTitle($0)) }),
            ]))

        case .sendNotification:
            let title = render(action.title)
            let body = render(action.body)
            do {
                try await services.sendNotification(title: title.isEmpty ? "RowHouse" : title, body: body)
                return StepOutcome(ok: true, message: "Sent notification “\(title)”")
            } catch {
                return StepOutcome(ok: false, message: "Notification failed: \(error.localizedDescription)")
            }

        case .httpRequest:
            let urlString = render(action.url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return StepOutcome(ok: false, message: "Enter a valid http(s) URL")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = (action.method ?? "POST").uppercased()
            for (k, v) in action.headers ?? [:] where !k.isEmpty { request.setValue(render(v), forHTTPHeaderField: k) }
            if request.httpMethod != "GET", let body = action.body, !body.isEmpty {
                request.httpBody = Data(render(body).utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    let trimmed = render(body).trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
            do {
                let (status, headers, data) = try await services.perform(request)
                let text = String(decoding: data.prefix(200_000), as: UTF8.self)
                var output: [String: JSONValue] = ["status": .number(Double(status)), "body": .string(text)]
                output["headers"] = .object(headers.mapValues(JSONValue.string))
                if let json = try? JSONValue.parse(data) { output["json"] = json }
                let ok = (200..<400).contains(status)
                return StepOutcome(ok: ok, message: "\(request.httpMethod ?? "POST") \(url.host ?? urlString) → \(status)", output: .object(output))
            } catch {
                return StepOutcome(ok: false, message: "Request failed: \(error.localizedDescription)")
            }

        case .runScript:
            guard let source = action.script, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return StepOutcome(ok: false, message: "The script is empty")
            }
            var inputs: [String: JSONValue] = [:]
            for (k, v) in action.inputs ?? [:] where !k.isEmpty { inputs[k] = .string(render(v)) }
            let result = await ScriptRunner.run(source: source, inputs: inputs, document: document, origin: origin)
            if let error = result.error {
                return StepOutcome(ok: false, message: "Script error: \(error)", output: .object(result.output), logs: result.logs)
            }
            return StepOutcome(ok: true, message: "Script finished", output: .object(result.output), logs: result.logs)

        case .runShortcut:
            let name = render(action.shortcutName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return StepOutcome(ok: false, message: "Enter the name of a Shortcut") }
            do {
                let output = try await services.runShortcut(named: name, input: render(action.body))
                return StepOutcome(ok: true, message: "Ran Shortcut “\(name)”", output: .object(["output": .string(output)]))
            } catch {
                return StepOutcome(ok: false, message: "Shortcut failed: \(error.localizedDescription)")
            }

        case .sendEmail:
            let to: [String], cc: [String], bcc: [String]
            do {
                to = try MailScript.addresses(from: render(action.to))
                cc = try MailScript.addresses(from: render(action.cc))
                bcc = try MailScript.addresses(from: render(action.bcc))
            } catch let error as MailScript.InvalidAddress {
                return StepOutcome(ok: false, message: error.message)
            } catch {
                return StepOutcome(ok: false, message: error.localizedDescription)
            }
            guard !to.isEmpty else { return StepOutcome(ok: false, message: "Add at least one recipient in To") }
            let subject = render(action.subject).components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            do {
                try await services.sendEmail(to: to, cc: cc, bcc: bcc, subject: subject, body: render(action.body))
                return StepOutcome(ok: true, message: "Sent “\(subject)” to \(to.joined(separator: ", "))", output: .object([
                    "to": .array(to.map(JSONValue.string)),
                    "subject": .string(subject),
                ]))
            } catch {
                return StepOutcome(ok: false, message: "Email failed: \(error.localizedDescription)")
            }
        }
    }

    private func renderedValues(_ templates: [String: String]?, tableID: String, scope: JSONValue) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for (fieldID, template) in templates ?? [:] {
            guard let field = document.field(fieldID), field.tableID == tableID, field.isEditable else { continue }
            let text = TemplateRenderer.render(template, scope: scope)
            if field.type == .link {
                // Record ids (e.g. from {{trigger.record.id}}) link directly; anything else matches by name.
                let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !parts.isEmpty, parts.allSatisfy({ document.record($0)?.tableID == field.options.linkedTableID }) {
                    values[fieldID] = .array(parts.map(JSONValue.string))
                    continue
                }
            }
            values[fieldID] = document.parseValue(text, for: document.field(fieldID) ?? field, createMissingChoices: true)
        }
        return values
    }

    private func renderFilter(_ filter: FilterGroup, scope: JSONValue) -> FilterGroup {
        var copy = filter
        copy.conditions = filter.conditions.map { c in
            var c = c
            if let s = c.value?.stringValue { c.value = .string(TemplateRenderer.render(s, scope: scope)) }
            return c
        }
        copy.groups = filter.groups.map { renderFilter($0, scope: scope) }
        return copy
    }

    // MARK: - Template scope

    func recordScope(_ recordID: String) -> JSONValue {
        guard let record = document.record(recordID) else { return .object(["id": .string(recordID)]) }
        var obj: [String: JSONValue] = [
            "id": .string(record.id),
            "url": .string("rowhouse://record?base=\(document.baseID)&table=\(record.tableID)&record=\(record.id)"),
            "title": .string(document.primaryTitle(record)),
            "createdTime": .string(DateCoding.iso8601String(record.createdTime)),
        ]
        var byID: [String: JSONValue] = [:]
        for field in document.fields(in: record.tableID) {
            let text = JSONValue.string(document.displayString(record, field))
            byID[field.id] = text
            if obj[field.name] == nil { obj[field.name] = text }
        }
        obj["fields"] = .object(byID)
        return .object(obj)
    }

    func baseScope(automation: AutomationModel, recordID: String?, webhook: WebhookRequest? = nil) -> JSONValue {
        var trigger: [String: JSONValue] = ["type": .string(automation.trigger.kind.rawValue), "time": .string(DateCoding.iso8601String(Date()))]
        if let recordID { trigger["record"] = recordScope(recordID) }
        if automation.trigger.kind == .webhookReceived {
            trigger.merge((webhook ?? WebhookRequest(method: "", path: "")).scope) { _, new in new }
        }
        if let t = document.table(automation.trigger.tableID) {
            trigger["table"] = .object(["id": .string(t.id), "name": .string(t.name)])
        }
        return .object([
            "trigger": .object(trigger),
            "steps": .object([:]),
            "base": .object(["id": .string(document.baseID), "name": .string(document.info.name)]),
            "automation": .object(["id": .string(automation.id), "name": .string(automation.name)]),
            "now": .string(DateCoding.iso8601String(Date())),
            "today": .string(DateCoding.encode(Date(), includeTime: false)),
        ])
    }

    /// Tokens offered by the editor's "Insert value" menu for a step at `stepIndex`.
    public func availableTokens(for automation: AutomationModel, stepIndex: Int) -> [TemplateRenderer.Token] {
        var tokens: [TemplateRenderer.Token] = [
            .init(label: "Now (date & time)", path: "now"),
            .init(label: "Today (date)", path: "today"),
            .init(label: "Base name", path: "base.name"),
        ]
        if automation.trigger.kind.providesRecord, let tableID = automation.trigger.tableID {
            tokens.append(.init(label: "Trigger record ID", path: "trigger.record.id"))
            tokens.append(.init(label: "Trigger record link", path: "trigger.record.url"))
            for f in document.fields(in: tableID) {
                tokens.append(.init(label: "Trigger record › \(f.name)", path: "trigger.record.\(f.name)"))
            }
        }
        if automation.trigger.kind == .webhookReceived {
            let sample = lastWebhookRequests[automation.id]
            tokens.append(.init(label: "Webhook body", path: "trigger.body"))
            for key in sample?.body.objectValue?.keys.sorted() ?? [] {
                tokens.append(.init(label: "Webhook body › \(key)", path: "trigger.body.\(key)"))
            }
            tokens.append(.init(label: "Webhook query string", path: "trigger.query"))
            for key in sample?.query.keys.sorted() ?? [] {
                tokens.append(.init(label: "Webhook query › \(key)", path: "trigger.query.\(key)"))
            }
            tokens.append(.init(label: "Webhook method", path: "trigger.method"))
        }
        if stepIndex < automation.actions.count, automation.actions[stepIndex].repeatFrom != nil {
            tokens.append(.init(label: "Current item", path: "item"))
            tokens.append(.init(label: "Item number (1, 2, 3…)", path: "index"))
            if let tableID = repeatItemTableID(for: automation, stepIndex: stepIndex) {
                tokens.append(.init(label: "Item › Record ID", path: "item.id"))
                tokens.append(.init(label: "Item › Record link", path: "item.url"))
                for f in document.fields(in: tableID) {
                    tokens.append(.init(label: "Item › \(f.name)", path: "item.\(f.name)"))
                }
            }
        }
        for (i, action) in automation.actions.prefix(stepIndex).enumerated() {
            let n = i + 1
            if action.repeatFrom != nil {
                tokens.append(.init(label: "Step \(n) › Number of results", path: "steps.\(n).count"))
                switch action.kind {
                case .createRecord, .updateRecord:
                    tokens.append(.init(label: "Step \(n) › Record IDs", path: "steps.\(n).items.id"))
                    tokens.append(.init(label: "Step \(n) › Record names", path: "steps.\(n).items.title"))
                default:
                    tokens.append(.init(label: "Step \(n) › Results", path: "steps.\(n).items"))
                }
                continue
            }
            switch action.kind {
            case .createRecord, .updateRecord:
                tokens.append(.init(label: "Step \(n) › Record ID", path: "steps.\(n).id"))
                if let t = action.tableID {
                    for f in document.fields(in: t) { tokens.append(.init(label: "Step \(n) › \(f.name)", path: "steps.\(n).\(f.name)")) }
                }
            case .findRecords:
                tokens.append(.init(label: "Step \(n) › Count", path: "steps.\(n).count"))
                tokens.append(.init(label: "Step \(n) › Record names", path: "steps.\(n).titles"))
                tokens.append(.init(label: "Step \(n) › Record IDs", path: "steps.\(n).ids"))
            case .httpRequest:
                tokens.append(.init(label: "Step \(n) › Status", path: "steps.\(n).status"))
                tokens.append(.init(label: "Step \(n) › Response body", path: "steps.\(n).body"))
            case .runScript:
                tokens.append(.init(label: "Step \(n) › Output (use output.set keys)", path: "steps.\(n)"))
            case .runShortcut:
                tokens.append(.init(label: "Step \(n) › Shortcut output", path: "steps.\(n).output"))
            default:
                break
            }
        }
        return tokens
    }

    // MARK: - Repeat for each

    /// An earlier step whose output holds a list a later step can repeat over.
    public struct RepeatSource: Hashable, Sendable {
        /// 1-based step number.
        public var step: Int
        public var title: String
        /// Where the list sits in the step's output, or nil when the author says (scripts, HTTP).
        public var path: String?
        /// The table the list's records belong to, when the items are records.
        public var tableID: String?
    }

    /// Steps before `stepIndex` (0-based) that a step can repeat over.
    public func repeatSources(for automation: AutomationModel, before stepIndex: Int) -> [RepeatSource] {
        automation.actions.prefix(stepIndex).enumerated().compactMap { i, action in
            let title = "Step \(i + 1): " + (action.label?.isEmpty == false ? action.label! : action.kind.displayName)
            if action.repeatFrom != nil {
                let records = action.kind == .createRecord || action.kind == .updateRecord
                return RepeatSource(step: i + 1, title: title, path: "items", tableID: records ? action.tableID : nil)
            }
            switch action.kind {
            case .findRecords: return RepeatSource(step: i + 1, title: title, path: "records", tableID: action.tableID)
            case .runScript, .httpRequest: return RepeatSource(step: i + 1, title: title, path: nil, tableID: nil)
            default: return nil
            }
        }
    }

    /// The table of the records a repeating step at `stepIndex` runs over, if its items are records.
    public func repeatItemTableID(for automation: AutomationModel, stepIndex: Int) -> String? {
        guard stepIndex < automation.actions.count, let from = automation.actions[stepIndex].repeatFrom,
              let source = repeatSources(for: automation, before: stepIndex).first(where: { $0.step == from }),
              source.path == repeatPath(for: automation.actions[stepIndex], in: automation)
        else { return nil }
        return source.tableID
    }

    /// The list a repeating step reads: its own path, else its source step's natural list.
    public func repeatPath(for action: AutomationAction, in automation: AutomationModel) -> String {
        if let path = action.repeatPath?.trimmingCharacters(in: .whitespaces), !path.isEmpty { return path }
        if let from = action.repeatFrom, from >= 1, from <= automation.actions.count, automation.actions[from - 1].repeatFrom != nil {
            return "items"
        }
        return "records"
    }
}

extension JSONValue {
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var obj) = self else { return self }
        obj[key] = value
        return .object(obj)
    }
}
