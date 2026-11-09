import AppKit
import RowHouseCore
import SwiftUI
import UserNotifications

@main
struct RowHouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before any scene exists: a second copy must quit before a window opens a base.
        InstanceLock.claimOrQuit()
    }

    var body: some Scene {
        WindowGroup("RowHouse", id: "main") {
            MainWindow()
                .environment(AppModel.shared)
                .frame(minWidth: 900, minHeight: 560)
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1380, height: 860)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        UpdateChecker.shared.checkAutomaticallyIfNeeded()
        MainActor.assumeIsolated { StatusItemController.shared.start() }
        MainActor.assumeIsolated { WebhookServer.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running so automations keep firing; the menu bar item reopens the window.
        !UserDefaults.standard.bool(forKey: "RowHouse.showMenuBarExtra") && UserDefaults.standard.object(forKey: "RowHouse.showMenuBarExtra") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.closeAll()
            InstanceLock.release()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            if AppModel.shared.library.lastError != nil { AppModel.shared.library.refresh() }
            AppModel.shared.pollAll()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking a mention notification opens the record.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String,
              let url = URL(string: link), url.scheme == "rowhouse" || url.scheme == AppInfo.urlScheme else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

/// The menu bar item that keeps RowHouse reachable while it runs automations with no window open.
/// Built with AppKit because SwiftUI's MenuBarExtra rebuilds the main menu in a loop alongside
/// focused-value driven commands.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    static let defaultsKey = "RowHouse.showMenuBarExtra"
    private var item: NSStatusItem?
    var openMainWindow: (() -> Void)?

    func start() {
        update()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StatusItemController.shared.update() }
        }
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    private func update() {
        if enabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.topleft.filled", accessibilityDescription: "RowHouse")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !enabled, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionMenuItem("Open RowHouse", image: nil) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                self?.openMainWindow?()
            }
        })
        menu.addItem(.separator())
        let app = AppModel.shared
        let running = app.engines.values.reduce(0) { $0 + $1.activeRuns }
        let header = NSMenuItem(title: running > 0 ? "Running \(running) automation\(running == 1 ? "" : "s")…" : "Automations", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for session in app.orderedSessions {
            let count = session.document.automations.filter(\.enabled).count
            let row = NSMenuItem(title: "\(session.document.info.name) — \(count) on", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Check for Updates…", image: nil) {
            NSApp.activate(ignoringOtherApps: true)
            UpdateChecker.shared.check(.menu)
        })
        menu.addItem(ActionMenuItem("Settings…", image: nil) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        let quit = ActionMenuItem("Quit RowHouse", image: nil) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }
}
