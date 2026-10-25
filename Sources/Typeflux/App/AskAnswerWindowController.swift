// swiftlint:disable file_length
import AppKit
import SwiftUI

private final class TransparentAskAnswerHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

final class AskAnswerWindowController: NSObject {
    private lazy var interfaceStyleObserver = MainActor.assumeIsolated {
        InterfaceStyleObserver(settings: settingsStore)
    }

    fileprivate enum Metrics {
        static let windowWidth: CGFloat = 790
        static let windowHeight: CGFloat = 620
        static let minWindowWidth: CGFloat = 660
        static let minWindowHeight: CGFloat = 500
        static let titleBarInsetHeight: CGFloat = 48
        static let outerHorizontalPadding: CGFloat = 30
        static let outerBottomPadding: CGFloat = 22
        static let sectionSpacing: CGFloat = 16
        static let headerButtonSize: CGFloat = 20
        static let contentCardCornerRadius: CGFloat = 12
        static let contentCardPadding: CGFloat = 18
        static let answerContentTopPadding: CGFloat = 0
        static let promptBubbleCornerRadius: CGFloat = 12
        static let promptBubbleMaxWidth: CGFloat = 390
        static let promptBubbleMinHeight: CGFloat = 50
        static let answerMaxWidth: CGFloat = 600
        static let composerHeight: CGFloat = 68
        static let composerMaxWidth: CGFloat = 600
        static let composerCornerRadius: CGFloat = 10
        static let composerButtonSize: CGFloat = 24
        static let footerHeight: CGFloat = 20
        static let avatarSize: CGFloat = 32
        static let selectedTextMaxLines: Int = 4
    }

    fileprivate enum Palette {
        static let windowBackground = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.968, green: 0.976, blue: 0.990, alpha: 0.96),
            dark: NSColor(calibratedRed: 0.060, green: 0.068, blue: 0.084, alpha: 0.94)
        )
        static let windowBackgroundLower = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.992, green: 0.996, blue: 1.000, alpha: 0.94),
            dark: NSColor(calibratedRed: 0.078, green: 0.084, blue: 0.105, alpha: 0.92)
        )
        static let promptSurface = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.925, green: 0.938, blue: 1.000, alpha: 0.92),
            dark: NSColor(calibratedRed: 0.125, green: 0.130, blue: 0.180, alpha: 0.95)
        )
        static let answerSurface = StudioTheme.dynamic(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.98),
            dark: NSColor(calibratedRed: 0.105, green: 0.112, blue: 0.145, alpha: 0.95)
        )
        static let cardHighlight = StudioTheme.dynamic(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.74),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.055)
        )
        static let border = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.48, green: 0.56, blue: 0.72, alpha: 0.14),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.13)
        )
        static let questionAccent = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.94, alpha: 1),
            dark: NSColor(calibratedRed: 0.64, green: 0.52, blue: 1.0, alpha: 1)
        )
        static let answerAccent = StudioTheme.dynamic(
            light: NSColor(calibratedRed: 0.17, green: 0.78, blue: 0.54, alpha: 1),
            dark: NSColor(calibratedRed: 0.30, green: 0.82, blue: 0.55, alpha: 1)
        )
        static let composerSurface = StudioTheme.dynamic(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.58),
            dark: NSColor(calibratedRed: 0.105, green: 0.110, blue: 0.136, alpha: 0.58)
        )
    }

    fileprivate final class Model: ObservableObject {
        @Published var question: String = ""
        @Published var selectedText: String = ""
        @Published var answerMarkdown: String = ""
        @Published var appearanceMode: AppearanceMode = .light
        @Published var onPromptCopyRequested: (() -> Void)?
        @Published var onAnswerCopyRequested: (() -> Void)?
    }

    private final class WindowSession {
        let model: Model
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>

        init(model: Model, window: NSWindow, hostingView: NSHostingView<AnyView>) {
            self.model = model
            self.window = window
            self.hostingView = hostingView
        }
    }

    private let clipboard: ClipboardService
    private let settingsStore: SettingsStore
    private let outputPostProcessor: OutputPostProcessing

    private var sessions: [ObjectIdentifier: WindowSession] = [:]
    private var appearanceObserver: NSObjectProtocol?

    init(clipboard: ClipboardService, settingsStore: SettingsStore, outputPostProcessor: OutputPostProcessing) {
        self.clipboard = clipboard
        self.settingsStore = settingsStore
        self.outputPostProcessor = outputPostProcessor
        super.init()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for session in sessions.values {
                session.model.appearanceMode = self.settingsStore.appearanceMode
                session.hostingView.rootView = AnyView(AskAnswerWindowView(model: session.model)
                    .interfaceStyle(following: interfaceStyleObserver))
                applyAppearance(to: session.window)
            }
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    // swiftlint:disable:next function_body_length
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

        let presentationStartedAt = Date()
        let model = Model()
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
            guard let self else { return }
            Task {
                let processedAnswer = await self.outputPostProcessor.process(trimmedAnswer)
                await MainActor.run {
                    self.clipboard.write(text: processedAnswer)
                }
            }
        }

        NetworkDebugLogger.logMessage(
            """
            [Ask Answer] Presenting answer window
            Question Length: \(trimmedQuestion.count)
            Question Preview: \(String(trimmedQuestion.prefix(120)))
            Selected Text Length: \(trimmedSelectedText.count)
            Answer Markdown Length: \(trimmedAnswer.count)
            Answer Markdown Preview: \(String(trimmedAnswer.prefix(160)))
            """
        )

        let session = makeWindowSession(model: model)
        positionNewWindow(session.window, offsetIndex: sessions.count)
        sessions[ObjectIdentifier(session.window)] = session

        DockVisibilityController.shared.windowDidShow(session.window)
        session.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NetworkDebugLogger.logMessage(
            String(
                format: "[Ask Timing] answer window presented in %.1fms",
                Date().timeIntervalSince(presentationStartedAt) * 1000
            )
        )
        _ = title
    }

    func dismiss() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss() }
            return
        }
        for session in sessions.values {
            DockVisibilityController.shared.windowDidHide(session.window)
            session.window.delegate = nil
            session.window.close()
        }
        sessions.removeAll()
    }

    private func makeWindowSession(model: Model) -> WindowSession {
        let rootView = AnyView(AskAnswerWindowView(model: model).interfaceStyle(following: interfaceStyleObserver))
        let hosting = TransparentAskAnswerHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = L("workflow.ask.answerTitle")
        window.identifier = TypefluxWindowIdentity.askAnswerWindowIdentifier
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.delegate = self
        window.minSize = NSSize(width: Metrics.minWindowWidth, height: Metrics.minWindowHeight)
        window.backgroundColor = .clear
        window.contentView = hosting
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        applyAppearance(to: window)

        return WindowSession(model: model, window: window, hostingView: hosting)
    }

    private func positionNewWindow(_ window: NSWindow, offsetIndex: Int) {
        window.center()

        let cascadeStep = CGFloat((offsetIndex % 8) * 28)
        guard cascadeStep > 0 else { return }

        var frame = window.frame
        frame.origin.x += cascadeStep
        frame.origin.y -= cascadeStep

        if let visibleFrame = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }

        window.setFrameOrigin(frame.origin)
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
        window.backgroundColor = .clear
    }
}

