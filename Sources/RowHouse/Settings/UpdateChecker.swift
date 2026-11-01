import AppKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer version and offers to open the download page.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let autoCheckKey = "RowHouse.checkForUpdates"
    private static let lastCheckKey = "RowHouse.lastUpdateCheck"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    /// Where a check started, which decides how its result is shown.
    enum Trigger {
        /// The daily background check, which only speaks up when a newer version is out.
        case automatic
        /// A menu command, which reports every result in an alert.
        case menu
        /// The Settings button, which shows the result beside the button.
        case settings
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date
    private var notes = ""

    var availableVersion: String? {
        if case .available(let version, _) = status { return version }
        return nil
    }

    func checkAutomaticallyIfNeeded() {
        let enabled = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        guard enabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 86_400 { return }
        check(.automatic)
    }

    func check(_ trigger: Trigger) {
        guard status != .checking else { return }
        let previous = status
        status = .checking
        Task {
            do {
                let release = try await fetchLatest()
                record(checkedAt: Date())
                if Self.isNewer(release.version, than: AppInfo.version) {
                    notes = release.notes
                    status = .available(version: release.version, page: release.page)
                    if trigger != .settings { offerUpdate() }
                } else {
                    status = .upToDate
                    if trigger == .menu { show("You are up to date", "RowHouse \(AppInfo.version) is the latest version.") }
                }
            } catch {
                let message = (error as? CheckFailure)?.message ?? error.localizedDescription
                switch trigger {
                case .automatic:
                    // A failed background check should not replace what an earlier check found.
                    status = previous
                case .menu:
                    status = .failed(message)
                    show("Could not check for updates", message)
                case .settings:
                    status = .failed(message)
                }
            }
        }
    }

    /// Shows what is new in the available version and offers to open its download page.
    func offerUpdate() {
        guard case .available(let version, let page) = status else { return }
        let alert = NSAlert()
        alert.messageText = "RowHouse \(version) is available"
        let summary = Self.summary(of: notes)
        alert.informativeText = "You have \(AppInfo.version)." + (summary.isEmpty ? "" : "\n\n" + summary)
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Release notes as plain text for an alert: everything before the install instructions, with
    /// headings, bold and links reduced to their text and list items shown as bullets.
    static func summary(of notes: String, limit: Int = 700) -> String {
        let body = notes.components(separatedBy: "### Install").first ?? notes
        var lines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            var bullet = false
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line.removeFirst(2)
                bullet = true
            }
            if let plain = try? AttributedString(markdown: line) { line = String(plain.characters) }
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(bullet ? "• " + line : line)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return String(cut[..<(cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex)]) + "…"
    }

    private struct Release {
        var version: String
        var page: URL
        var notes: String
    }

    private struct CheckFailure: Error {
        var message: String
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: AppInfo.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RowHouse/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { throw CheckFailure(message: "GitHub did not return release information. Try again later.") }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page, notes: json["body"] as? String ?? "")
    }

    private func record(checkedAt date: Date) {
        lastChecked = date
        UserDefaults.standard.set(date, forKey: Self.lastCheckKey)
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
