import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and offers to open the download page.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let autoCheckKey = "RowHouse.checkForUpdates"
    private static let lastCheckKey = "RowHouse.lastUpdateCheck"
    private var checking = false

    func checkAutomaticallyIfNeeded() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true
        guard enabled else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            do {
                var request = URLRequest(url: AppInfo.releasesAPI, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("RowHouse/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    if userInitiated { show("Couldn't check for updates", "GitHub didn't return release information. Try again later.") }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isNewer(latest, than: AppInfo.version) {
                    let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage
                    offer(version: latest, notes: json["body"] as? String ?? "", page: page)
                } else if userInitiated {
                    show("You're up to date", "RowHouse \(AppInfo.version) is the latest version.")
                }
            } catch {
                if userInitiated { show("Couldn't check for updates", error.localizedDescription) }
            }
        }
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

    private func offer(version: String, notes: String, page: URL) {
        let alert = NSAlert()
        alert.messageText = "RowHouse \(version) is available"
        alert.informativeText = "You have \(AppInfo.version).\n\n" + String(notes.prefix(600))
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
