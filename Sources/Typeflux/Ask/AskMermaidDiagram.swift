import AppKit
import SwiftUI
import WebKit

enum AskMermaidResources {
    static var hostURL: URL? { Bundle.module.url(forResource: "mermaid-host", withExtension: "html") }
    static var resourceURL: URL? { Bundle.module.resourceURL }
}

private final class MermaidWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct AskMermaidDiagram: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 160
    @State private var showsSource = false
    @State private var expanded = false
    @State private var renderFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Mermaid")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showsSource ? L("ask.mermaid.showDiagram") : L("ask.mermaid.showSource")) {
                    showsSource.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .accessibilityIdentifier("ask.mermaid.toggleSource")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showsSource || renderFailed {
                if renderFailed {
                    Text(L("ask.mermaid.renderFailed"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }
                Text(source)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                AskMermaidWebView(source: source, dark: colorScheme == .dark,
                                  contentHeight: $contentHeight, renderFailed: $renderFailed)
                    .frame(height: expanded ? contentHeight : min(contentHeight, 600))
                    .clipped()
                    .accessibilityLabel(L("ask.mermaid.diagram"))
                if contentHeight > 600 {
                    Button(expanded ? L("ask.mermaid.collapse") : L("ask.mermaid.expand")) {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.leading, 14)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: AskMarkdownText.codeFill), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.15)))
    }
}

private struct AskMermaidWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    @Binding var contentHeight: CGFloat
    @Binding var renderFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, renderFailed: $renderFailed)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "mermaidHeight")
        let webView = MermaidWKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(source: source, dark: dark, webView: webView)
        if let page = AskMermaidResources.hostURL,
           let resources = AskMermaidResources.resourceURL {
            webView.loadFileURL(page, allowingReadAccessTo: resources)
        } else {
            DispatchQueue.main.async { renderFailed = true }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.renderFailed = $renderFailed
        context.coordinator.update(source: source, dark: dark, webView: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var contentHeight: Binding<CGFloat>
        var renderFailed: Binding<Bool>
        private var source = ""
        private var dark = false
        private var loaded = false
        private var lastRendered: (String, Bool)?

        init(contentHeight: Binding<CGFloat>, renderFailed: Binding<Bool>) {
            self.contentHeight = contentHeight
            self.renderFailed = renderFailed
        }

        func update(source: String, dark: Bool, webView: WKWebView) {
            self.source = source
            self.dark = dark
            if loaded { render(in: webView) }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            loaded = true
            render(in: webView)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            renderFailed.wrappedValue = true
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            renderFailed.wrappedValue = true
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = action.request.url == AskMermaidResources.hostURL
                && action.navigationType != .linkActivated
            decisionHandler(allowed ? .allow : .cancel)
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidHeight", let height = message.body as? NSNumber else { return }
            let bounded = min(max(CGFloat(truncating: height), 80), 8_000)
            if abs(contentHeight.wrappedValue - bounded) > 1 {
                DispatchQueue.main.async { self.contentHeight.wrappedValue = bounded }
            }
        }

        private func render(in webView: WKWebView) {
            guard lastRendered?.0 != source || lastRendered?.1 != dark else { return }
            lastRendered = (source, dark)
            let requestedSource = source
            let requestedDark = dark
            webView.callAsyncJavaScript(
                "return await window.renderDiagram(source, dark)",
                arguments: ["source": source, "dark": dark], in: nil, in: .page
            ) { [weak self] result in
                if case .failure = result {
                    DispatchQueue.main.async {
                        guard let self, self.source == requestedSource, self.dark == requestedDark else { return }
                        self.renderFailed.wrappedValue = true
                    }
                }
            }
        }
    }
}
