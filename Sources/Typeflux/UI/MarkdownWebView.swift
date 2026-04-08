import AppKit
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let appearanceMode: AppearanceMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        update(webView: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        update(webView: webView, coordinator: context.coordinator)
    }

    private func update(webView: WKWebView, coordinator: Coordinator) {
        let normalizedMarkdown = normalizedMarkdownText(markdown)
        let html = wrappedHTML(for: normalizedMarkdown)
        guard coordinator.lastHTML != html else { return }
        coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func wrappedHTML(for markdown: String) -> String {
        let bodyHTML = MarkdownHTMLRenderer().render(markdown: markdown)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>\(stylesheet)</style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

    private var stylesheet: String {
        """
        :root {
          color-scheme: \(colorSchemeValue);
          --bg: \(colorHex(StudioTheme.surface));
          --text: \(colorHex(StudioTheme.textPrimary));
          --muted: \(colorHex(StudioTheme.textSecondary));
          --border: \(colorHex(StudioTheme.border));
          --accent: \(colorHex(StudioTheme.accent));
          --code-bg: \(colorHex(StudioTheme.surfaceMuted));
          --table-header-bg: \(colorHex(StudioTheme.surfaceMuted.opacity(0.92)));
        }
        * { box-sizing: border-box; }
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          font-size: \(StudioTheme.Typography.body)px;
          line-height: 1.65;
        }
        body {
          padding: 0;
          overflow-wrap: anywhere;
          word-break: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
          margin: 0 0 0.65em;
          line-height: 1.3;
          color: var(--text);
          font-weight: 700;
        }
        h1 { font-size: \(StudioTheme.Typography.sectionTitle + 4)px; }
        h2 { font-size: \(StudioTheme.Typography.sectionTitle + 1)px; }
        h3 { font-size: \(StudioTheme.Typography.subsectionTitle)px; }
        h4, h5, h6 { font-size: \(StudioTheme.Typography.cardTitle)px; }
        p {
          margin: 0 0 0.9em;
        }
        ul, ol {
          margin: 0 0 1em 1.4em;
          padding-left: 1.0em;
        }
        li {
          margin: 0.2em 0;
        }
        li > p {
          margin: 0.2em 0 0.45em;
        }
        blockquote {
          margin: 0 0 1em;
          padding: 0.1em 0 0.1em 0.9em;
          border-left: 3px solid var(--border);
          color: var(--muted);
        }
        pre {
          margin: 0 0 1em;
          padding: 0.8em 0.95em;
          background: var(--code-bg);
          border: 1px solid var(--border);
          border-radius: 10px;
          overflow-x: auto;
        }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
          font-size: \(StudioTheme.Typography.bodySmall)px;
          background: var(--code-bg);
          border-radius: 6px;
        }
        :not(pre) > code {
          padding: 0.15em 0.35em;
        }
        pre code {
          padding: 0;
          background: transparent;
          border-radius: 0;
        }
        table {
          display: block;
          width: max-content;
          min-width: 100%;
          max-width: 100%;
          margin: 0 0 1em;
          border-collapse: collapse;
          overflow-x: auto;
          border: 1px solid var(--border);
          border-radius: 10px;
        }
        thead {
          background: var(--table-header-bg);
        }
        th, td {
          padding: 0.6em 0.8em;
          border: 1px solid var(--border);
          vertical-align: top;
          text-align: left;
        }
        th {
          font-weight: 700;
        }
        td > p:last-child, th > p:last-child {
          margin-bottom: 0;
        }
        hr {
          border: 0;
          border-top: 1px solid var(--border);
          margin: 1.1em 0;
        }
        a {
          color: var(--accent);
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
        strong {
          font-weight: 700;
        }
        em {
          font-style: italic;
        }
        img {
          max-width: 100%;
          height: auto;
        }
        body > *:last-child {
          margin-bottom: 0;
        }
        """
    }

    private var colorSchemeValue: String {
        switch appearanceMode {
        case .dark:
            "dark"
        case .light:
            "light"
        case .system:
            "light dark"
        }
    }

    private func normalizedMarkdownText(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "    ")

        NetworkDebugLogger.logMessage(
            """
            [MarkdownWebView] Markdown passed to WebView:
            \(normalized)
            """,
        )

        return normalized
    }

    private func colorHex(_ color: Color) -> String {
        NSColor(color).resolvedHexString
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url
            {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

private extension NSColor {
    var resolvedHexString: String {
        let resolved = usingColorSpace(.deviceRGB) ?? self
        let red = Int(round(resolved.redComponent * 255))
        let green = Int(round(resolved.greenComponent * 255))
        let blue = Int(round(resolved.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
