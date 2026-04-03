import AppKit
import SwiftUI
import WebKit

final class AskAnswerWindowController: NSObject {
    fileprivate enum Metrics {
        static let windowWidth: CGFloat = 820
        static let windowHeight: CGFloat = 520
        static let minWindowWidth: CGFloat = 760
        static let minWindowHeight: CGFloat = 480
        static let outerHorizontalPadding: CGFloat = 14
        static let outerTopPadding: CGFloat = 8
        static let outerBottomPadding: CGFloat = 10
        static let sectionSpacing: CGFloat = 10
        static let headerButtonSize: CGFloat = 20
        static let questionIconWidth: CGFloat = 20
        static let contentCardCornerRadius: CGFloat = 12
        static let answerHeaderHorizontalPadding: CGFloat = 12
        static let answerHeaderVerticalPadding: CGFloat = 8
        static let answerContentHorizontalPadding: CGFloat = 14
        static let answerContentVerticalPadding: CGFloat = 12
        static let promptCardPadding: CGFloat = 8
        static let selectedTextMaxLines: Int = 4
    }

    fileprivate final class Model: ObservableObject {
        @Published var question: String = ""
        @Published var selectedText: String = ""
        @Published var answerMarkdown: String = ""
        @Published var appearanceMode: AppearanceMode = .light
        @Published var onPromptCopyRequested: (() -> Void)?
        @Published var onAnswerCopyRequested: (() -> Void)?
    }

    private let clipboard: ClipboardService
    private let settingsStore: SettingsStore
    private let model = Model()

    private var window: NSWindow?
    private var hostingView: NSHostingView<AskAnswerWindowView>?
    private var appearanceObserver: NSObjectProtocol?

