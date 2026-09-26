import RowHouseCore
import SwiftUI

/// The expanded record: every field with an editor, plus comments and history.
struct RecordDetailSheet: View {
    let session: BaseSession
    let expanded: ExpandedRecord
    var state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var recordID = ""
    @State private var confirmDelete = false

    private var document: BaseDocument { session.document }

    var body: some View {
        let record = document.record(recordID.isEmpty ? expanded.recordID : recordID)
        VStack(spacing: 0) {
            if let record {
                header(record)
                Divider()
                HStack(spacing: 0) {
                    ScrollView {
                        RecordFieldsForm(session: session, record: record, state: state)
                            .padding(24)
                            .id(record.id)
                    }
                    Divider()
                    RecordSidePanel(session: session, record: record)
                        .frame(width: 300)
                }
            } else {
                ContentUnavailableView("Record deleted", systemImage: "trash", description: Text("This record no longer exists."))
                Button("Close") { dismiss() }.padding()
            }
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 740)
        .onAppear { recordID = expanded.recordID }
        .confirmationDialog("Delete this record?", isPresented: $confirmDelete) {
            Button("Delete Record", role: .destructive) {
                let id = recordID
                dismiss()
                document.deleteRecords([id])
            }
        } message: {
            Text("You can undo this with ⌘Z.")
        }
    }

    private func header(_ record: RecordModel) -> some View {
        let siblings = expanded.siblings
        let index = siblings.firstIndex(of: record.id)
        return HStack(spacing: 12) {
            ControlGroup {
                Button {
                    if let i = index, i > 0 { recordID = siblings[i - 1] }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == nil || index == 0)
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button {
                    if let i = index, i + 1 < siblings.count { recordID = siblings[i + 1] }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == nil || index == siblings.count - 1)
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(document.primaryTitle(record))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(document.table(record.tableID)?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let i = index {
                Text("\(i + 1) of \(siblings.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Button("Duplicate Record") {
                    if let id = document.duplicateRecords([record.id]).first { recordID = id }
                }
                Button("Copy Record Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("rowhouse://record?base=\(document.baseID)&table=\(record.tableID)&record=\(record.id)", forType: .string)
                }
                Divider()
                Button("Delete Record…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct RecordFieldsForm: View {
    let session: BaseSession
    let record: RecordModel
    var state: WindowState

    var body: some View {
        let document = session.document
        let view = state.currentView(for: record.tableID, in: document)
        let fields = view.map { document.orderedFields(for: $0) } ?? document.fields(in: record.tableID)
        VStack(alignment: .leading, spacing: 20) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: field.type.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(field.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if field.type.isComputed {
                            Text(field.type.displayName.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        if !field.description.isEmpty {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help(field.description)
                        }
                    }
                    FieldValueEditor(session: session, field: field, value: document.binding(recordID: record.id, field: field), recordID: record.id, style: .detail)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
            Divider()
            HStack(spacing: 16) {
                Label("Created \(record.createdTime.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                let stamp = record.lastModifiedStamp
                Label("Edited \(stamp.date.formatted(.relative(presentation: .named))) on \(document.deviceName(for: stamp.node))", systemImage: "pencil")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RecordSidePanel: View {
    let session: BaseSession
    let record: RecordModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Comments").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            if tab == 0 {
                CommentsPanel(document: session.document, record: record)
            } else {
                HistoryPanel(session: session, record: record)
                    .id(record.id)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A record's revision history, read from every Mac's change logs (the last 14 days).
private struct HistoryPanel: View {
    let session: BaseSession
    let record: RecordModel
    @State private var entries: [RecordHistoryEntry]?

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath", description: Text("Changes from the last 14 days appear here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Image(systemName: symbol(entry.kind)).foregroundStyle(color(entry.kind)).font(.caption)
                                        Text(entry.author).font(.caption.weight(.semibold))
                                        Text(entry.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if entry.kind != .updated {
                                        Text(title(entry.kind)).font(.callout).foregroundStyle(.secondary)
                                    }
                                    ForEach(entry.changes, id: \.self) { change in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(change.fieldName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                if !change.old.isEmpty {
                                                    Text(change.old).strikethrough().foregroundStyle(.secondary).lineLimit(3)
                                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                                }
                                                Text(change.new.isEmpty ? "(cleared)" : change.new).lineLimit(3)
                                            }
                                            .font(.callout)
                                        }
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: record.lastModifiedStamp) { await load() }
    }

    private func load() async {
        let storage = session.storage
        let id = record.id
        storage.flush()
        let ops = await Task.detached(priority: .userInitiated) { storage.operations(forEntity: id) }.value
        entries = session.document.history(of: id, operations: ops)
    }

    private func symbol(_ kind: RecordHistoryEntry.Kind) -> String {
        switch kind {
        case .created: "plus.circle.fill"
        case .updated: "pencil.circle.fill"
        case .deleted: "trash.circle.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        }
    }

    private func color(_ kind: RecordHistoryEntry.Kind) -> Color {
        switch kind {
        case .created: .green
        case .updated: .accentColor
        case .deleted: .red
        case .restored: .orange
        }
    }

    private func title(_ kind: RecordHistoryEntry.Kind) -> String {
        switch kind {
        case .created: "Created this record"
        case .updated: "Edited"
        case .deleted: "Deleted this record"
        case .restored: "Restored this record"
        }
    }
}

private struct CommentsPanel: View {
    let document: BaseDocument
    let record: RecordModel
    @State private var draft = ""

    var body: some View {
        let comments = document.comments(for: record.id)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if comments.isEmpty {
                        Text("No comments yet. Notes you leave here sync to your other Macs.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(comment.authorName).font(.caption.weight(.semibold))
                                Text(comment.createdTime.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if comment.authorDeviceID == document.deviceID {
                                    Button {
                                        document.deleteComment(comment.id)
                                    } label: {
                                        Image(systemName: "trash").font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Text(comment.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Leave a comment", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func send() {
        document.addComment(to: record.id, text: draft)
        draft = ""
    }
}
