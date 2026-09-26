import AppKit
import RowHouseCore
import SwiftUI

/// An AI field's stored text, editable by hand, with a button that asks Claude to (re)generate it.
struct AITextEditor: View {
    let session: BaseSession
    let field: FieldModel
    @Binding var value: JSONValue
    var recordID: String?
    let style: EditorStyle
    var initialText: String?
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommitTextEditor(text: value.stringValue ?? "", initialText: initialText, minHeight: style == .popover ? 140 : 80, commitOnChange: style == .form) { text in
                let updated: JSONValue = text.isEmpty ? .null : .string(text)
                if updated != value { value = updated }
            }
            if let recordID, style != .form {
                HStack(spacing: 8) {
                    Button {
                        generate(recordID)
                    } label: {
                        Label(value.stringValue?.isEmpty == false ? "Regenerate" : "Generate", systemImage: "sparkles")
                    }
                    .disabled(generating)
                    if generating {
                        ProgressView().controlSize(.small)
                        Button("Stop") { task?.cancel() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    Spacer()
                    Text(AIModel.displayName(for: field.options.aiModel ?? AIConfiguration.defaultModel))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func generate(_ recordID: String) {
        // Save anything typed first, so the generated value isn't overwritten when the editor loses focus.
        NSApp.keyWindow?.makeFirstResponder(nil)
        generating = true
        error = nil
        let document = session.document
        let fieldID = field.id
        task = Task { @MainActor in
            defer { generating = false }
            do {
                let service = try AIConfiguration.makeService()
                try await document.generateAIValue(recordID: recordID, fieldID: fieldID, using: service)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
