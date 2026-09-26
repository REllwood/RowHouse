import AppKit
import SwiftUI

/// Explains the bundled MCP server and gives copyable setup snippets for common AI assistants.
struct AssistantSettings: View {
    private static let helperName = "rowhouse-mcp"

    private enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case claudeDesktop = "Claude Desktop"

        var id: String { rawValue }

        var instructions: String {
            switch self {
            case .claudeCode: "Run in Terminal:"
            case .codex: "Add to ~/.codex/config.toml:"
            case .claudeDesktop: "Add to claude_desktop_config.json (Claude › Settings › Developer › Edit Config), then restart Claude:"
            }
        }
    }

    @State private var client = Client.claudeCode

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Inside RowHouse.app the helper sits next to the app's executable in Contents/MacOS; when run
    /// with `swift run` it's built next to the RowHouse executable.
    private var helperURL: URL {
        if isBundled { return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Self.helperName)") }
        return (Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL).appendingPathComponent(Self.helperName)
    }

    private var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    var body: some View {
        Form {
            Section {
                Text("RowHouse includes an MCP server, so AI assistants such as Claude and Codex can work with your bases: look up and search records, add and update them, and create tables and fields.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Server") {
                    Text(helperURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !isBundled {
                    Label("RowHouse isn't running from its app bundle. Build the server with “swift build --product rowhouse-mcp”, or build the app with scripts/build-app.sh.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !helperExists {
                    Label("The server is missing from this copy of RowHouse. Reinstall RowHouse to restore it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("An assistant edits your bases the way another Mac does: its changes appear here within a second and sync to your other Macs through iCloud Drive, labelled with its name, such as “Claude Code (MCP)”. Record automations don't run for its edits. If you move RowHouse, copy the setup again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connect an assistant") {
                Picker("Assistant", selection: $client) {
                    ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SnippetRow(title: client.rawValue, caption: client.instructions, snippet: snippet(for: client))
                    .id(client)
            }

            Section {
                DisclosureGroup("What assistants can do") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.capabilities, id: \.self) { line in
                            Label(line, systemImage: "checkmark")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("If your bases are in iCloud Drive and the assistant can't see them, open System Settings › Privacy & Security › Files & Folders and allow the app that runs the assistant (Claude, Codex, Terminal or your editor) to access iCloud Drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static let capabilities = [
        "List bases, tables, fields and views (list_bases, get_base_schema)",
        "Read, filter, sort and search records (list_records, get_record, search_records)",
        "Create, update and delete records, up to 100 at a time",
        "Create bases from templates, add tables and fields, rename them and change field options",
        "Read and add record comments",
    ]

    private var quotedForJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(helperURL.path)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(helperURL.path)\""
    }

    private func snippet(for client: Client) -> String {
        switch client {
        case .claudeCode:
            return "claude mcp add rowhouse -- '\(helperURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        case .codex:
            // TOML basic strings take the same escapes as JSON (the escaped slash is turned off).
            return "[mcp_servers.rowhouse]\ncommand = \(quotedForJSON)"
        case .claudeDesktop:
            return """
                {
                  "mcpServers": {
                    "rowhouse": {
                      "command": \(quotedForJSON)
                    }
                  }
                }
                """
        }
    }
}

private struct SnippetRow: View {
    let title: String
    let caption: String
    let snippet: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .help("Copy the \(title) setup")
            }
            Text(snippet)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 2)
    }
}
