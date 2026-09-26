import AppKit
import RowHouseCore
import SwiftUI

/// Long text with Markdown formatting: a toolbar that wraps the selection in Markdown, a plain-text
/// editor, and a rendered preview. Commits like `CommitTextEditor`: on losing focus or disappearing.
struct RichTextEditor: View {
    let text: String
    var initialText: String?
    var minHeight: CGFloat = 90
    var commitOnChange = false
    var startsInPreview = false
    let commit: (String) -> Void

    enum Mode: Hashable { case write, preview }

    @State private var draft = ""
    @State private var loaded = false
    @State private var mode: Mode = .write
    @StateObject private var controller = MarkdownEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Self.buttons, id: \.format) { item in
                    Button {
                        controller.apply(item.format)
                    } label: {
                        Image(systemName: item.symbol).frame(width: 18, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(item.help)
                    .disabled(mode == .preview)
                }
                Spacer(minLength: 8)
                Picker("", selection: $mode) {
                    Text("Write").tag(Mode.write)
                    Text("Preview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            Group {
                if mode == .write {
                    MarkdownTextView(text: $draft, controller: controller) { commit(draft) }
                } else {
                    ScrollView {
                        RichTextPreview(markdown: draft)
                            .padding(8)
                    }
                }
            }
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(controller.isEditing ? 0.25 : 0.1)))
        }
        .onChange(of: draft) { _, new in
            if commitOnChange && loaded { commit(new) }
        }
        .onChange(of: text) { _, new in
            if !controller.isEditing { draft = new }
        }
        .onChange(of: mode) { _, new in
            if new == .preview, draft != text { commit(draft) }
        }
        .onAppear {
            guard !loaded else { return }
            draft = initialText.map { text + $0 } ?? text
            mode = startsInPreview && initialText == nil && !text.isEmpty ? .preview : .write
            loaded = true
            if initialText != nil { controller.focus() }
        }
        .onDisappear {
            if draft != text { commit(draft) }
        }
    }

    private struct ToolbarButton {
        var format: MarkdownFormat
        var symbol: String
        var help: String
    }

    private static let buttons: [ToolbarButton] = [
        ToolbarButton(format: .bold, symbol: "bold", help: "Bold"),
        ToolbarButton(format: .italic, symbol: "italic", help: "Italic"),
        ToolbarButton(format: .strikethrough, symbol: "strikethrough", help: "Strikethrough"),
        ToolbarButton(format: .heading, symbol: "textformat.size", help: "Heading"),
        ToolbarButton(format: .bulletList, symbol: "list.bullet", help: "Bulleted list"),
        ToolbarButton(format: .numberedList, symbol: "list.number", help: "Numbered list"),
        ToolbarButton(format: .link, symbol: "link", help: "Link"),
        ToolbarButton(format: .code, symbol: "chevron.left.forwardslash.chevron.right", help: "Code"),
    ]
}

/// Lets the toolbar reach the text view that SwiftUI manages.
@MainActor
final class MarkdownEditorController: ObservableObject {
    weak var textView: NSTextView?
    @Published var isEditing = false

    func apply(_ format: MarkdownFormat) {
        guard let textView else { return }
        let edit = RichText.edit(format, text: textView.string, selection: textView.selectedRange())
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textView.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        textView.window?.makeFirstResponder(textView)
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }
}

/// A plain-text NSTextView (SwiftUI's TextEditor doesn't expose its selection on macOS 14).
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    let endEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        textView.delegate = context.coordinator
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.controller.isEditing = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.controller.isEditing = false
            parent.endEditing()
        }
    }
}

/// Renders stored Markdown: headings, lists, quotes and code blocks line by line, with inline styles
/// from `AttributedString(markdown:)`. Anything that doesn't parse is shown as plain text.
struct RichTextPreview: View {
    let markdown: String

    var body: some View {
        let blocks = RichText.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 4) {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("—").foregroundStyle(.tertiary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ block: RichText.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title3.weight(.bold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .padding(.top, 2)
        case .bullet(let indent, let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                } else {
                    Text("•")
                }
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit()
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
        case .rule:
            Divider()
        case .blank:
            Color.clear.frame(height: 4)
        }
    }

    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Inline Markdown as an attributed string. Links are kept only for web and email addresses, so
    /// synced text can't point a click at a local file or app.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in attributed.runs {
            if let url = run.link, !allowedLinkSchemes.contains(url.scheme?.lowercased() ?? "") {
                attributed[run.range].link = nil
            }
        }
        return attributed
    }
}
