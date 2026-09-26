import Foundation

public enum TriggerKind: String, Codable, CaseIterable, Sendable {
    case recordCreated
    case recordUpdated
    case recordMatchesConditions
    case recordEntersView
    case formSubmitted
    case scheduled
    case buttonClicked
    case webhookReceived
    case manual

    public var displayName: String {
        switch self {
        case .recordCreated: "When a record is created"
        case .recordUpdated: "When a record is updated"
        case .recordMatchesConditions: "When a record matches conditions"
        case .recordEntersView: "When a record enters a view"
        case .formSubmitted: "When a form is submitted"
        case .scheduled: "At a scheduled time"
        case .buttonClicked: "When a button is clicked"
        case .webhookReceived: "When a webhook is received"
        case .manual: "When run manually"
        }
    }

    public var symbolName: String {
        switch self {
        case .recordCreated: "plus.rectangle.on.rectangle"
        case .recordUpdated: "pencil.line"
        case .recordMatchesConditions: "line.3.horizontal.decrease.circle"
        case .recordEntersView: "tray.and.arrow.down"
        case .formSubmitted: "list.bullet.rectangle"
        case .scheduled: "clock"
        case .buttonClicked: "cursorarrow.click"
        case .webhookReceived: "point.3.connected.trianglepath.dotted"
        case .manual: "play.circle"
        }
    }

    /// Whether the trigger provides a record to later steps.
    public var providesRecord: Bool {
        switch self {
        case .scheduled, .manual, .webhookReceived: false
        default: true
        }
    }
}

public enum ScheduleFrequency: String, Codable, CaseIterable, Sendable {
    case minutes, hourly, daily, weekly, monthly

    public var displayName: String {
        switch self {
        case .minutes: "Every few minutes"
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        }
    }
}

public struct Schedule: Codable, Hashable, Sendable {
    public var frequency: ScheduleFrequency
    /// For `.minutes`: interval in minutes (min 5). For `.hourly`/`.daily`: every N hours/days.
    public var interval: Int
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar weekday numbering).
    public var weekday: Int
    public var dayOfMonth: Int

    public init(frequency: ScheduleFrequency = .daily, interval: Int = 1, hour: Int = 9, minute: Int = 0, weekday: Int = 2, dayOfMonth: Int = 1) {
        self.frequency = frequency
        self.interval = interval
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
    }

    /// The first fire date strictly after `date`.
    public func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date {
        switch frequency {
        case .minutes:
            return date.addingTimeInterval(Double(max(5, interval)) * 60)
        case .hourly:
            var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            comps.minute = minute
            var candidate = calendar.date(from: comps) ?? date
            while candidate <= date {
                candidate = calendar.date(byAdding: .hour, value: max(1, interval), to: candidate) ?? date.addingTimeInterval(3600)
            }
            return candidate
        case .daily:
            var candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
            while candidate <= date {
                candidate = calendar.date(byAdding: .day, value: max(1, interval), to: candidate) ?? date.addingTimeInterval(86400)
            }
            return candidate
        case .weekly:
            let comps = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 86400)
        case .monthly:
            let comps = DateComponents(day: min(max(1, dayOfMonth), 28), hour: hour, minute: minute, second: 0)
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) ?? date.addingTimeInterval(30 * 86400)
        }
    }

    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .minutes: return "Every \(max(5, interval)) minutes"
        case .hourly: return interval <= 1 ? "Every hour at :\(String(format: "%02d", minute))" : "Every \(interval) hours at :\(String(format: "%02d", minute))"
        case .daily: return interval <= 1 ? "Every day at \(time)" : "Every \(interval) days at \(time)"
        case .weekly:
            let names = Calendar(identifier: .gregorian).weekdaySymbols
            let name = names[(max(1, min(7, weekday)) - 1)]
            return "Every \(name) at \(time)"
        case .monthly: return "Monthly on day \(dayOfMonth) at \(time)"
        }
    }
}

