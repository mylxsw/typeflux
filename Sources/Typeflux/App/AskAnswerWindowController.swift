import AppKit
import SwiftUI

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
            queue: .main,
        ) { [weak self] _ in
            guard let self, let window else { return }
            model.appearanceMode = self.settingsStore.appearanceMode
            hostingView?.rootView = AskAnswerWindowView(model: model)
            applyAppearance(to: window)
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
            """,
        )

        guard let window else { return }
        hostingView?.rootView = AskAnswerWindowView(model: model)
        applyAppearance(to: window)
        if !window.isVisible {
            window.center()
        }
        DockVisibilityController.shared.windowDidShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = title
    }

    func dismiss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
            return
        }
        if let window {
            DockVisibilityController.shared.windowDidHide(window)
            window.orderOut(nil)
        }
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
            defer: false,
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

        hostingView = hosting
        self.window = window
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
    }
}

extension AskAnswerWindowController: NSWindowDelegate {
    func windowShouldClose(_: NSWindow) -> Bool {
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
            maxHeight: .infinity,
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
                appearanceMode: model.appearanceMode,
            )
            .padding(.horizontal, AskAnswerWindowController.Metrics.answerContentHorizontalPadding)
            .padding(.vertical, AskAnswerWindowController.Metrics.answerContentVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous,
            )
            .fill(StudioTheme.surface),
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous,
            )
            .stroke(StudioTheme.border.opacity(0.85), lineWidth: 1),
        )
        .contentShape(RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
            style: .continuous,
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
                    height: AskAnswerWindowController.Metrics.headerButtonSize,
                )
        }
        .buttonStyle(.plain)
        .studioTooltip(L("common.copy"), yOffset: 30)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}
