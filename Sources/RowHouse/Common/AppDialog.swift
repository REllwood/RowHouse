import AppKit
import Observation
import SwiftUI

/// What a dialog says and asks. Every alert, confirmation and prompt in RowHouse is one of these,
/// drawn by `AppDialogPresenter` in RowHouse's own style instead of as a system alert.
struct AppDialog {
    enum Tone {
        /// A question or prompt. Return presses the confirm button.
        case standard
        /// Deletes or replaces something. The confirm button is red, and Return does not press it.
        case destructive
        /// Something went wrong.
        case warning
    }

    struct Field {
        var placeholder: String
        var text: String
        /// The confirm button stays disabled while the trimmed text is empty.
        var required = true
    }

    var title: String
    var message: String?
    /// Longer text, such as release notes, shown in a scrolling box under the message.
    var detail: String?
    var symbol: String
    var tone: Tone = .standard
    /// The confirm button's title. A notice has none and shows only `cancelTitle`.
    var confirmTitle: String?
    var cancelTitle = "Cancel"
    /// A text field for prompts such as renaming. Its text is passed back when the dialog is confirmed.
    var field: Field?

    /// Information with a single button that dismisses it.
    static func notice(_ title: String, message: String? = nil, symbol: String = "info") -> AppDialog {
        AppDialog(title: title, message: message, symbol: symbol, cancelTitle: "OK")
    }

    /// A failure with a single button that dismisses it.
    static func failure(_ title: String, message: String? = nil) -> AppDialog {
        AppDialog(title: title, message: message, symbol: "exclamationmark", tone: .warning, cancelTitle: "OK")
    }

    static func confirm(_ title: String, message: String? = nil, confirmTitle: String, destructive: Bool = false, symbol: String? = nil) -> AppDialog {
        AppDialog(
            title: title,
            message: message,
            symbol: symbol ?? (destructive ? "trash" : "questionmark"),
            tone: destructive ? .destructive : .standard,
            confirmTitle: confirmTitle
        )
    }

    static func prompt(_ title: String, message: String? = nil, placeholder: String, text: String, confirmTitle: String, symbol: String = "pencil") -> AppDialog {
        AppDialog(title: title, message: message, symbol: symbol, confirmTitle: confirmTitle, field: Field(placeholder: placeholder, text: text))
    }
}

enum AppDialogResult: Equatable {
    /// Confirmed, with the text field's contents (empty when the dialog has no field).
    case confirmed(String)
    /// Cancelled with the cancel button, Escape, a click outside the dialog, or because its window went away.
    case cancelled
}

/// Shows `AppDialog`s. Each window shows one dialog at a time and queues the rest.
@MainActor
enum AppDialogPresenter {
    private static var showing: [ObjectIdentifier: AppDialogController] = [:]
    private static var waiting: [ObjectIdentifier: [AppDialogController]] = [:]

    /// Shows a dialog over a window: the given one, else the key or main window. With no window open it
    /// appears on its own in the middle of the screen.
    @discardableResult
    static func present(_ dialog: AppDialog, over window: NSWindow? = nil, completion: @escaping (AppDialogResult) -> Void = { _ in }) -> AppDialogController {
        let controller = AppDialogController(dialog: dialog, parent: resolve(window), completion: completion)
        if showing[controller.key] == nil {
            start(controller)
        } else {
            waiting[controller.key, default: []].append(controller)
        }
        return controller
    }

    /// Shows a dialog on its own and waits for an answer, for use before any window exists.
    static func runModal(_ dialog: AppDialog) -> AppDialogResult {
        var outcome = AppDialogResult.cancelled
        let controller = AppDialogController(dialog: dialog, parent: nil) { result in
            outcome = result
            NSApp.stopModal()
        }
        controller.runModal()
        return outcome
    }

    private static func resolve(_ window: NSWindow?) -> NSWindow? {
        var target = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        // A dialog asked for over another dialog waits its turn over the same window.
        if let panel = target as? AppDialogPanel { target = panel.controller?.parent }
        guard let target, target.isVisible else { return nil }
        return target
    }

    private static func start(_ controller: AppDialogController) {
        showing[controller.key] = controller
        controller.show()
    }

    fileprivate static func finished(_ controller: AppDialogController) {
        if showing[controller.key] === controller {
            showing[controller.key] = nil
            guard var queue = waiting[controller.key], !queue.isEmpty else { return }
            let next = queue.removeFirst()
            waiting[controller.key] = queue.isEmpty ? nil : queue
            start(next)
        } else {
            waiting[controller.key]?.removeAll { $0 === controller }
        }
    }
}

/// One dialog: a borderless panel over its window, so keyboard focus stays inside the dialog until it
/// closes.
@MainActor
final class AppDialogController {
    private enum Phase {
        /// Waiting for an earlier dialog over the same window to close.
        case queued
        /// Waiting for a sheet in front of the window to close, such as a sheet whose action failed.
        case waitingForSheet
        case visible(AppDialogPanel)
        /// Answered, cancelled, or cancelled because its window went away. Nothing happens after this.
        case finished
    }

