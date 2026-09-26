import RowHouseCore
import SwiftUI

/// Settings › Claude AI: the Anthropic API key (kept in the Keychain), the default model for AI
/// fields, and a connection test.
struct AISettings: View {
    @AppStorage(AIConfiguration.defaultModelKey) private var defaultModel = AIModel.default.rawValue
    @State private var keyDraft = ""
    @State private var hasSavedKey = false
    @State private var message: StatusMessage?
    @State private var testing = false

    private struct StatusMessage {
        var text: String
        var isError: Bool
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    HStack {
                        SecureField(hasSavedKey ? "Saved in your Keychain" : "sk-ant-…", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                LabeledContent("Status") {
                    HStack {
                        Text(keyStatus).foregroundStyle(.secondary)
                        if hasSavedKey {
                            Button("Remove Key", role: .destructive, action: removeKey)
                        }
                    }
                }
                Picker("Default model", selection: $defaultModel) {
                    ForEach(AIModel.allCases) { Text($0.displayName).tag($0.rawValue) }
                    if AIModel(rawValue: defaultModel) == nil {
                        Text(defaultModel).tag(defaultModel)
                    }
                }
                HStack {
                    Button("Test Connection", action: testConnection)
                        .disabled(testing || (!hasSavedKey && AIConfiguration.environmentAPIKey == nil))
                    if testing { ProgressView().controlSize(.small) }
                    if let message {
                        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(message.isError ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("AI fields use Claude to write a value for each record from a prompt. Get a key at console.anthropic.com. When you generate a value, that record's prompt — including the values of the fields it mentions — is sent to Anthropic. The key never leaves this Mac's Keychain except to authenticate those requests. If no key is saved, RowHouse uses the ANTHROPIC_API_KEY environment variable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasSavedKey = AIConfiguration.hasSavedAPIKey }
    }

    private var keyStatus: String {
        if hasSavedKey { return "A key is saved in your Keychain" }
        if AIConfiguration.environmentAPIKey != nil { return "Using ANTHROPIC_API_KEY from the environment" }
        return "No key yet"
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try AIConfiguration.saveAPIKey(key)
            keyDraft = ""
            hasSavedKey = true
            message = StatusMessage(text: "Key saved", isError: false)
        } catch {
            message = StatusMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func removeKey() {
        do {
            try AIConfiguration.deleteAPIKey()
            hasSavedKey = false
            message = nil
        } catch {
            message = StatusMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func testConnection() {
        testing = true
        message = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let service = try AIConfiguration.makeService()
                _ = try await service.generateText(prompt: "Reply with the single word OK.", model: nil)
                message = StatusMessage(text: "Connected to \(AIModel.displayName(for: service.defaultModel))", isError: false)
            } catch {
                message = StatusMessage(text: error.localizedDescription, isError: true)
            }
        }
    }
}
