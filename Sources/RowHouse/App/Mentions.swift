import Foundation
import RowHouseCore
import UserNotifications

/// Which collaborator is "you" on this Mac, per base. RowHouse has no accounts, so this is how
/// @mentions know whom to notify.
enum Me {
    private static let key = "RowHouse.me"

    static func personID(in baseID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[baseID]
    }

    static func set(_ personID: String?, in baseID: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[baseID] = personID
        UserDefaults.standard.set(map, forKey: key)
    }
}

enum MentionNotifier {
    static func post(title: String, subtitle: String, body: String, link: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["link": link]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