    let dialog: AppDialog
    private(set) weak var parent: NSWindow?
    /// Whether the dialog belongs to a window. If that window has gone by the time it would show, the
    /// dialog is cancelled instead of appearing on its own.
    private let belongsToWindow: Bool
    fileprivate let key: ObjectIdentifier
    private var completion: ((AppDialogResult) -> Void)?
    private let model: AppDialogModel
    private var phase = Phase.queued
    private var observers: [NSObjectProtocol] = []

    fileprivate init(dialog: AppDialog, parent: NSWindow?, completion: @escaping (AppDialogResult) -> Void) {
        self.dialog = dialog
        self.parent = parent
        belongsToWindow = parent != nil
        self.completion = completion
        key = parent.map(ObjectIdentifier.init) ?? ObjectIdentifier(AppDialogPanel.self)
        model = AppDialogModel(text: dialog.field?.text ?? "")
    }

    private var panel: AppDialogPanel? {
        if case .visible(let panel) = phase { return panel }
        return nil
    }

    /// Closes the dialog as if it had been cancelled.
    func dismiss() {
        finish(.cancelled)
    }

    fileprivate func show() {
        switch phase {
        case .queued, .waitingForSheet: break
        case .visible, .finished: return
        }
        removeObservers()
        if belongsToWindow && parent?.isVisible != true {
            finish(.cancelled)
            return
        }
        if let parent {
            // In every phase from here on, the window closing or hiding cancels the dialog.
            observe(NSWindow.willCloseNotification, of: parent) { [weak self] in self?.finish(.cancelled) }
            observe(NSWindow.didChangeOcclusionStateNotification, of: parent) { [weak self] in
                if self?.parent?.isVisible == false { self?.finish(.cancelled) }
            }
            if parent.attachedSheet != nil {
                phase = .waitingForSheet
                observe(NSWindow.didEndSheetNotification, of: parent) { [weak self] in self?.show() }
                return
            }
        }
        let panel = makePanel()
        phase = .visible(panel)
        if let parent {
            panel.setFrame(parent.frame, display: false)
            parent.addChildWindow(panel, ordered: .above)
            observe(NSWindow.didResizeNotification, of: parent) { [weak self] in
                guard let self, let parent = self.parent else { return }
                self.panel?.setFrame(parent.frame, display: true)
            }
            // Clicking back into the window, or switching to it, puts the keyboard back in the dialog.
            observe(NSWindow.didBecomeKeyNotification, of: parent) { [weak self] in self?.panel?.makeKey() }
        } else {
            placeOnScreen(panel)
            NSApp.activate()
            // On its own, clicking anywhere else cancels it.
            observe(NSWindow.didResignKeyNotification, of: panel) { [weak self] in self?.finish(.cancelled) }
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.model.isVisible = true }
    }

    fileprivate func runModal() {
        let panel = makePanel()
        phase = .visible(panel)
        placeOnScreen(panel)
        NSApp.activate()
        model.isVisible = true
        NSApp.runModal(for: panel)
    }

    fileprivate func confirm() {
        if dialog.field?.required == true, model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        finish(.confirmed(model.text))
    }

    fileprivate func finish(_ result: AppDialogResult) {
        if case .finished = phase { return }
        let panel = self.panel
        phase = .finished
        removeObservers()
        if let panel {
            model.isVisible = false
            let parent = self.parent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
            }
            if let parent, parent.isVisible { parent.makeKey() }
        }
        AppDialogPresenter.finished(self)
        completion?(result)
        completion = nil
    }

    private func makePanel() -> AppDialogPanel {
        let panel = AppDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.controller = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: AppDialogView(
            dialog: dialog,
            model: model,
            standalone: parent == nil,
            confirm: { [weak self] in self?.confirm() },
            cancel: { [weak self] in self?.finish(.cancelled) }
        ))
        panel.setAccessibilitySubrole(.dialog)
        panel.setAccessibilityTitle(dialog.title)
        panel.setAccessibilityModal(true)
        return panel
    }

    private func placeOnScreen(_ panel: NSPanel) {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // A little above the middle, where alerts usually sit.
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.12)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func observe(_ name: Notification.Name, of object: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// The dialog's window. Borderless, so it can become key only because it says so.
final class AppDialogPanel: NSPanel {
    weak var controller: AppDialogController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        controller?.dismiss()
    }
}

@Observable
final class AppDialogModel {
    var text: String
    var isVisible = false

    init(text: String) {
        self.text = text
    }
}

