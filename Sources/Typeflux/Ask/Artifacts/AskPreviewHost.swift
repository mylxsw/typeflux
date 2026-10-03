import Foundation
import WebKit

/// D04 may supply a separately validated runtime lease here. A URL alone never
/// grants access to a development service; dynamic loading remains fail-closed.
enum AskPreviewSource {
    case artifact(AskArtifactRef)
    case developmentService(process: AskProcessRef, address: URL)
}

struct AskPreviewPolicy {
    static let scheme = "typeflux-artifact"
    let token: String
    let paths: Set<String>

    func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        components.path = "/" + path
        return components.url!
    }

    func path(_ url: URL) throws -> String {
        guard url.scheme == Self.scheme, url.host == token, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/") else { throw AskArtifactError.denied }
        let path = String(decoded.dropFirst())
        try AskArtifactStore.validatePath(path)
        guard paths.contains(path) else { throw AskArtifactError.unavailable }
        return path
    }

    var contentSecurityPolicy: String {
        let origin = Self.scheme + "://" + token
        return "sandbox allow-scripts; default-src 'none'; " +
            "script-src 'unsafe-inline' \(origin); style-src 'unsafe-inline' \(origin); img-src \(origin); " +
            "connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; " +
            "object-src 'none'; base-uri 'none'; form-action 'none'; media-src 'none'; font-src 'none'"
    }

    var contentRules: String {
        get throws {
            // Block networking independently of page CSP. Only this preview's random
            // origin can be handled, and the handler serves the manifest's bytes only.
            let rules: [[String: Any]] = [
                ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
                ["trigger": ["url-filter": "^" + Self.scheme + "://" + token + "/"],
                 "action": ["type": "ignore-previous-rules"]]
            ]
            guard let json = try String(data: JSONSerialization.data(withJSONObject: rules), encoding: .utf8) else {
                throw AskArtifactError.invalid
            }
            return json
        }
    }
}

/// A fresh, nonpersistent WebKit page, with no message handlers, file URL grants,
/// native actions, popups, downloads or external navigation. Never reused for app UI.
@MainActor final class AskPreviewHost: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var policy: AskPreviewPolicy?
    private var bundle: AskArtifactBundle?
    private var validate: (() throws -> Void)?
    private var timer: Timer?
    private var generation = UUID()
    var report: (String) -> Void = { _ in }

    func open(_ source: AskPreviewSource, enabled: Bool,
              validateAccess: ((AskArtifactRef) throws -> Void)? = nil,
              load: @escaping (AskArtifactRef) throws -> AskArtifactBundle) async throws -> WKWebView {
        try Task.checkCancellation()
        close()
        let ticket = generation
        guard enabled else { throw AskArtifactError.previewDisabled }
        guard case let .artifact(ref) = source else { throw AskArtifactError.dynamicUnavailable }
        let bundle = try load(ref)
        guard ref.mediaType == "text/html" else { throw AskArtifactError.unsupported }
        let policy = AskPreviewPolicy(token: UUID().uuidString.lowercased(), paths: Set(bundle.files.keys))
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "TypefluxArtifact-" + policy.token, encodedContentRuleList: policy.contentRules
        )
        defer {
            WKContentRuleListStore.default()
                .removeContentRuleList(forIdentifier: "TypefluxArtifact-" + policy.token) { _ in }
        }
        try Task.checkCancellation()
        guard ticket == generation else { throw CancellationError() }
        // Rule compilation suspends: revalidate owner, expiry and grants before loading.
        let validate = { if let validateAccess { try validateAccess(ref) } else { _ = try load(ref) } }
        try validate()
        let configuration = WKWebViewConfiguration()
        try AskPreviewEnginePolicy.apply(to: configuration.preferences)
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = WKProcessPool()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        guard let rules else { throw AskArtifactError.unavailable }
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.errorCollector, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: .defaultClient
        ))
        configuration.setURLSchemeHandler(self, forURLScheme: AskPreviewPolicy.scheme)
        self.bundle = bundle
        self.policy = policy
        self.validate = validate
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false
        webView = view
        view.load(URLRequest(url: policy.url(bundle.manifest.entry)))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return view
    }

    private static let errorCollector = """
    globalThis.typefluxPreviewErrors = [];
    function record(e) {
      if (typefluxPreviewErrors.length < 8) typefluxPreviewErrors.push(String(e).slice(0, 500));
    }
    addEventListener('error', e => record(e.message || 'A page resource failed to load'), true);
    addEventListener('unhandledrejection', e => record(e.reason || 'Unhandled page rejection'));
    addEventListener('securitypolicyviolation', () => record('Preview blocked a prohibited resource or action'));
    """

    func check() {
        do { try validate?() } catch {
            report(error.localizedDescription)
            close()
            return
        }
        webView?.evaluateJavaScript(
            "typefluxPreviewErrors.splice(0).join('\\n')", in: nil, in: .defaultClient
        ) { [weak self] result in
            if case let .success(value) = result, let text = value as? String, !text.isEmpty {
                self?.report(text)
            }
        }
    }

    func close() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        // Detach the executable page when closing or revoking, rather than leaving
        // old scripts running behind an error message.
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView?.configuration.userContentController.removeAllUserScripts()
        webView = nil
        bundle = nil
        policy = nil
        validate = nil
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            try validate?()
            guard let policy, let bundle, let url = urlSchemeTask.request.url,
                  urlSchemeTask.request.httpMethod == "GET" else { throw AskArtifactError.denied }
            let path = try policy.path(url)
            guard let data = bundle.files[path] else { throw AskArtifactError.unavailable }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": AskArtifactStore.mediaType(path) + "; charset=utf-8",
                "Content-Security-Policy": policy.contentSecurityPolicy,
                "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer"
            ])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            report(error.localizedDescription)
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && !navigationAction.shouldPerformDownload &&
            navigationAction.request.url.flatMap { try? policy?.path($0) } != nil
        if !allowed {
            report(L("ask.artifact.blocked"))
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        report(error.localizedDescription)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        report(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        report(L("ask.artifact.pageFailed"))
        close()
    }

    func webView(_: WKWebView, runOpenPanelWith _: WKOpenPanelParameters,
                 initiatedByFrame _: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration,
                 for _: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame _: WKFrameInfo, completionHandler: @escaping () -> Void) {
        report(String(message.prefix(500)))
        completionHandler()
    }

    func webView(_: WKWebView, runJavaScriptConfirmPanelWithMessage _: String,
                 initiatedByFrame _: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_: WKWebView, runJavaScriptTextInputPanelWithPrompt _: String,
                 defaultText _: String?, initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    func webView(_: WKWebView, requestMediaCapturePermissionFor _: WKSecurityOrigin,
                 initiatedByFrame _: WKFrameInfo, type _: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}
