import AppKit
import WebKit

/// Prints generated HTML through the standard print panel (which also offers Save as PDF).
/// The HTML is laid out by an offscreen WKWebView so tables paginate like a browser print.
@MainActor
final class Printing: NSObject, WKNavigationDelegate {
    private static var active: Set<Printing> = []

    private let title: String
    private let parent: NSWindow?
    private let window: NSWindow
    private let webView: WKWebView

    static func print(html: String, title: String) {
        let job = Printing(title: title, parent: NSApp.keyWindow)
        active.insert(job)
        job.webView.loadHTMLString(html, baseURL: nil)
    }

    private init(title: String, parent: NSWindow?) {
        self.title = title
        self.parent = parent
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        if #available(macOS 13.3, *) { config.preferences.shouldPrintBackgrounds = true }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { run() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish() }
    }

    private func run() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let op = webView.printOperation(with: info)
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsScaling])
        op.view?.frame = webView.bounds
        window.orderBack(nil)
        op.runModal(for: parent ?? window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish()
    }

    private func finish() {
        window.orderOut(nil)
        Self.active.remove(self)
    }
}