private struct AppDialogView: View {
    let dialog: AppDialog
    @Bindable var model: AppDialogModel
    let standalone: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    /// The radius of a RowHouse window's corners, so the dimmed layer follows the window's shape.
    private static let windowCornerRadius: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if standalone {
                card
                    .padding(28)
            } else {
                GeometryReader { proxy in
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous)
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.42 : 0.2))
                            .opacity(model.isVisible ? 1 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: cancel)
                            .accessibilityHidden(true)
                        card
                            .padding(24)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isVisible)
    }

    private var tint: Color {
        switch dialog.tone {
        case .standard: Color.accentColor
        case .destructive: Color(nsColor: Theme.solid(.red))
        case .warning: Color(nsColor: Theme.solid(.orange))
        }
    }

    private var canConfirm: Bool {
        guard let field = dialog.field, field.required else { return true }
        return !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sized by its contents. When those are taller than the window, the text scrolls.
    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Text that does not fit the window scrolls, so very large text still works.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content.padding(.trailing, 6) }
            }
            if let field = dialog.field {
                TextField(field.placeholder, text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.panelBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(fieldFocused ? Color.accentColor.opacity(0.7) : Theme.hairline, lineWidth: fieldFocused ? 2 : 1)
                    )
                    .focused($fieldFocused)
                    .onSubmit { if canConfirm { confirm() } }
                    .accessibilityLabel(field.placeholder)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .trailing, spacing: 8) {
                    buttons
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 28, y: 12)
        .scaleEffect(model.isVisible || reduceMotion ? 1 : 0.96)
        .opacity(model.isVisible ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(dialog.title)
        .task {
            if dialog.field != nil { fieldFocused = true }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: dialog.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(tint.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(dialog.title)
                    .font(.system(.title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message = dialog.message {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = dialog.detail {
                    ScrollView {
                        Text(detail)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(maxHeight: 240)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.panelBackground))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let confirmTitle = dialog.confirmTitle {
            Button(dialog.cancelTitle, action: cancel)
                .buttonStyle(AppDialogButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: confirm)
                .buttonStyle(AppDialogButtonStyle(kind: dialog.tone == .destructive ? .destructive : .primary))
                // Return never presses a button that deletes something.
                .keyboardShortcut(dialog.tone == .destructive ? nil : .defaultAction)
                .disabled(!canConfirm)
        } else {
            Button(dialog.cancelTitle, action: cancel)
                .buttonStyle(AppDialogButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// RowHouse's dialog buttons: rounded like the rest of the app, filled with the accent colour (or red
/// for a destructive action), or tinted grey for Cancel.
struct AppDialogButtonStyle: ButtonStyle {
    enum Kind {
        case primary, destructive, secondary
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minWidth: 76, minHeight: 28)
                .foregroundStyle(kind == .secondary ? Color.primary : Color.white)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(fill))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline)
                    } else if configuration.isPressed || hovering {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(configuration.isPressed ? Color.black.opacity(0.16) : Color.white.opacity(0.1))
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            switch kind {
            case .primary: Color.accentColor
            case .destructive: Color(nsColor: Theme.solid(.red))
            case .secondary: Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.1 : 0.06)
            }
        }
    }
}

extension View {
    /// Shows a dialog over this view's window while `item` is set, and clears `item` when it closes.
    /// Confirming acts on the item the dialog was opened for, even if `item` changed meanwhile.
    func appDialog<Item>(item: Binding<Item?>, _ dialog: @escaping (Item) -> AppDialog, onConfirm: @escaping (Item, String) -> Void) -> some View {
        modifier(AppDialogModifier(isActive: item.wrappedValue != nil) {
            guard let presented = item.wrappedValue else { return nil }
            return (dialog(presented), { result in
                item.wrappedValue = nil
                if case .confirmed(let text) = result { onConfirm(presented, text) }
            })
        })
    }

    /// Shows a dialog over this view's window while `isPresented` is true, and sets it back to false when it closes.
    func appDialog(isPresented: Binding<Bool>, _ dialog: @escaping () -> AppDialog, onConfirm: @escaping (String) -> Void) -> some View {
        modifier(AppDialogModifier(isActive: isPresented.wrappedValue) {
            (dialog(), { result in
                isPresented.wrappedValue = false
                if case .confirmed(let text) = result { onConfirm(text) }
            })
        })
    }
}

private struct AppDialogModifier: ViewModifier {
    var isActive: Bool
    /// The dialog and what to do with its answer, made from the state at the moment it opens.
    var prepare: () -> (dialog: AppDialog, onResult: (AppDialogResult) -> Void)?
    @State private var host = AppDialogHost()

    func body(content: Content) -> some View {
        content
            .background(WindowReader(host: host))
            .onChange(of: isActive, initial: true) { _, active in
                if active, host.controller == nil, let prepared = prepare() {
                    host.controller = AppDialogPresenter.present(prepared.dialog, over: host.window) { result in
                        host.controller = nil
                        prepared.onResult(result)
                    }
                } else if !active {
                    host.controller?.dismiss()
                }
            }
    }
}

/// Remembers the window a view is in and the dialog it is showing.
private final class AppDialogHost {
    weak var window: NSWindow?
    var controller: AppDialogController?
}

private struct WindowReader: NSViewRepresentable {
    let host: AppDialogHost

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.host = host
        host.window = view.window
    }

    final class ReaderView: NSView {
        var host: AppDialogHost?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }
}
