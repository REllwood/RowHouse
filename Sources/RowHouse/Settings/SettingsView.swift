import RowHouseCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "icloud") }
            AutomationSettings()
                .tabItem { Label("Automations", systemImage: "bolt") }
            AISettings().tabItem { Label("Claude AI", systemImage: "sparkle") }
            WebhookSettings().tabItem { Label("Webhooks", systemImage: "point.3.connected.trianglepath.dotted") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSwitch: StorageLocation?

    var body: some View {
        let location = app.library.location
        Form {
            Section {
                Picker("Save bases in", selection: Binding(get: { tag(location) }, set: { choose($0) })) {
                    Text("iCloud Drive").tag(0).disabled(!Library.isICloudDriveAvailable)
                    Text("On this Mac only").tag(1)
                    Text("Custom folder…").tag(2)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Folder") {
                    HStack {
                        Text(app.library.rootURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.library.rootURL]) }
                    }
                }
                if !Library.isICloudDriveAvailable {
                    Label("iCloud Drive is off. Turn it on in System Settings › Apple Account › iCloud to sync between Macs.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Each base is a folder of plain files. In iCloud Drive every Mac writes only its own change log, so edits from different Macs merge without conflicts — even when you're offline. Switching locations doesn't move existing bases; move the .rowhouse folders in Finder if you want to bring them along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("This Mac") {
                LabeledContent("Name", value: app.identity.name)
                LabeledContent("Device ID", value: app.identity.id)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Switch storage location?", isPresented: Binding(get: { confirmSwitch != nil }, set: { if !$0 { confirmSwitch = nil } })) {
            Button("Switch") {
                if let target = confirmSwitch { app.setStorageLocation(target) }
                confirmSwitch = nil
            }
        } message: {
            Text("RowHouse will show the bases in the new location. Your existing bases stay where they are.")
        }
    }

    private func tag(_ location: StorageLocation) -> Int {
        switch location {
        case .iCloudDrive: 0
        case .local: 1
        case .custom: 2
        }
    }

    private func choose(_ tag: Int) {
        switch tag {
        case 0: confirmSwitch = .iCloudDrive
        case 1: confirmSwitch = .local
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use Folder"
            if panel.runModal() == .OK, let url = panel.url { confirmSwitch = .custom(url) }
        }
    }
}

private struct AutomationSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("RowHouse.showMenuBarExtra") private var showMenuBarExtra = true
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications") {
                    HStack {
                        Text(statusText).foregroundStyle(.secondary)
                        if notificationStatus == .notDetermined {
                            Button("Allow") {
                                Task {
                                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                                    await refresh()
                                }
                            }
                        } else if notificationStatus == .denied {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                    }
                }
                Toggle("Keep running in the menu bar when the window is closed", isOn: $showMenuBarExtra)
                LaunchAtLoginToggle()
            } footer: {
                Text("Automations run while RowHouse is open. Keeping it in the menu bar and opening it at login means scheduled automations never miss a run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scheduled automations run on") {
                ForEach(app.orderedSessions) { session in
                    let doc = session.document
                    LabeledContent(doc.info.name) {
                        Picker("", selection: Binding(get: { doc.effectiveAutomationHost }, set: { doc.setAutomationHost($0) })) {
                            ForEach(hostChoices(doc), id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func hostChoices(_ doc: BaseDocument) -> [(String, String)] {
        var list = doc.devices.map { ($0.id, $0.id == doc.deviceID ? "\($0.name) (this Mac)" : $0.name) }
        if !list.contains(where: { $0.0 == doc.deviceID }) { list.insert((doc.deviceID, "\(doc.deviceName) (this Mac)"), at: 0) }
        if !list.contains(where: { $0.0 == doc.effectiveAutomationHost }) { list.append((doc.effectiveAutomationHost, "Another Mac")) }
        return list
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Turned off"
        default: "Not set up"
        }
    }

    private func refresh() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open RowHouse at login", isOn: Binding(get: { enabled }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    enabled = on
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(UpdateChecker.autoCheckKey) private var autoCheck = true

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheck)
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                Button("Check Now") { UpdateChecker.shared.check(userInitiated: true) }
            }
            Section("About") {
                LabeledContent("Source code") {
                    Link("github.com/REllwood/RowHouse", destination: AppInfo.repository)
                }
                Text("RowHouse is free and open source under the MIT License. It never sends your data anywhere: bases live in your own iCloud Drive or on this Mac. The only network requests it makes on its own are the optional update check to GitHub and the requests your automations make.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
