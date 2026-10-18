import AppKit
import WebKit

/// One page of the embedded browser. The web view lives here rather than in a
/// SwiftUI view, so switching conversations or hiding the panel never reloads it.
@MainActor
final class AskBrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    enum Owner: Equatable {
        case user
        /// Opened by the AI in this conversation. The AI may also use the user's
        /// tabs; ownership only decides which tabs it may close.
        case agent(conversationId: String)
    }

    let id = UUID()
    /// Short, stable number the AI uses to name the tab.
    let number: Int
    let webView: WKWebView
    let isPrivate: Bool
    var owner: Owner
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Why the last navigation was refused (download, unsupported link), for the panel.
    @Published var notice: String?
    /// Bumped on every committed main-frame navigation; observations and approvals
    /// bound to an older generation are stale.
    private(set) var generation = 0
    /// Opens `window.open` and `target=_blank` pages as new tabs.
    var openPopup: ((WKWebViewConfiguration) -> WKWebView?)?
    private var observations: [NSKeyValueObservation] = []

    init(number: Int, configuration: WKWebViewConfiguration, isPrivate: Bool, owner: Owner) {
        self.number = number
        self.isPrivate = isPrivate
        self.owner = owner
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = false }
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            }
        ]
    }

    var host: String? { url?.host?.lowercased() }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return host ?? L("ask.web.newTab")
    }

    func load(_ url: URL) {
        notice = nil
        webView.load(URLRequest(url: url))
    }

    func close() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Releases the page's WebContent process instead of waiting for deallocation.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Waits until the current navigation finishes, or `timeout` passes. A page
    /// that keeps loading resources is still usable; this never throws on timeout.
    func waitForLoad(timeout: Duration = .seconds(10)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // Give a just-requested navigation a moment to start.
        try await Task.sleep(for: .milliseconds(150))
        while webView.isLoading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Navigation policy

    static func allowsNavigation(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data"].contains(scheme)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if Self.allowsNavigation(to: url) {
            // Top-level data: URLs are a phishing vector; frames may still use them.
            if url?.scheme?.lowercased() == "data", navigationAction.targetFrame?.isMainFrame != false {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        // mailto:, app links and the like open outside only when the user clicked them.
        if navigationAction.navigationType == .linkActivated, url?.scheme?.lowercased() != "file", let url {
            NSWorkspace.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame else {
            notice = L("ask.web.downloadUnsupported")
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        generation += 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        record(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        notice = L("ask.web.crashed")
        generation += 1
    }

    private func record(_ error: any Error) {
        let error = error as NSError
        // Cancelled loads and policy cancellations are not failures the user needs to see.
        guard error.code != NSURLErrorCancelled, error.domain != "WebKitErrorDomain" || error.code != 102 else { return }
        notice = error.localizedDescription
    }

    // MARK: - UI delegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit requires the returned view to use this configuration, which keeps
        // `window.opener` working for sign-in popups.
        guard Self.allowsNavigation(to: navigationAction.request.url) else { return nil }
        return openPopup?(configuration)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        // File uploads always go through the user's own choice in the system panel.
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}
