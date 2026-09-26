import RowHouseCore
import SwiftUI

/// Settings › Webhooks: turns the local webhook server on and chooses its port.
struct WebhookSettings: View {
    @AppStorage(WebhookServer.enabledKey) private var enabled = false
    @AppStorage(WebhookServer.portKey) private var storedPort = Webhooks.defaultPort
    @State private var portText = ""
    private var server: WebhookServer { WebhookServer.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Receive webhooks on this Mac", isOn: $enabled)
                LabeledContent("Port") {
                    HStack {
                        TextField("", text: $portText, prompt: Text(String(Webhooks.defaultPort)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(parsedPort == nil || parsedPort == WebhookServer.port)
                    }
                }
                if !portText.trimmingCharacters(in: .whitespaces).isEmpty, parsedPort == nil {
                    Text("Choose a port from 1024 to 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("Status") { statusView }
            } footer: {
                Text("RowHouse listens on 127.0.0.1 only, so only apps on this Mac can call your webhooks. Each webhook automation has its own secret address: copy it from the automation's trigger. To receive webhooks from other computers, forward them to this Mac with a tunnelling tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(WebhookServer.port) }
    }

    @ViewBuilder
    private var statusView: some View {
        switch server.status {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case .running(let port):
            Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { server.restart() }
            }
        }
    }

    private var parsedPort: Int? {
        guard let n = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(n) else { return nil }
        return n
    }

    private func applyPort() {
        guard let port = parsedPort else { return }
        storedPort = port
        server.applySettings()
    }
}
