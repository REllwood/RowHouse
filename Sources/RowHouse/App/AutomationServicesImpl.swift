import Foundation
import RowHouseCore
import UserNotifications

/// Real side effects for automations: macOS notifications, HTTP, the Shortcuts app and Mail.
struct SystemAutomationServices: AutomationServices {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func sendNotification(title: String, body: String) async throws {
        guard Bundle.main.bundleIdentifier != nil else { throw Failure(message: "Notifications need the app bundle") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let current = await center.notificationSettings()
        guard current.authorizationStatus == .authorized || current.authorizationStatus == .provisional else {
            throw Failure(message: "Notifications are turned off for RowHouse in System Settings › Notifications")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func perform(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        var req = request
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("RowHouse/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "Not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        return (http.statusCode, headers, data)
    }

    func runShortcut(named name: String, input: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rowhouse-shortcut-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let inputURL = dir.appendingPathComponent("input.txt")
            let outputURL = dir.appendingPathComponent("output")
            try Data(input.utf8).write(to: inputURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name, "--input-path", inputURL.path, "--output-path", outputURL.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw Failure(message: errText.isEmpty ? "Shortcut “\(name)” failed (exit \(process.terminationStatus))" : errText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let out = (try? Data(contentsOf: outputURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    func generateText(prompt: String, model: String?) async throws -> String {
        try await AIConfiguration.makeService().generateText(prompt: prompt, model: model)
    }

    func sendEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let source = MailScript.sendScript(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.appleScriptQueue.async {
                continuation.resume(with: Self.runMailScript(source))
            }
        }
    }

    /// NSAppleScript mustn't be used from two threads at once, so every script runs on this one serial
    /// queue. Keeping it off the main thread means launching Mail, or waiting for the user to answer the
    /// Automation permission prompt, never freezes the app.
    private static let appleScriptQueue = DispatchQueue(label: "com.rellwood.RowHouse.applescript", qos: .userInitiated)

    private static func runMailScript(_ source: String) -> Result<Void, Error> {
        guard let script = NSAppleScript(source: source) else { return .failure(Failure(message: "Couldn't prepare the email")) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let text = errorInfo[NSAppleScript.errorMessage] as? String ?? "Mail reported an error"
            switch number {
            case -1743:
                return .failure(Failure(message: "RowHouse isn't allowed to control Mail. Turn on Mail for RowHouse in System Settings › Privacy & Security › Automation."))
            case MailScript.noAccountErrorNumber:
                return .failure(Failure(message: "Mail has no email account set up. Add one in Mail › Settings › Accounts."))
            case -1712:
                return .failure(Failure(message: "Mail didn't respond in time. Open Mail and check that it isn't waiting for you."))
            case -600, -10810:
                return .failure(Failure(message: "Couldn't open Mail."))
            default:
                return .failure(Failure(message: text))
            }
        }
        guard result.booleanValue else { return .failure(Failure(message: "Mail couldn't send the message. Check your account in Mail.")) }
        return .success(())
    }

    /// Names of the user's Shortcuts, for the action editor's picker.
    static func shortcutNames() async -> [String] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
        }.value
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static let repository = URL(string: "https://github.com/REllwood/RowHouse")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/REllwood/RowHouse/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/REllwood/RowHouse/releases/latest")!
}