    init(clipboard: ClipboardService, settingsStore: SettingsStore) {
        self.clipboard = clipboard
        self.settingsStore = settingsStore
        super.init()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.model.appearanceMode = self.settingsStore.appearanceMode
            self.hostingView?.rootView = AskAnswerWindowView(model: self.model)
            self.applyAppearance(to: window)
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func show(title: String, question: String, selectedText: String?, answerMarkdown: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(title: title, question: question, selectedText: selectedText, answerMarkdown: answerMarkdown)
            }
            return
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAnswer = answerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAnswer.isEmpty else { return }

        ensureWindow()
        model.question = trimmedQuestion
        model.selectedText = trimmedSelectedText
        model.answerMarkdown = trimmedAnswer
        model.appearanceMode = settingsStore.appearanceMode
        model.onPromptCopyRequested = { [weak self] in
            let promptText = trimmedSelectedText.isEmpty
                ? trimmedQuestion
                : "\(trimmedQuestion)\n\n\(trimmedSelectedText)"
            self?.clipboard.write(text: promptText)
        }
        model.onAnswerCopyRequested = { [weak self] in
            self?.clipboard.write(text: trimmedAnswer)
        }

        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Presenting answer window
            Question: \(trimmedQuestion)
            Selected Text: \(trimmedSelectedText.isEmpty ? "<empty>" : trimmedSelectedText)
            Answer Markdown: \(trimmedAnswer)
            """
        )

        guard let window else { return }
        hostingView?.rootView = AskAnswerWindowView(model: model)
        applyAppearance(to: window)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = title
    }

    func dismiss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
            return
        }
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        model.appearanceMode = settingsStore.appearanceMode
        let rootView = AskAnswerWindowView(model: model)
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = L("workflow.ask.answerTitle")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: Metrics.minWindowWidth, height: Metrics.minWindowHeight)
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
        window.contentView = hosting
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        applyAppearance(to: window)

        self.hostingView = hosting
        self.window = window
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
    }
}

extension AskAnswerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}

private struct AskAnswerWindowView: View {
    @ObservedObject var model: AskAnswerWindowController.Model

    @State private var isPromptHovered = false
    @State private var isPromptTextHovered = false
    @State private var isAnswerHovered = false
    @State private var isSelectedTextExpanded = false

    var body: some View {
        ZStack {
            StudioTheme.windowBackground

            VStack(alignment: .leading, spacing: AskAnswerWindowController.Metrics.sectionSpacing) {
                promptSection
                answerSection
            }
            .padding(.horizontal, AskAnswerWindowController.Metrics.outerHorizontalPadding)
            .padding(.top, AskAnswerWindowController.Metrics.outerTopPadding)
            .padding(.bottom, AskAnswerWindowController.Metrics.outerBottomPadding)
        }
        .frame(
            minWidth: AskAnswerWindowController.Metrics.minWindowWidth,
            idealWidth: AskAnswerWindowController.Metrics.windowWidth,
            maxWidth: .infinity,
            minHeight: AskAnswerWindowController.Metrics.minWindowHeight,
            idealHeight: AskAnswerWindowController.Metrics.windowHeight,
            maxHeight: .infinity
        )
    }

    private var promptSection: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.smallMedium) {
            Image(systemName: "mic")
                .font(.system(size: StudioTheme.Typography.iconMedium, weight: .semibold))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: AskAnswerWindowController.Metrics.questionIconWidth)

            VStack(alignment: .leading, spacing: StudioTheme.Spacing.textCompact) {
                HStack(alignment: .firstTextBaseline, spacing: StudioTheme.Spacing.xSmall) {
                    Text(model.question)
                        .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !model.selectedText.isEmpty {
                        Image(systemName: isSelectedTextExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: StudioTheme.Typography.iconTiny, weight: .semibold))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(.top, 2)
                    }
                }

                if !model.selectedText.isEmpty {
                    Text(model.selectedText)
                        .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(isSelectedTextExpanded ? nil : AskAnswerWindowController.Metrics.selectedTextMaxLines)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, StudioTheme.Spacing.small)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(StudioTheme.border.opacity(0.9))
                                .frame(width: 3)
                        }
                }
            }
            .contentShape(Rectangle())
            .onHover { isPromptTextHovered = $0 }
            .onTapGesture {
                guard !model.selectedText.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    isSelectedTextExpanded.toggle()
                }
            }

            copyButton(isVisible: isPromptHovered || isPromptTextHovered) {
                model.onPromptCopyRequested?()
            }
        }
        .padding(AskAnswerWindowController.Metrics.promptCardPadding)
        .contentShape(Rectangle())
        .onHover { isPromptHovered = $0 }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("workflow.ask.answerSectionTitle"), systemImage: "sparkles")
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                copyButton(isVisible: isAnswerHovered) {
                    model.onAnswerCopyRequested?()
                }
            }
            .padding(.horizontal, AskAnswerWindowController.Metrics.answerHeaderHorizontalPadding)
            .padding(.vertical, AskAnswerWindowController.Metrics.answerHeaderVerticalPadding)

            Divider()
                .overlay(StudioTheme.border.opacity(0.8))

            MarkdownWebView(
                markdown: model.answerMarkdown,
                appearanceMode: model.appearanceMode
            )
            .padding(.horizontal, AskAnswerWindowController.Metrics.answerContentHorizontalPadding)
            .padding(.vertical, AskAnswerWindowController.Metrics.answerContentVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous
            )
            .fill(StudioTheme.surface)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous
            )
            .stroke(StudioTheme.border.opacity(0.85), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
            style: .continuous
        ))
        .onHover { isAnswerHovered = $0 }
    }

    private func copyButton(isVisible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(
                    width: AskAnswerWindowController.Metrics.headerButtonSize,
                    height: AskAnswerWindowController.Metrics.headerButtonSize
                )
        }
        .buttonStyle(.plain)
        .studioTooltip(L("common.copy"), yOffset: 30)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private struct MarkdownWebView: NSViewRepresentable {
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
          <style>
            :root {
              color-scheme: \(colorSchemeValue);
              --bg: \(colorHex(StudioTheme.surface));
              --text: \(colorHex(StudioTheme.textPrimary));
              --muted: \(colorHex(StudioTheme.textSecondary));
              --border: \(colorHex(StudioTheme.border));
              --accent: \(colorHex(StudioTheme.accent));
              --code-bg: \(colorHex(StudioTheme.surfaceMuted));
            }
            * { box-sizing: border-box; }
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif;
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
          </style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

    private var colorSchemeValue: String {
        switch appearanceMode {
        case .dark:
            return "dark"
        case .light:
            return "light"
        case .system:
            return "light dark"
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
            [Ask Answer] Markdown passed to WebView:
            \(normalized)
            """
        )

        return normalized
    }

    private func colorHex(_ color: Color) -> String {
        NSColor(color).resolvedHexString
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
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
        let color = usingColorSpace(.deviceRGB) ?? self
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
