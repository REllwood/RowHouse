import RowHouseCore
import SwiftUI

struct TemplateGrid: View {
    @Binding var selection: BaseTemplate

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach(BaseTemplate.allCases) { template in
                Button {
                    selection = template
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: template.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(template.color.swiftUI.gradient))
                        Text(template.name).font(.headline)
                        Text(template.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .cardStyle(selected: selection == template)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct NewBaseSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var state: WindowState
    @State private var template: BaseTemplate = .projectTracker
    @State private var name = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a base").font(.title2.bold())
            TextField("Base name", text: $name, prompt: Text(template == .blank ? "Untitled Base" : template.name))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Text("Start from").font(.headline)
            TemplateGrid(selection: $template)
            HStack {
                Label(app.library.isInICloudDrive ? "Saved to iCloud Drive › RowHouse" : "Saved on this Mac", systemImage: app.library.isInICloudDrive ? "icloud" : "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if creating { ProgressView().controlSize(.small) } else { Text("Create Base") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func create() {
        creating = true
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? (template == .blank ? "Untitled Base" : template.name) : name
        Task {
            if let id = await app.createBase(name: finalName, template: template), let table = app.mainTable(of: id) {
                state.destination = .table(base: id, table: table.id)
            }
            creating = false
            dismiss()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    var state: WindowState
    @State private var template: BaseTemplate = .projectTracker
    @State private var creating = false

    private var storageMessage: String {
        if app.library.isInICloudDrive { return "Your bases are saved in iCloud Drive › RowHouse and sync to your other Macs." }
        if !Library.isICloudDriveAvailable { return "iCloud Drive is off, so bases are saved on this Mac. Turn it on to sync, then choose iCloud Drive in Settings." }
        return "Bases are saved in \(app.library.rootURL.path). You can change this in Settings."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    AppIconView(size: 88)
                    Text("Welcome to RowHouse").font(.largeTitle.bold())
                    Text("Spreadsheet-simple databases with views, formulas and automations — stored in your own iCloud Drive.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                .padding(.top, 40)
                TemplateGrid(selection: $template)
                    .frame(maxWidth: 820)
                HStack(spacing: 12) {
                    Button {
                        creating = true
                        Task {
                            let name = template == .blank ? "Untitled Base" : template.name
                            if let id = await app.createBase(name: name, template: template), let table = app.mainTable(of: id) {
                                state.destination = .table(base: id, table: table.id)
                            }
                            creating = false
                        }
                    } label: {
                        Text(creating ? "Creating…" : "Create \(template.name)")
                            .frame(minWidth: 180)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(creating)
                    Button("Import CSV…") { state.csvImportSheet = true }
                        .controlSize(.large)
                    Button("Import from Airtable…") { state.airtableImportSheet = true }
                        .controlSize(.large)
                }
                Label(storageMessage, systemImage: app.library.isInICloudDrive ? "icloud" : "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The app icon rendered from the bundle (falls back to a drawn glyph when running unbundled).
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
