import Foundation
import WebKit

/// A URL/DTO alone never grants access: services also need a live host capability.
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
    private var development: AskDevelopmentPreview?
    private var resourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var validate: (() throws -> Void)?
    private var timer: Timer?
    private var generation = UUID()
    var report: (String) -> Void = { _ in }
    private(set) var diagnostics: [String] = []

    func open(_ source: AskPreviewSource, enabled: Bool,
              validateAccess: ((AskArtifactRef) throws -> Void)? = nil,
              development: AskDevelopmentPreview? = nil,
              load: @escaping (AskArtifactRef) throws -> AskArtifactBundle) async throws -> WKWebView {
        try Task.checkCancellation()
        close()
        let ticket = generation
        guard enabled else { throw AskArtifactError.previewDisabled }
        let bundle: AskArtifactBundle?
        let paths: Set<String>, entry: String
        let validate: () throws -> Void
        switch source {
        case let .artifact(ref):
            let loaded = try load(ref)
            guard ref.mediaType == "text/html" else { throw AskArtifactError.unsupported }
            bundle = loaded; paths = Set(loaded.files.keys); entry = loaded.manifest.entry
            validate = {
                if let validateAccess {
                    try validateAccess(ref)
                } else {
                    _ = try load(ref)
                }
            }
        case let .developmentService(process, address):
            guard let development else { throw AskArtifactError.dynamicUnavailable }
            try development.validate(process: process, address: address)
            bundle = nil; paths = development.paths; entry = development.entry
            validate = { try development.validate(process: process, address: address) }
        }
        let policy = AskPreviewPolicy(token: UUID().uuidString.lowercased(), paths: paths)
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
        try validate()
        guard let rules else { throw AskArtifactError.unavailable }
        let configuration = try configuration(rules: rules)
        install(bundle: bundle, development: development, policy: policy, validate: validate)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false
        webView = view
        view.load(URLRequest(url: policy.url(entry)))
        beginMonitoring()
        return view
    }

    private func install(bundle: AskArtifactBundle?, development: AskDevelopmentPreview?,
                         policy: AskPreviewPolicy, validate: @escaping () throws -> Void) {
        self.bundle = bundle
        self.development = development
        development?.invalidated = { [weak self] in
            self?.record(L("ask.artifact.error.denied")); self?.close()
        }
        diagnostics = []
        self.policy = policy
        self.validate = validate
    }

    private func beginMonitoring() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func configuration(rules: WKContentRuleList) throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        try AskPreviewEnginePolicy.apply(to: configuration.preferences)
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = WKProcessPool()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.errorCollector, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: .defaultClient
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.consoleCollector, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        configuration.setURLSchemeHandler(self, forURLScheme: AskPreviewPolicy.scheme)
        return configuration
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

    private static let consoleCollector = """
    globalThis.typefluxPreviewConsole = [];
    globalThis.typefluxPreviewPageErrors = [];
    function recordPageError(message) {
      if (typefluxPreviewPageErrors.length < 8) typefluxPreviewPageErrors.push(String(message).slice(0,500));
    }
    addEventListener('error', e => recordPageError(e.message || 'A page resource failed to load'), true);
    addEventListener('unhandledrejection', e => recordPageError(e.reason || 'Unhandled page rejection'));
    for (const level of ['log', 'info', 'warn', 'error']) {
      const original = console[level].bind(console);
      console[level] = (...args) => {
        if (typefluxPreviewConsole.length < 64)
          typefluxPreviewConsole.push((level + ': ' + args.map(String).join(' ')).slice(0,1000));
        if (level === 'error') recordPageError(args.join(' '));
        original(...args);
      };
    }
    """

    private func record(_ message: String) {
        if diagnostics.count < 64 {
            diagnostics.append(String(message.prefix(1000)))
        }
        report(message)
    }

    func collectDiagnostics() async throws -> (errors: [String], console: [String]) {
        try validate?()
        guard let view = webView else { throw AskArtifactError.unavailable }
        let errors = try await view.evaluateJavaScript(
            "typefluxPreviewErrors.splice(0)",
            in: nil,
            in: .defaultClient
        ) as? [String] ?? []
        for error in errors {
            record(error)
        }
        let pageErrors = try await view.evaluateJavaScript(
            "(globalThis.typefluxPreviewPageErrors || []).slice(0,8).map(x => String(x).slice(0,500))"
        ) as? [String] ?? []
        for error in pageErrors where !diagnostics.contains(error) { record(error) }
        let console = try await view.evaluateJavaScript(
            "(globalThis.typefluxPreviewConsole || []).slice(0,64).map(x => String(x).slice(0,1000))"
        ) as? [String] ?? []
        try validate?()
        guard webView === view else { throw AskArtifactError.unavailable }
        return (diagnostics, console)
    }

    func check() {
        do { try validate?() } catch {
            record(error.localizedDescription)
            close()
            return
        }
        webView?.evaluateJavaScript(
            "typefluxPreviewErrors.splice(0).join('\\n')", in: nil, in: .defaultClient
        ) { [weak self] result in
            if case let .success(value) = result, let text = value as? String, !text.isEmpty {
                self?.record(text)
            }
        }
    }

    func close() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        resourceTasks.values.forEach { $0.cancel() }; resourceTasks = [:]
        development?.close(); development = nil
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
}

extension AskPreviewHost {
    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            try validate?()
            guard let policy, let url = urlSchemeTask.request.url,
                  urlSchemeTask.request.httpMethod == "GET" else { throw AskArtifactError.denied }
            let path = try policy.path(url)
            if let development {
                let id = ObjectIdentifier(urlSchemeTask)
                let ticket = generation
                resourceTasks[id] = Task { @MainActor [weak self] in
                    do {
                        let data = try await development.load(path)
                        try Task.checkCancellation()
                        guard let self, generation == ticket, resourceTasks[id] != nil else { return }
                        resourceTasks[id] = nil
                        respond(urlSchemeTask, url: url, path: path, data: data, policy: policy)
                    } catch {
                        guard let self, generation == ticket, resourceTasks[id] != nil else { return }
                        resourceTasks[id] = nil
                        record(error.localizedDescription); urlSchemeTask.didFailWithError(error)
                    }
                }
                return
            }
            guard let data = bundle?.files[path] else { throw AskArtifactError.unavailable }
            respond(urlSchemeTask, url: url, path: path, data: data, policy: policy)
        } catch {
            record(error.localizedDescription)
            urlSchemeTask.didFailWithError(error)
        }
    }

    private func respond(_ urlSchemeTask: any WKURLSchemeTask, url: URL, path: String,
                         data: Data, policy: AskPreviewPolicy) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": AskArtifactStore.mediaType(path) + "; charset=utf-8",
            "Content-Security-Policy": policy.contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer"
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        resourceTasks.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true && !navigationAction.shouldPerformDownload &&
            navigationAction.request.url.flatMap { try? policy?.path($0) } != nil
        if !allowed {
            record(L("ask.artifact.blocked"))
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        record(error.localizedDescription)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        record(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        record(L("ask.artifact.pageFailed"))
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