public struct AutomationTrigger: Codable, Hashable, Sendable {
    public var kind: TriggerKind
    public var tableID: String?
    /// recordUpdated: only fire when one of these fields changes (empty = any field).
    public var watchedFieldIDs: [String]?
    /// recordMatchesConditions: fire when a record starts matching this filter.
    public var filter: FilterGroup?
    /// formSubmitted: the form view. recordEntersView: the view whose filter records enter.
    public var viewID: String?
    public var schedule: Schedule?
    /// webhookReceived: the secret that must appear in the webhook URL.
    public var webhookToken: String?

    public init(kind: TriggerKind, tableID: String? = nil) {
        self.kind = kind
        self.tableID = tableID
        if kind == .webhookReceived { webhookToken = Webhooks.makeToken() }
    }
}

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case createRecord
    case updateRecord
    case deleteRecord
    case findRecords
    case sendNotification
    case httpRequest
    case runScript
    case runShortcut
    case sendEmail
    case generateText

    public var displayName: String {
        switch self {
        case .createRecord: "Create record"
        case .updateRecord: "Update record"
        case .deleteRecord: "Delete record"
        case .findRecords: "Find records"
        case .sendNotification: "Send Mac notification"
        case .httpRequest: "Send HTTP request"
        case .runScript: "Run JavaScript"
        case .runShortcut: "Run Shortcut"
        case .sendEmail: "Send email"
        case .generateText: "Generate text with AI"
        }
    }

    public var symbolName: String {
        switch self {
        case .createRecord: "plus.square"
        case .updateRecord: "square.and.pencil"
        case .deleteRecord: "trash"
        case .findRecords: "magnifyingglass"
        case .sendNotification: "bell.badge"
        case .httpRequest: "network"
        case .runScript: "curlybraces"
        case .runShortcut: "square.stack.3d.up"
        case .sendEmail: "envelope"
        case .generateText: "sparkles"
        }
    }
}

public struct AutomationAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ActionKind
    /// Optional per-step label shown in the editor and run history.
    public var label: String?
    /// Only run this step when the trigger record (or, when repeating over records, the current
    /// item's record) matches these conditions.
    public var condition: FilterGroup?

    // Repeat for each
    /// 1-based number of an earlier step whose output list this step runs once per item of.
    public var repeatFrom: Int?
    /// Path of the list inside that step's output (defaults to "records", or "items" when that step
    /// repeats too).
    public var repeatPath: String?

    // Records
    public var tableID: String?
    /// Template resolving to a record id; defaults to the trigger record, or the item when repeating.
    public var recordIDTemplate: String?
    /// Field id → value template.
    public var fieldValues: [String: String]?
    public var filter: FilterGroup?
    public var limit: Int?

    // Notification
    public var title: String?
    public var body: String?

    // HTTP
    public var url: String?
    public var method: String?
    public var headers: [String: String]?

    // Script / Shortcut
    public var script: String?
    /// Named inputs made available to scripts through `input.config()`.
    public var inputs: [String: String]?
    public var shortcutName: String?

    // Email (comma-separated, templated recipients; the message text is `body`)
    public var to: String?
    public var cc: String?
    public var bcc: String?
    public var subject: String?

    // AI (templated prompt; nil model means the default chosen in Settings)
    public var prompt: String?
    public var aiModel: String?

    public init(id: String = RowID.action(), kind: ActionKind) {
        self.id = id
        self.kind = kind
    }
}

public struct AutomationModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var actions: [AutomationAction]
    public var order: Double
}

public enum RunStatus: String, Codable, Sendable {
    case running, succeeded, failed, skipped
}

public struct StepResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var status: RunStatus
    public var message: String
    public var logs: [String]

    public init(id: String, name: String, status: RunStatus, message: String = "", logs: [String] = []) {
        self.id = id
        self.name = name
        self.status = status
        self.message = message
        self.logs = logs
    }
}

public struct AutomationRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var automationID: String
    public var automationName: String
    public var deviceID: String
    public var deviceName: String
    public var trigger: String
    public var recordID: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var steps: [StepResult]

    public init(id: String = RowID.run(), automationID: String, automationName: String, deviceID: String, deviceName: String, trigger: String, recordID: String?, startedAt: Date = Date()) {
        self.id = id
        self.automationID = automationID
        self.automationName = automationName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.trigger = trigger
        self.recordID = recordID
        self.startedAt = startedAt
        self.status = .running
        self.steps = []
    }
}
