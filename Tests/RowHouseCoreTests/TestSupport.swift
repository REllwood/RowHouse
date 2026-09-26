import Foundation
@testable import RowHouseCore

enum TestSupport {
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rowhouse-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh base package on disk plus a library entry for it.
    static func makePackage(name: String = "Test") throws -> LibraryEntry {
        let root = tempDirectory()
        let baseID = RowID.base()
        let url = root.appendingPathComponent("\(name).rowhouse", isDirectory: true)
        try BaseStorage.createPackage(at: url, baseID: baseID, name: name)
        return LibraryEntry(baseID: baseID, url: url, initialName: name, createdAt: Date())
    }

    @MainActor
    static func document(device: String = "devA") -> BaseDocument {
        BaseDocument(baseID: RowID.base(), deviceID: device, deviceName: "Mac \(device)")
    }
}

/// Records every side effect so automation tests can assert on them.
final class FakeServices: AutomationServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _notifications: [(String, String)] = []
    private var _requests: [URLRequest] = []
    private var _shortcuts: [(String, String)] = []
    private var _emails: [SentEmail] = []
    var responseStatus = 200
    var responseBody = Data("{\"ok\":true}".utf8)
    var emailError: Error?

    struct SentEmail: Equatable {
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String
        var body: String
    }

    var notifications: [(String, String)] { lock.withLock { _notifications } }
    var requests: [URLRequest] { lock.withLock { _requests } }
    var shortcuts: [(String, String)] { lock.withLock { _shortcuts } }
    var emails: [SentEmail] { lock.withLock { _emails } }

    func sendNotification(title: String, body: String) async throws {
        lock.withLock { _notifications.append((title, body)) }
    }

    func perform(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        lock.withLock { _requests.append(request) }
        return (responseStatus, ["Content-Type": "application/json"], responseBody)
    }

    func runShortcut(named name: String, input: String) async throws -> String {
        lock.withLock { _shortcuts.append((name, input)) }
        return "shortcut:\(input)"
    }

    func sendEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        if let emailError = lock.withLock({ emailError }) { throw emailError }
        lock.withLock { _emails.append(SentEmail(to: to, cc: cc, bcc: bcc, subject: subject, body: body)) }
    }
}
