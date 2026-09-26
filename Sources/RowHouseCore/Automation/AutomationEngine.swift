import Foundation
import Observation

/// Side effects that leave the app. The app provides real implementations; tests provide fakes.
public protocol AutomationServices: Sendable {
    func sendNotification(title: String, body: String) async throws
    func perform(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data)
    func runShortcut(named name: String, input: String) async throws -> String
}

/// Runs a base's automations.
///
/// To make sure an automation runs exactly once even with several Macs sharing a base:
/// record triggers fire only on the Mac where the change was made (remote changes never fire), and
/// scheduled triggers fire only on the base's automation host.
@MainActor
@Observable
public final class AutomationEngine {
    public let session: BaseSession
    public var document: BaseDocument { session.document }
    public private(set) var activeRuns = 0

    @ObservationIgnored private let services: AutomationServices
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var matching: [String: Set<String>] = [:]
    @ObservationIgnored private var recentRuns: [String: [Date]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    public static let maxChainDepth = 5
    public static let maxRunsPerMinute = 60

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
        if changes.automationsChanged { rebuildMatchingCache() }
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
            case .recordMatchesConditions:
                guard let filter = trigger.filter else { continue }
                var current = matching[automation.id] ?? []
                for recordID in changes.deletedRecords.keys { current.remove(recordID) }
                let candidates = Array(changes.createdRecords.keys) + Array(changes.updatedRecords.keys)
                for recordID in candidates {
                    guard let record = document.record(recordID), record.tableID == tableID else { continue }
                    let nowMatches = document.matches(record, filter: filter)
                    let wasMatching = current.contains(recordID)
                    if nowMatches {
                        current.insert(recordID)
                        if !wasMatching && fire && automation.enabled {
                            start(automation, recordID: recordID, trigger: "Record matched conditions", depth: depth)
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

    private func rebuildMatchingCache() {
        var fresh: [String: Set<String>] = [:]
        for automation in document.automations where automation.trigger.kind == .recordMatchesConditions {
            guard let tableID = automation.trigger.tableID, let filter = automation.trigger.filter else { continue }
            // Keep what we already knew so edits to other automations don't re-arm this one.
            if let existing = matching[automation.id], existingFilterKey[automation.id] == filterKey(automation) {
                fresh[automation.id] = existing
                continue
            }
            fresh[automation.id] = Set(document.records(in: tableID).filter { document.matches($0, filter: filter) }.map(\.id))
            existingFilterKey[automation.id] = filterKey(automation)
        }
        matching = fresh
    }

    @ObservationIgnored private var existingFilterKey: [String: String] = [:]

    private func filterKey(_ a: AutomationModel) -> String {
        JSONValue(encoding: a.trigger).jsonString
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

    /// Runs an automation now (the editor's "Test" button). Uses `recordID` or the first record in the trigger table.
    @discardableResult
    public func runNow(_ automationID: String, recordID: String? = nil) async -> AutomationRun? {
        guard let automation = document.automation(automationID) else { return nil }
        var rid = recordID
        if rid == nil, automation.trigger.kind.providesRecord, let t = automation.trigger.tableID {
            rid = document.records(in: t).first?.id
        }
        return await execute(automation, recordID: rid, trigger: "Run manually", depth: 0)
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

    private func start(_ automation: AutomationModel, recordID: String?, trigger: String, depth: Int) {
        let now = Date()
        var times = (recentRuns[automation.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard times.count < Self.maxRunsPerMinute else {
            var run = AutomationRun(automationID: automation.id, automationName: automation.name, deviceID: document.deviceID, deviceName: document.deviceName, trigger: trigger, recordID: recordID)
            run.status = .skipped
            run.finishedAt = now
            run.steps = [StepResult(id: "limit", name: "Rate limit", status: .skipped, message: "Skipped: more than \(Self.maxRunsPerMinute) runs in one minute")]
            session.record(run: run)
            return
        }
        times.append(now)
        recentRuns[automation.id] = times
        Task { await execute(automation, recordID: recordID, trigger: trigger, depth: depth) }
    }

    private func execute(_ automation: AutomationModel, recordID: String?, trigger: String, depth: Int) async -> AutomationRun {
        var run = AutomationRun(automationID: automation.id, automationName: automation.name, deviceID: document.deviceID, deviceName: document.deviceName, trigger: trigger, recordID: recordID)
        activeRuns += 1
        defer { activeRuns -= 1 }
        session.record(run: run)

        var scope = baseScope(automation: automation, recordID: recordID)
        var stepsScope: [String: JSONValue] = [:]
        var failed = false
        for (index, action) in automation.actions.enumerated() {
            let name = action.label?.isEmpty == false ? action.label! : action.kind.displayName
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

    private func perform(_ action: AutomationAction, scope: JSONValue, depth: Int) async -> StepOutcome {
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
            let rid = render(action.recordIDTemplate?.isEmpty == false ? action.recordIDTemplate : "{{trigger.record.id}}").trimmingCharacters(in: .whitespaces)
            guard let record = document.record(rid), record.tableID == tableID else {
                return StepOutcome(ok: false, message: "Couldn't find record “\(rid)” in \(document.table(tableID)?.name ?? "the table")")
            }
            let values = renderedValues(action.fieldValues, tableID: tableID, scope: scope)
            document.updateRecord(rid, values: values, actionName: "Automation Update", origin: origin)
            return StepOutcome(ok: true, message: "Updated \(document.primaryTitle(recordID: rid))", output: recordScope(rid))

        case .deleteRecord:
            let rid = render(action.recordIDTemplate?.isEmpty == false ? action.recordIDTemplate : "{{trigger.record.id}}").trimmingCharacters(in: .whitespaces)
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

    func baseScope(automation: AutomationModel, recordID: String?) -> JSONValue {
        var trigger: [String: JSONValue] = ["type": .string(automation.trigger.kind.rawValue), "time": .string(DateCoding.iso8601String(Date()))]
        if let recordID { trigger["record"] = recordScope(recordID) }
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
        for (i, action) in automation.actions.prefix(stepIndex).enumerated() {
            let n = i + 1
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
}

extension JSONValue {
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var obj) = self else { return self }
        obj[key] = value
        return .object(obj)
    }
}
