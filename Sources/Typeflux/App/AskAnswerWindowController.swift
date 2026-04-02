import AppKit
import SwiftUI

final class AskAnswerWindowController: NSObject {
    fileprivate enum Metrics {
        static let windowWidth: CGFloat = 820
        static let windowHeight: CGFloat = 520
        static let minWindowWidth: CGFloat = 760
        static let minWindowHeight: CGFloat = 480
        static let outerCornerRadius: CGFloat = 12
        static let outerHorizontalPadding: CGFloat = 14
        static let outerTopPadding: CGFloat = 8
        static let outerBottomPadding: CGFloat = 10
        static let sectionSpacing: CGFloat = 10
        static let headerButtonSize: CGFloat = 30
        static let questionIconWidth: CGFloat = 20
        static let contentCardCornerRadius: CGFloat = 12
        static let answerHeaderHorizontalPadding: CGFloat = 12
        static let answerHeaderVerticalPadding: CGFloat = 8
        static let answerContentHorizontalPadding: CGFloat = 14
        static let answerContentVerticalPadding: CGFloat = 12
        static let selectedTextMaxLines: Int = 4
    }

    fileprivate final class Model: ObservableObject {
        @Published var question: String = ""
        @Published var selectedText: String = ""
        @Published var answerMarkdown: String = ""
        @Published var onDismissRequested: (() -> Void)?
        @Published var onCopyRequested: (() -> Void)?
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
        model.onDismissRequested = { [weak self] in self?.dismiss() }
        model.onCopyRequested = { [weak self] in
            self?.clipboard.write(text: trimmedAnswer)
        }

        guard let window else { return }
        hostingView?.rootView = AskAnswerWindowView(model: model)
        applyAppearance(to: window)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let rootView = AskAnswerWindowView(model: model)
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
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
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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
                Text(model.question)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !model.selectedText.isEmpty {
                    Text(model.selectedText)
                        .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(AskAnswerWindowController.Metrics.selectedTextMaxLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, StudioTheme.Spacing.small)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(StudioTheme.border.opacity(0.9))
                                .frame(width: 3)
                        }
                }
            }

            Button(action: { model.onCopyRequested?() }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: StudioTheme.Typography.iconMedium, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L("common.copy"))
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("workflow.ask.answerSectionTitle"), systemImage: "sparkles")
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                Button(action: { model.onCopyRequested?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: StudioTheme.Typography.iconMedium, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L("common.copy"))
            }
            .padding(.horizontal, AskAnswerWindowController.Metrics.answerHeaderHorizontalPadding)
            .padding(.vertical, AskAnswerWindowController.Metrics.answerHeaderVerticalPadding)

            Divider()
                .overlay(StudioTheme.border.opacity(0.8))

            MarkdownTextView(markdown: model.answerMarkdown)
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
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        update(textView: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        update(textView: textView)
    }

    private func update(textView: NSTextView) {
        textView.textStorage?.setAttributedString(renderedMarkdown())
        textView.setNeedsDisplay(textView.bounds)
    }

    private func renderedMarkdown() -> NSAttributedString {
        let normalizedMarkdown = normalizedMarkdownText()
        let baseFont = NSFont.systemFont(ofSize: StudioTheme.Typography.bodyLarge, weight: .medium)
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 2
        bodyParagraph.paragraphSpacing = 10

        let fallback = NSAttributedString(
            string: normalizedMarkdown,
            attributes: [
                NSAttributedString.Key.font: baseFont,
                NSAttributedString.Key.foregroundColor: NSColor(StudioTheme.textPrimary),
                NSAttributedString.Key.paragraphStyle: bodyParagraph
            ]
        )

        guard let parsed = try? AttributedString(
            markdown: normalizedMarkdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return fallback
        }

        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.beginEditing()

        attributed.enumerateAttribute(NSAttributedString.Key.paragraphStyle, in: fullRange) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = max(style.paragraphSpacing, 10)
            attributed.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: range)
        }

        attributed.enumerateAttribute(NSAttributedString.Key.font, in: fullRange) { value, range, _ in
            guard let font = value as? NSFont else {
                attributed.addAttribute(NSAttributedString.Key.font, value: baseFont, range: range)
                return
            }

            let descriptor = font.fontDescriptor
            let traits = descriptor.symbolicTraits
            let targetSize: CGFloat

            if font.pointSize >= 22 {
                targetSize = StudioTheme.Typography.sectionTitle
            } else if font.pointSize >= 18 {
                targetSize = StudioTheme.Typography.subsectionTitle
            } else {
                targetSize = StudioTheme.Typography.bodyLarge
            }

            let updatedDescriptor = descriptor.withSymbolicTraits(traits)
            let updatedFont = NSFont(descriptor: updatedDescriptor, size: targetSize) ?? font
            attributed.addAttribute(NSAttributedString.Key.font, value: updatedFont, range: range)
        }

        attributed.addAttribute(
            NSAttributedString.Key.foregroundColor,
            value: NSColor(StudioTheme.textPrimary),
            range: fullRange
        )

        attributed.endEditing()
        return attributed
    }

    private func normalizedMarkdownText() -> String {
        var normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")

        if !normalized.contains("\n") && normalized.contains("\\n") {
            normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
        }

        return normalized
    }
}
