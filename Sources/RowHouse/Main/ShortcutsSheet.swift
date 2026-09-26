import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌘/).
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        var id: String { action }
        let keys: String
        let action: String
    }

    private let sections: [(String, [Shortcut])] = [
        ("Grid", [
            Shortcut(keys: "↑ ↓ ← →", action: "Move between cells"),
            Shortcut(keys: "⌘ + arrow", action: "Jump to the first or last cell"),
            Shortcut(keys: "⇧ + arrow", action: "Extend the selection"),
            Shortcut(keys: "⇥  /  ⇧⇥", action: "Next or previous cell"),
            Shortcut(keys: "↩", action: "Edit the cell"),
            Shortcut(keys: "Type", action: "Replace the cell's value"),
            Shortcut(keys: "Space", action: "Expand the record"),
            Shortcut(keys: "⇧↩", action: "Add a record below"),
            Shortcut(keys: "⌫", action: "Clear cells or delete selected records"),
            Shortcut(keys: "⌘C  ⌘X  ⌘V", action: "Copy, cut and paste cells"),
            Shortcut(keys: "⌘D", action: "Fill down"),
            Shortcut(keys: "⌘A", action: "Select all records"),
            Shortcut(keys: "⎋", action: "Clear the selection"),
            Shortcut(keys: "1 – 9", action: "Set a rating"),
        ]),
        ("Records", [
            Shortcut(keys: "⌃⌘↑  ⌃⌘↓", action: "Previous or next record in an expanded record"),
            Shortcut(keys: "⌥⌘N", action: "Add a field"),
            Shortcut(keys: "⌘P", action: "Print the view"),
            Shortcut(keys: "⌘Z  ⇧⌘Z", action: "Undo and redo"),
        ]),
        ("Find", [
            Shortcut(keys: "⌘F", action: "Search records in this view"),
            Shortcut(keys: "⇧⌘F", action: "Search the whole base"),
            Shortcut(keys: "⌥⌘F", action: "Find and replace"),
        ]),
        ("Bases", [
            Shortcut(keys: "⇧⌘N", action: "New base"),
            Shortcut(keys: "⌥⌘T", action: "New table"),
            Shortcut(keys: "⇧⌘I", action: "Import a spreadsheet"),
            Shortcut(keys: "⇧⌘E", action: "Export the view as CSV"),
            Shortcut(keys: "⌥⌘V", action: "Show or hide the views list"),
            Shortcut(keys: "⌘/", action: "Show keyboard shortcuts"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 20) {
                    ForEach(sections, id: \.0) { title, shortcuts in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            ForEach(shortcuts) { s in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(s.action).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(s.keys).font(.body.monospaced())
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 700, height: 520)
    }
}