extension AskAnswerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DockVisibilityController.shared.windowDidHide(window)
        sessions.removeValue(forKey: ObjectIdentifier(window))
    }
}

private struct AskAnswerWindowView: View {
    @ObservedObject var model: AskAnswerWindowController.Model

    @State private var isAnswerHovered = false
    @State private var isSelectedTextExpanded = false

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea(.container, edges: .top)

            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: AskAnswerWindowController.Metrics.titleBarInsetHeight)

                VStack(alignment: .leading, spacing: AskAnswerWindowController.Metrics.sectionSpacing) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: AskAnswerWindowController.Metrics.sectionSpacing) {
                            promptSection
                            answerSection
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.bottom, StudioTheme.Spacing.medium)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    composer
                    footer
                }
                .padding(.horizontal, AskAnswerWindowController.Metrics.outerHorizontalPadding)
                .padding(.bottom, AskAnswerWindowController.Metrics.outerBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(
            minWidth: AskAnswerWindowController.Metrics.minWindowWidth,
            idealWidth: AskAnswerWindowController.Metrics.windowWidth,
            maxWidth: .infinity,
            minHeight: AskAnswerWindowController.Metrics.minWindowHeight,
            idealHeight: AskAnswerWindowController.Metrics.windowHeight,
            maxHeight: .infinity
        )
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var background: some View {
        AskWindowBackdrop()
    }

    private var promptSection: some View {
        HStack(alignment: .center, spacing: StudioTheme.Spacing.smallMedium) {
            Spacer(minLength: 56)
            promptBubble
            userAvatar
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var answerSection: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
            assistantAvatar
                .padding(.top, StudioTheme.Spacing.xxSmall)

            ZStack(alignment: .bottomTrailing) {
                MarkdownSwiftUIView(markdown: model.answerMarkdown)
                    .padding(.top, AskAnswerWindowController.Metrics.answerContentTopPadding)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)

                copyButton(isVisible: isAnswerHovered) {
                    model.onAnswerCopyRequested?()
                }
            }
            .padding(AskAnswerWindowController.Metrics.contentCardPadding)
            .frame(
                maxWidth: AskAnswerWindowController.Metrics.answerMaxWidth,
                alignment: .topLeading
            )
            .background(cardBackground(fill: AskAnswerWindowController.Palette.answerSurface))
            .overlay(cardBorder)
            .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 10)
            .contentShape(RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous
            ))
            .onHover { isAnswerHovered = $0 }

            Spacer(minLength: 22)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: StudioTheme.Spacing.xxSmall) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: StudioTheme.Typography.bodySmall, weight: .semibold))
            Text(L("workflow.ask.answerDisclaimer"))
                .font(.studioBody(StudioTheme.Typography.caption, weight: .medium))
        }
        .foregroundStyle(StudioTheme.textTertiary.opacity(0.78))
        .frame(maxWidth: .infinity)
        .frame(height: AskAnswerWindowController.Metrics.footerHeight)
    }

    private var composer: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(L("workflow.ask.followUpComingSoon"))
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                .foregroundStyle(StudioTheme.textTertiary.opacity(0.86))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, StudioTheme.Spacing.small)
                .padding(.leading, StudioTheme.Spacing.mediumLarge)
                .padding(.trailing, 54)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Button(action: {}) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: StudioTheme.Typography.iconXSmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary.opacity(0.76))
                    .frame(
                        width: AskAnswerWindowController.Metrics.composerButtonSize,
                        height: AskAnswerWindowController.Metrics.composerButtonSize
                    )
                    .background(Circle().fill(StudioTheme.textTertiary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .padding(.trailing, StudioTheme.Spacing.small)
            .padding(.bottom, StudioTheme.Spacing.small)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: AskAnswerWindowController.Metrics.composerHeight,
            maxHeight: AskAnswerWindowController.Metrics.composerHeight
        )
        .background(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.composerCornerRadius,
                style: .continuous
            )
            .fill(AskAnswerWindowController.Palette.composerSurface)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.composerCornerRadius,
                style: .continuous
            )
            .stroke(AskAnswerWindowController.Palette.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.025), radius: 8, x: 0, y: 3)
        .opacity(0.72)
        .allowsHitTesting(false)
        .accessibilityLabel(L("workflow.ask.followUpComingSoon"))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func cardBackground(fill: Color) -> some View {
        RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
            style: .continuous
        )
        .fill(fill)
        .overlay(alignment: .top) {
            RoundedRectangle(
                cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        AskAnswerWindowController.Palette.cardHighlight,
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.contentCardCornerRadius,
            style: .continuous
        )
        .stroke(AskAnswerWindowController.Palette.border, lineWidth: 1)
    }

    private func copyButton(isVisible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
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

    private var promptBubble: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.textCompact) {
            Text(model.question)
                .font(.studioBody(StudioTheme.Typography.body, weight: .regular))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !model.selectedText.isEmpty {
                selectedTextPreview
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(
            maxWidth: AskAnswerWindowController.Metrics.promptBubbleMaxWidth,
            minHeight: AskAnswerWindowController.Metrics.promptBubbleMinHeight,
            alignment: .center
        )
        .background(promptBubbleBackground)
        .overlay(promptBubbleBorder)
        .shadow(color: AskAnswerWindowController.Palette.questionAccent.opacity(0.10), radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.promptBubbleCornerRadius,
            style: .continuous
        ))
        .onTapGesture {
            guard !model.selectedText.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                isSelectedTextExpanded.toggle()
            }
        }
        .contextMenu {
            Button(L("common.copy")) {
                model.onPromptCopyRequested?()
            }
        }
    }

    private var selectedTextPreview: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.textMicro) {
            Divider()
                .opacity(0.48)

            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(AskAnswerWindowController.Palette.questionAccent.opacity(0.42))
                    .frame(width: 3)

                Text(model.selectedText)
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(isSelectedTextExpanded ? nil : AskAnswerWindowController.Metrics.selectedTextMaxLines)
                    .truncationMode(.tail)
            }
        }
        .padding(.top, StudioTheme.Spacing.xSmall)
    }

    private var userAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            AskAnswerWindowController.Palette.questionAccent.opacity(0.12),
                            AskAnswerWindowController.Palette.questionAccent.opacity(0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: AskAnswerWindowController.Palette.questionAccent.opacity(0.18), radius: 12, x: 0, y: 7)

            Image(systemName: "person.fill")
                .font(.system(size: StudioTheme.Typography.iconMedium, weight: .semibold))
                .foregroundStyle(AskAnswerWindowController.Palette.questionAccent)
        }
        .frame(
            width: AskAnswerWindowController.Metrics.avatarSize,
            height: AskAnswerWindowController.Metrics.avatarSize
        )
    }

    private var assistantAvatar: some View {
        TypefluxLogoBadge(
            size: AskAnswerWindowController.Metrics.avatarSize,
            symbolSize: 18,
            backgroundShape: .circle,
            showsBorder: false
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        .frame(
            width: AskAnswerWindowController.Metrics.avatarSize,
            height: AskAnswerWindowController.Metrics.avatarSize
        )
    }

    private var promptBubbleBackground: some View {
        RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.promptBubbleCornerRadius,
            style: .continuous
        )
        .fill(
            LinearGradient(
                colors: [
                    AskAnswerWindowController.Palette.promptSurface,
                    AskAnswerWindowController.Palette.promptSurface.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var promptBubbleBorder: some View {
        RoundedRectangle(
            cornerRadius: AskAnswerWindowController.Metrics.promptBubbleCornerRadius,
            style: .continuous
        )
        .stroke(AskAnswerWindowController.Palette.questionAccent.opacity(0.13), lineWidth: 1)
    }
}
