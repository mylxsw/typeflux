import AppKit
import QuartzCore
import SwiftUI

enum LiveTranscriptPreviewLayout {
    static let maxVisibleLineCount = 3
    static let lineHeight: CGFloat = 16
    static let textViewportHeight = lineHeight * CGFloat(maxVisibleLineCount)
    static let expandedCapsuleHeight: CGFloat = 103
    static let expandedOverlayHeight: CGFloat = 194
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

private final class RoundedVisualEffectView: NSVisualEffectView {
    var preferredCornerRadius: CGFloat?

    override func layout() {
        super.layout()
        layer?.cornerRadius = preferredCornerRadius ?? bounds.height / 2
    }
}

private struct RoundedVisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat?

    func makeNSView(context _: Context) -> RoundedVisualEffectView {
        let view = RoundedVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.preferredCornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: RoundedVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = true
        nsView.preferredCornerRadius = cornerRadius
        nsView.needsLayout = true
    }
}

private struct LiquidGlassShapeBackground<S: InsettableShape>: View {
    let shape: S
    let cornerRadius: CGFloat?
    let tintOpacity: Double
    let scrimOpacity: Double
    let strokeOpacity: Double
    let lineWidth: CGFloat
    let interactive: Bool

    init(
        shape: S,
        cornerRadius: CGFloat? = nil,
        tintOpacity: Double = 0.08,
        scrimOpacity: Double = 0.18,
        strokeOpacity: Double = 0.16,
        lineWidth: CGFloat = 0.9,
        interactive: Bool = false,
    ) {
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.tintOpacity = tintOpacity
        self.scrimOpacity = scrimOpacity
        self.strokeOpacity = strokeOpacity
        self.lineWidth = lineWidth
        self.interactive = interactive
    }

    var body: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ZStack {
                    shape
                        .fill(Color.clear)
                        .glassEffect(
                            Glass.clear
                                .interactive(interactive)
                                .tint(Color.white.opacity(tintOpacity)),
                            in: shape,
                        )

                    shape
                        .fill(Color.black.opacity(scrimOpacity))
                        .allowsHitTesting(false)
                }
            } else {
                fallbackBackground
            }
            #else
            fallbackBackground
            #endif
        }
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(strokeOpacity + 0.08),
                            Color.white.opacity(strokeOpacity * 0.35),
                            Color.white.opacity(strokeOpacity),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                    lineWidth: lineWidth,
                ),
        )
        .overlay(
            shape
                .inset(by: lineWidth + 0.6)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.clear,
                            Color.white.opacity(0.07),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                    lineWidth: 0.6,
                )
                .blendMode(.screen),
        )
    }

    private var fallbackBackground: some View {
        ZStack {
            RoundedVisualEffectBlur(
                material: .popover,
                blendingMode: .behindWindow,
                cornerRadius: cornerRadius,
            )
            .allowsHitTesting(false)

            shape
                .fill(Color.black.opacity(tintOpacity))
        }
    }
}

/// CGEventTap callback — intercepts and consumes keyboard events (Return/Esc/arrows)
/// system-wide so the panel never needs to steal focus from the original app.
private func overlayEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<OverlayController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handleEventTapEvent(type: type, event: event)
}

struct OverlayFailureAction {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let isRetry: Bool
    let style: Style
    let trailingSystemImage: String?
    let handler: () -> Void

    init(
        title: String,
        isRetry: Bool,
        style: Style = .primary,
        trailingSystemImage: String? = nil,
        handler: @escaping () -> Void,
    ) {
        self.title = title
        self.isRetry = isRetry
        self.style = style
        self.trailingSystemImage = trailingSystemImage
        self.handler = handler
    }
}

final class OverlayController {
    private static let autoDismissDelay: TimeInterval = 6.0
    private static let shadowGutter: CGFloat = 32
    private static let processingStatusLocalizationKey = "overlay.processing.thinking"

    struct PersonaPickerItem: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
    }

    enum PersonaPickerIcon: Equatable {
        case none
        case global
        case application(NSImage?)

        static func == (lhs: PersonaPickerIcon, rhs: PersonaPickerIcon) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.global, .global), (.application, .application):
                true
            default:
                false
            }
        }
    }

    private let appState: AppStateStore
    private var window: NSPanel?

    private let model = OverlayViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastPositionedFrame: NSRect?
    private var lastPositionedPresentation: OverlayViewModel.Presentation?
    private var pendingFrameAnimationWorkItem: DispatchWorkItem?
    private var pendingPresentationWorkItem: DispatchWorkItem?

    init(appState: AppStateStore) {
        self.appState = appState
        model.onDismissRequested = { [weak self] in
            self?.dismiss(after: 0)
        }
    }

    deinit {
        removeKeyMonitoring()
    }

    func setRecordingActionHandlers(onCancel: (() -> Void)?, onConfirm: (() -> Void)?) {
        model.onCancelRequested = onCancel
        model.onConfirmRequested = onConfirm
    }

    func setPersonaPickerHandlers(
        onMoveUp: (() -> Void)?,
        onMoveDown: (() -> Void)?,
        onSelect: ((Int) -> Void)?,
        onConfirm: (() -> Void)?,
        onCancel: (() -> Void)?,
    ) {
        model.onPersonaMoveUpRequested = onMoveUp
        model.onPersonaMoveDownRequested = onMoveDown
        model.onPersonaSelectRequested = onSelect
        model.onPersonaConfirmRequested = onConfirm
        model.onPersonaCancelRequested = onCancel
    }

    func setResultDialogHandler(onCopy: (() -> Void)?) {
        model.onResultCopyRequested = onCopy
    }

    func setFailureRetryHandler(onRetry: (() -> Void)?) {
        model.onFailureRetryHandler = onRetry
    }

    func show(hintText: String? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.show(hintText: hintText) }
            return
        }
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        model.presentation = .recordingHold
        model.recordingPreviewExpanded = false
        model.statusText = L("overlay.recording.listening")
        model.detailText = ""
        model.recordingHintText = hintText ?? ""
        model.processingProgress = 0
        refreshWindow()
    }

    private func cancelPendingPresentationTransition() {
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
    }

    private func ensureWindow() {
        if window == nil {
            let view = OverlayView(model: model)
            let hosting = TransparentHostingView(rootView: view)
            hosting.wantsLayer = true
            hosting.layer?.isOpaque = false
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            let metrics = metrics(for: .recordingHold)
            let panel = OverlayPanel(
                contentRect: NSRect(origin: .zero, size: metrics.size),
                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false,
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level.statusBar
            panel.backgroundColor = NSColor.clear
            panel.hasShadow = false
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [
                NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.transient,
            ]
            panel.contentView = hosting
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.isOpaque = false
            panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

            window = panel
        }
    }

    func showLockedRecording(hintText: String? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showLockedRecording(hintText: hintText) }
            return
        }
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        model.presentation = .recordingLocked
        model.recordingPreviewExpanded = false
        model.recordingHintText = hintText ?? ""
        refreshWindow()
    }

    func updateRecordingPreviewText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateRecordingPreviewText(text) }
            return
        }

        model.detailText = text
        model.recordingPreviewExpanded = true
        switch model.presentation {
        case .recordingHold:
            model.presentation = .recordingHoldPreview
        case .recordingLocked:
            model.presentation = .recordingLockedPreview
        case .recordingHoldPreview, .recordingLockedPreview:
            break
        default:
            return
        }
        refreshWindow()
    }

    func showProcessing() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showProcessing() }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        if model.presentation.isRecordingPreview {
            model.recordingPreviewExpanded = false
            model.statusText = L(Self.processingStatusLocalizationKey)
            model.recordingHintText = ""
            model.processingProgress = 0
            model.processingPhase = 1
            model.processingEpoch += 1
            refreshWindow()

            let workItem = DispatchWorkItem { [weak self] in
                self?.showProcessingImmediately()
            }
            pendingPresentationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: workItem)
            return
        }
        showProcessingImmediately()
    }

    private func showProcessingImmediately() {
        cancelPendingPresentationTransition()
        ensureWindow()
        model.presentation = .processing
        model.recordingPreviewExpanded = false
        model.statusText = L(Self.processingStatusLocalizationKey)
        model.detailText = ""
        model.recordingHintText = ""
        model.processingProgress = 0
        model.processingPhase = 1
        model.processingEpoch += 1
        refreshWindow()
    }

    func showLLMProcessing() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showLLMProcessing() }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        model.presentation = .processing
        model.statusText = L(Self.processingStatusLocalizationKey)
        model.detailText = ""
        model.recordingHintText = ""
        model.processingProgress = 0
        model.processingPhase = 1
        model.processingEpoch += 1
        refreshWindow()
    }

    func transitionToLLMPhase() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.transitionToLLMPhase() }
            return
        }
        var shouldRefresh = false
        if model.presentation.isRecordingPreview {
            cancelPendingPresentationTransition()
            ensureWindow()
            model.presentation = .processing
            model.recordingPreviewExpanded = false
            model.statusText = L(Self.processingStatusLocalizationKey)
            model.detailText = ""
            model.recordingHintText = ""
            model.processingProgress = 0
            model.processingPhase = 1
            model.processingEpoch += 1
            shouldRefresh = true
        }
        guard model.presentation.isProcessing else { return }
        if model.processingPhase == 0 {
            model.statusText = L(Self.processingStatusLocalizationKey)
            model.processingPhase = 1
            shouldRefresh = true
        }
        if shouldRefresh {
            refreshWindow()
        }
    }

    func showFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showFailure(message: message) }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureActions = []
        refreshWindow()
    }

    func showRetryableFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showRetryableFailure(message: message) }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureActions = wrapFailureActions([
            OverlayFailureAction(
                title: L("common.retry"),
                isRetry: true,
                handler: { [weak self] in self?.model.onFailureRetryHandler?() },
            ),
        ])
        refreshWindow()
    }

    func showTimeoutFailure() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showTimeoutFailure() }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.timeout.title")
        model.detailText = L("overlay.timeout.message")
        model.failureActions = wrapFailureActions([
            OverlayFailureAction(
                title: L("common.retry"),
                isRetry: true,
                handler: { [weak self] in self?.model.onFailureRetryHandler?() },
            ),
        ])
        refreshWindow()
    }

    func showFailureWithActions(message: String, actions: [OverlayFailureAction]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showFailureWithActions(message: message, actions: actions) }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureActions = wrapFailureActions(actions)
        refreshWindow()
    }

    static func wrapFailureActions(
        _ actions: [OverlayFailureAction],
        beforeAction: @escaping () -> Void,
    ) -> [OverlayFailureAction] {
        actions.map { action in
            OverlayFailureAction(
                title: action.title,
                isRetry: action.isRetry,
                handler: {
                    beforeAction()
                    action.handler()
                },
            )
        }
    }

    private func wrapFailureActions(_ actions: [OverlayFailureAction]) -> [OverlayFailureAction] {
        Self.wrapFailureActions(actions) { [weak self] in
            self?.dismissImmediately()
        }
    }

    func updateLevel(_ level: Float) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateLevel(level) }
            return
        }
        model.level = level
    }

    func updateStreamingText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateStreamingText(text) }
            return
        }
        model.detailText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.presentation.isProcessing {
            model.presentation = trimmed.isEmpty ? .processing : .processingPreview
            refreshWindow()
        } else if model.presentation == .transcriptPreview {
            model.presentation = .processing
            refreshWindow()
        }
    }

    func showNotice(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showNotice(message: message) }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        model.presentation = .notice
        model.statusText = L("overlay.notice.title")
        model.detailText = message
        refreshWindow()
        dismiss(after: Self.autoDismissDelay)
    }

    func showResultDialog(title: String, message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showResultDialog(title: title, message: message)
            }
            return
        }
        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .resultDialog
        model.statusText = title
        model.detailText = message
        refreshWindow()
    }

    func showPersonaPicker(
        items: [PersonaPickerItem],
        selectedIndex: Int,
        title: String,
        instructions: String,
        icon: PersonaPickerIcon,
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showPersonaPicker(
                    items: items, selectedIndex: selectedIndex, title: title,
                    instructions: instructions, icon: icon,
                )
            }
            return
        }

        cancelPendingPresentationTransition()
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .personaPicker
        model.personaItems = items
        model.personaSelectedIndex = max(0, min(selectedIndex, max(0, items.count - 1)))
        model.personaViewportHeight = min(360, CGFloat(max(1, items.count)) * 84)
        model.statusText = title
        model.detailText = instructions
        model.personaPickerIcon = icon
        refreshWindow()
    }

    func updatePersonaPickerSelection(_ index: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updatePersonaPickerSelection(index) }
            return
        }

        guard !model.personaItems.isEmpty else { return }
        model.personaSelectedIndex = max(0, min(index, model.personaItems.count - 1))
        refreshWindow()
    }

    func dismissSoon() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissSoon() }
            return
        }
        cancelPendingPresentationTransition()

        if model.presentation.isProcessing {
            model.processingProgress = 1
            dismiss(after: 0.18)
        } else if model.presentation == .notice || model.presentation == .resultDialog {
            return
        } else {
            dismiss(after: StudioTheme.Durations.overlayDismissDelay)
        }
    }

    func dismissProcessingIfVisible() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissProcessingIfVisible() }
            return
        }

        guard model.presentation.isProcessing else { return }
        dismissSoon()
    }

    func dismissProcessingImmediatelyIfVisible() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissProcessingImmediatelyIfVisible() }
            return
        }

        guard model.presentation.isProcessing else { return }
        dismissImmediately()
    }

    /// Immediately hides the overlay window and resets state, running synchronously
    /// on the main thread. Use this before returning focus to the original application
    /// so the panel is guaranteed to be hidden before activation.
    func dismissImmediately() {
        let work = { [weak self] in
            guard let self else { return }
            cancelPendingPresentationTransition()
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            window?.orderOut(nil)
            model.detailText = ""
            model.level = 0
            model.processingProgress = 0
            removeKeyMonitoring()
            removeMouseMonitoring()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func dismiss(after delay: TimeInterval) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismiss(after: delay) }
            return
        }
        cancelPendingPresentationTransition()
        if model.presentation == .failure, delay > 0 {
            return
        }
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.model.detailText = ""
            self?.model.level = 0
            self?.model.processingProgress = 0
            self?.removeKeyMonitoring()
            self?.removeMouseMonitoring()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshWindow() {
        positionWindow()
        configureWindowAppearance()
        // Always use orderFrontRegardless — never makeKeyAndOrderFront.
        // Stealing key window status from the original app causes it to lose
        // focus and selection, which breaks write-back after LLM processing.
        window?.orderFrontRegardless()
        updateKeyMonitoring()
    }

    private func configureWindowAppearance() {
        guard let window, let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.isOpaque = false
        contentView.layer?.cornerCurve = .continuous

        if let chrome = windowChrome(for: model.presentation) {
            contentView.layer?.backgroundColor = chrome.background.cgColor
            contentView.layer?.cornerRadius = chrome.cornerRadius
            contentView.layer?.masksToBounds = true
            contentView.layer?.borderWidth = 1
            contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = 0
            contentView.layer?.masksToBounds = false
            contentView.layer?.borderWidth = 0
            contentView.layer?.borderColor = nil
        }
    }

    private func windowChrome(for presentation: OverlayViewModel.Presentation) -> WindowChromeStyle? {
        let background = NSColor(
            calibratedRed: 0.13,
            green: 0.11,
            blue: 0.11,
            alpha: 0.96,
        )

        switch presentation {
        case .transcriptPreview, .notice:
            return WindowChromeStyle(background: background, cornerRadius: 14)
        case .failure:
            return WindowChromeStyle(background: background, cornerRadius: 16)
        case .resultDialog:
            return WindowChromeStyle(background: background, cornerRadius: 14)
        default:
            return nil
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main, let window else { return }
        let frame = screen.visibleFrame
        let metrics = metrics(for: model.presentation)
        let x: CGFloat
        let y: CGFloat

        switch metrics.anchor {
        case .center:
            x = frame.midX - metrics.size.width / 2
            y = frame.midY - metrics.size.height / 2
        case .bottom:
            x = frame.midX - metrics.size.width / 2
            y = frame.minY + metrics.offset
        case .top:
            x = frame.midX - metrics.size.width / 2
            y = frame.maxY - metrics.offset - metrics.size.height
        }

        let contentRect = NSRect(origin: NSPoint(x: x, y: y), size: metrics.size)
        let targetFrame = window.frameRect(forContentRect: contentRect)
        let previousPresentation = lastPositionedPresentation
        let previousFrame = lastPositionedFrame
        let isShrinkingAfterPreview = previousPresentation?.isRecordingPreview == true
            && !model.presentation.isRecordingPreview
            && previousFrame.map { targetFrame.height < $0.height } == true
        let shouldAnimate = window.isVisible
            && previousFrame != nil
            && targetFrame != previousFrame

        pendingFrameAnimationWorkItem?.cancel()
        pendingFrameAnimationWorkItem = nil

        if isShrinkingAfterPreview {
            let presentation = model.presentation
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, self.model.presentation == presentation else { return }
                self.animateWindow(window, to: targetFrame, duration: 0.30)
                self.lastPositionedFrame = targetFrame
            }
            pendingFrameAnimationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        } else if shouldAnimate {
            animateWindow(window, to: targetFrame, duration: model.presentation.isRecordingPreview ? 0.38 : 0.28)
            lastPositionedFrame = targetFrame
        } else {
            window.setFrame(targetFrame, display: true)
            lastPositionedFrame = targetFrame
        }
        lastPositionedPresentation = model.presentation
        window.ignoresMouseEvents = !metrics.interactive
    }

    private func animateWindow(_ window: NSWindow, to targetFrame: NSRect, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    private func metrics(for presentation: OverlayViewModel.Presentation) -> OverlayMetrics {
        switch presentation {
        case .recordingHold:
            return OverlayMetrics(
                size: recordingOverlaySize(baseWidth: 146, baseHeight: 112), anchor: .bottom, offset: 16,
                interactive: false,
            )
        case .recordingHoldPreview:
            let isExpanded = model.recordingPreviewExpanded
            return OverlayMetrics(
                size: recordingOverlaySize(
                    baseWidth: isExpanded ? 428 : 146,
                    baseHeight: isExpanded ? LiveTranscriptPreviewLayout.expandedOverlayHeight : 112,
                ), anchor: .bottom, offset: 16,
                interactive: false,
            )
        case .recordingLocked:
            return OverlayMetrics(
                size: recordingOverlaySize(baseWidth: 196, baseHeight: 120), anchor: .bottom, offset: 16, interactive: true,
            )
        case .recordingLockedPreview:
            let isExpanded = model.recordingPreviewExpanded
            return OverlayMetrics(
                size: recordingOverlaySize(
                    baseWidth: isExpanded ? 428 : 196,
                    baseHeight: isExpanded ? LiveTranscriptPreviewLayout.expandedOverlayHeight : 120,
                ), anchor: .bottom, offset: 16,
                interactive: true,
            )
        case .processing:
            return OverlayMetrics(
                size: NSSize(width: processingOverlayWidth() + Self.shadowGutter * 2, height: 112), anchor: .bottom, offset: 16,
                interactive: false,
            )
        case .processingPreview:
            return OverlayMetrics(
                size: NSSize(width: 428, height: 218), anchor: .bottom, offset: 16,
                interactive: false,
            )
        case .transcriptPreview:
            return OverlayMetrics(
                size: NSSize(width: 344, height: 108), anchor: .bottom, offset: 80,
                interactive: false,
            )
        case .notice:
            return OverlayMetrics(
                size: NSSize(width: 344, height: 108), anchor: .bottom, offset: 80,
                interactive: true,
            )
        case .failure:
            let actionCount = model.failureActions.count
            let failureHeight: CGFloat = actionCount == 0 ? 216 : 216 + CGFloat(actionCount) * 40
            return OverlayMetrics(
                size: NSSize(width: 352, height: failureHeight), anchor: .bottom, offset: 80,
                interactive: true,
            )
        case .personaPicker:
            let viewportHeight = min(320, max(180, model.personaViewportHeight))
            return OverlayMetrics(
                size: NSSize(width: 458, height: viewportHeight + 152), anchor: .center, offset: 36,
                interactive: true,
            )
        case .resultDialog:
            return OverlayMetrics(
                size: NSSize(width: 446, height: 236), anchor: .bottom, offset: 36,
                interactive: true,
            )
        }
    }

    private func recordingOverlaySize(baseWidth: CGFloat, baseHeight: CGFloat) -> NSSize {
        guard !model.recordingHintText.isEmpty else {
            return NSSize(width: baseWidth, height: baseHeight)
        }

        let estimatedHintWidth = max(
            baseWidth,
            min(420, CGFloat(model.recordingHintText.count) * 10.0 + 44),
        )
        return NSSize(width: estimatedHintWidth, height: baseHeight + 36)
    }

    private func processingOverlayWidth() -> CGFloat {
        let title = model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText
        let estimatedTextWidth = CGFloat(title.count) * 8.5 + 52
        return min(188, max(118, estimatedTextWidth))
    }

    private func updateKeyMonitoring() {
        if model.presentation == .recordingLocked
            || model.presentation == .recordingLockedPreview
            || model.presentation == .failure
            || model.presentation == .personaPicker
            || model.presentation == .resultDialog
        {
            installKeyMonitoringIfNeeded()
        } else {
            removeKeyMonitoring()
        }

        if model.presentation == .personaPicker {
            installMouseMonitoringIfNeeded()
        } else {
            removeMouseMonitoring()
        }
    }

    private func installKeyMonitoringIfNeeded() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: overlayEventTapCallback,
                userInfo: selfPtr,
            )
        else {
            NSLog(
                "[OverlayController] Failed to create CGEventTap — falling back to NSEvent monitors",
            )
            installNSEventMonitorFallback()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Fallback when CGEventTap creation fails (e.g. sandboxed environment).
    /// Global monitors cannot consume events, so Return may still leak to chat apps.
    private func installNSEventMonitorFallback() {
        guard eventTap == nil, runLoopSource == nil else { return }
        let globalMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyCode(Int(event.keyCode))
        }
        let localMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handleKeyCode(Int(event.keyCode)) ? nil : event
        }
        // Store monitors in the eventTap/runLoopSource slots is not possible,
        // so we use associated-object-free approach: keep them as "Any" via a side channel.
        _fallbackGlobalMonitor = globalMon
        _fallbackLocalMonitor = localMon
    }

    private var _fallbackGlobalMonitor: Any?
    private var _fallbackLocalMonitor: Any?
    private var _mouseOutsideMonitor: Any?

    private func installMouseMonitoringIfNeeded() {
        guard _mouseOutsideMonitor == nil else { return }
        _mouseOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
        ) { [weak self] _ in
            guard let self, model.presentation == .personaPicker else { return }
            let mouseLocation = NSEvent.mouseLocation
            if let window, !window.frame.contains(mouseLocation) {
                DispatchQueue.main.async { self.model.requestPersonaCancel() }
            }
        }
    }

    private func removeMouseMonitoring() {
        if let m = _mouseOutsideMonitor { NSEvent.removeMonitor(m) }
        _mouseOutsideMonitor = nil
    }

    private func removeKeyMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil

        if let m = _fallbackGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = _fallbackLocalMonitor { NSEvent.removeMonitor(m) }
        _fallbackGlobalMonitor = nil
        _fallbackLocalMonitor = nil
    }

    /// Called from the CGEventTap C callback on the main run loop.
    fileprivate func handleEventTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if handleKeyCode(keyCode) {
            return nil // consume the event
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyCode(_ keyCode: Int) -> Bool {
        if model.presentation == .recordingHold || model.presentation == .recordingHoldPreview || model.presentation == .recordingLocked || model.presentation == .recordingLockedPreview {
            if keyCode == 53 {
                model.requestCancel()
                return true
            }
            return false
        }

        switch model.presentation {
        case .processing, .processingPreview:
            if keyCode == 53 {
                model.requestCancel()
                return true
            }
            return false
        case .failure:
            if keyCode == 53 {
                model.requestDismiss()
                return true
            }
            if keyCode == 36 || keyCode == 76, !model.failureActions.isEmpty {
                model.requestFailureAction(at: 0)
                return true
            }
            return false
        case .personaPicker:
            switch keyCode {
            case 53:
                model.requestPersonaCancel()
                return true
            case 125:
                model.requestPersonaMoveDown()
                return true
            case 126:
                model.requestPersonaMoveUp()
                return true
            case 36, 76:
                model.requestPersonaConfirm()
                return true
            default:
                return false
            }
        case .resultDialog:
            if keyCode == 53 {
                model.requestDismiss()
                return true
            }
            return false
        default:
            return false
        }
    }
}

private struct OverlayMetrics {
    enum Anchor {
        case top
        case bottom
        case center
    }

    let size: NSSize
    let anchor: Anchor
    let offset: CGFloat
    let interactive: Bool
}

private struct WindowChromeStyle {
    let background: NSColor
    let cornerRadius: CGFloat
}

final class OverlayViewModel: ObservableObject {
    enum Presentation {
        case recordingHold
        case recordingHoldPreview
        case recordingLocked
        case recordingLockedPreview
        case processing
        case processingPreview
        case transcriptPreview
        case notice
        case failure
        case personaPicker
        case resultDialog

        var isRecordingPreview: Bool {
            self == .recordingHoldPreview || self == .recordingLockedPreview
        }

        var isProcessing: Bool {
            self == .processing || self == .processingPreview
        }
    }

    @Published var presentation: Presentation = .recordingHold
    @Published var statusText: String = ""
    @Published var detailText: String = ""
    @Published var recordingHintText: String = ""
    @Published var recordingPreviewExpanded: Bool = false
    @Published var level: Float = 0
    @Published var processingProgress: CGFloat = 0
    @Published var processingEpoch: Int = 0
    @Published var processingPhase: Int = 0
    @Published var personaItems: [OverlayController.PersonaPickerItem] = []
    @Published var personaSelectedIndex: Int = 0
    @Published var personaViewportHeight: CGFloat = 240
    @Published var personaPickerIcon: OverlayController.PersonaPickerIcon = .none
    @Published var failureActions: [OverlayFailureAction] = []
    var onDismissRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onConfirmRequested: (() -> Void)?
    var onPersonaMoveUpRequested: (() -> Void)?
    var onPersonaMoveDownRequested: (() -> Void)?
    var onPersonaSelectRequested: ((Int) -> Void)?
    var onPersonaConfirmRequested: (() -> Void)?
    var onPersonaCancelRequested: (() -> Void)?
    var onResultCopyRequested: (() -> Void)?
    var onFailureRetryHandler: (() -> Void)?

    func requestFailureAction(at index: Int) {
        guard failureActions.indices.contains(index) else { return }
        failureActions[index].handler()
    }

    func requestFailureRetry() {
        guard let retryIndex = failureActions.firstIndex(where: { $0.isRetry }) else { return }
        failureActions[retryIndex].handler()
    }

    func requestDismiss() {
        onDismissRequested?()
    }

    func requestCancel() {
        onCancelRequested?()
    }

    func requestConfirm() {
        onConfirmRequested?()
    }

    func requestPersonaMoveUp() {
        onPersonaMoveUpRequested?()
    }

    func requestPersonaMoveDown() {
        onPersonaMoveDownRequested?()
    }

    func requestPersonaSelection(at index: Int) {
        onPersonaSelectRequested?(index)
    }

    func requestPersonaConfirm() {
        onPersonaConfirmRequested?()
    }

    func requestPersonaCancel() {
        onPersonaCancelRequested?()
    }

    func requestResultCopy() {
        onResultCopyRequested?()
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel

    private let recordingMotion = Animation.easeInOut(duration: 0.38)

    var body: some View {
        if usesWindowChrome {
            Group {
                switch model.presentation {
                case .recordingHold:
                    recordingStack { recordingMorphCapsule(expanded: false, showControls: false) }
                case .recordingHoldPreview:
                    recordingStack { recordingMorphCapsule(expanded: model.recordingPreviewExpanded, showControls: false) }
                case .recordingLocked:
                    recordingStack { recordingMorphCapsule(expanded: false, showControls: true) }
                case .recordingLockedPreview:
                    recordingStack { recordingMorphCapsule(expanded: model.recordingPreviewExpanded, showControls: true) }
                case .processing:
                    processingCapsule
                case .processingPreview:
                    processingTranscriptCapsule
                case .transcriptPreview:
                    previewCard
                case .notice:
                    noticeToast
                case .failure:
                    failureCard
                case .personaPicker:
                    personaPickerCard
                case .resultDialog:
                    resultDialogCard
                }
            }
        } else {
            Group {
                switch model.presentation {
                case .recordingHold:
                    recordingStack { recordingMorphCapsule(expanded: false, showControls: false) }
                case .recordingHoldPreview:
                    recordingStack { recordingMorphCapsule(expanded: model.recordingPreviewExpanded, showControls: false) }
                case .recordingLocked:
                    recordingStack { recordingMorphCapsule(expanded: false, showControls: true) }
                case .recordingLockedPreview:
                    recordingStack { recordingMorphCapsule(expanded: model.recordingPreviewExpanded, showControls: true) }
                case .processing:
                    processingCapsule
                case .processingPreview:
                    processingTranscriptCapsule
                case .transcriptPreview:
                    previewCard
                case .notice:
                    noticeToast
                case .failure:
                    failureCard
                case .personaPicker:
                    personaPickerCard
                case .resultDialog:
                    resultDialogCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .padding(containerPadding)
            .animation(recordingMotion, value: model.presentation)
        }
    }

    private var usesWindowChrome: Bool {
        switch model.presentation {
        case .transcriptPreview, .notice, .failure, .personaPicker, .resultDialog:
            true
        default:
            false
        }
    }

    private var contentAlignment: Alignment {
        switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview,
             .processing, .processingPreview, .notice, .transcriptPreview, .failure, .personaPicker, .resultDialog:
            .bottom
        }
    }

    private var containerPadding: EdgeInsets {
        switch model.presentation {
        case .recordingHold, .processing:
            EdgeInsets(top: 28, leading: 34, bottom: 42, trailing: 34)
        case .processingPreview:
            EdgeInsets(top: 30, leading: 34, bottom: 42, trailing: 34)
        case .recordingHoldPreview:
            EdgeInsets(top: 30, leading: 34, bottom: 42, trailing: 34)
        case .recordingLocked:
            EdgeInsets(top: 28, leading: 34, bottom: 46, trailing: 34)
        case .recordingLockedPreview:
            EdgeInsets(top: 30, leading: 34, bottom: 46, trailing: 34)
        case .transcriptPreview, .notice, .failure:
            EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        case .personaPicker, .resultDialog:
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
    }

    private func recordingStack(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            if !model.recordingHintText.isEmpty {
                recordingHintBanner
            }
            content()
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var recordingHintBanner: some View {
        Text(model.recordingHintText)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                LiquidGlassShapeBackground(
                    shape: Capsule(style: .continuous),
                    cornerRadius: nil,
                    tintOpacity: 0.05,
                    strokeOpacity: 0.14,
                    lineWidth: 0.8,
                ),
            )
            .fixedSize(horizontal: true, vertical: true)
    }

    private var processingCapsule: some View {
        ThinkingProgressCapsule(
            title: model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText,
            progress: model.processingProgress,
            epoch: model.processingEpoch,
            phase: model.processingPhase,
        )
    }

    private var processingTranscriptCapsule: some View {
        ProcessingTranscriptCapsule(
            text: model.detailText,
            title: model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText,
            progress: model.processingProgress,
            epoch: model.processingEpoch,
            phase: model.processingPhase,
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    private func recordingMorphCapsule(expanded: Bool, showControls: Bool) -> some View {
        MorphingRecordingCapsule(
            text: model.detailText,
            level: model.level,
            expanded: expanded,
            showControls: showControls,
            onCancel: model.requestCancel,
            onConfirm: model.requestConfirm,
        )
        .fixedSize(horizontal: true, vertical: true)
    }

    private var previewCard: some View {
        OverlayCompactToast(width: 344, hostedInWindowChrome: true) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)

                Text("“\(model.detailText)”")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
        }
    }

    private var failureCard: some View {
        OverlayCard(width: 352, hostedInWindowChrome: true, shadowed: false) {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(
                    icon: "exclamationmark.circle",
                    accent: Color(red: 1.0, green: 0.42, blue: 0.08), title: model.statusText,
                    dismissible: true,
                )

                ScrollView(showsIndicators: false) {
                    Text(model.detailText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: model.failureActions.isEmpty ? 92 : 124)

                ForEach(Array(model.failureActions.enumerated()), id: \.offset) { index, action in
                    Button(action: { model.requestFailureAction(at: index) }) {
                        HStack(spacing: 6) {
                            Text(action.title)
                                .font(.system(size: 13, weight: .semibold))

                            if let trailingSystemImage = action.trailingSystemImage {
                                Image(systemName: trailingSystemImage)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(action.style == .primary ? Color.white : Color.white.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, action.style == .primary ? 7 : 5)
                        .background(failureActionBackground(for: action.style))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func failureActionBackground(for style: OverlayFailureAction.Style) -> some View {
        switch style {
        case .primary:
            RoundedRectangle(cornerRadius: 8).fill(
                Color(red: 1.0, green: 0.42, blue: 0.08).opacity(0.55),
            )
        case .secondary:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8),
                )
        }
    }

    private var noticeToast: some View {
        OverlayCompactToast(width: 344, hostedInWindowChrome: true) {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(
                    icon: "info.circle",
                    accent: StudioTheme.accent,
                    title: model.statusText,
                    dismissible: true,
                    titleSize: 13.5,
                )

                Text(model.detailText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(2)
            }
        }
    }

    private var personaPickerCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    personaPickerScopeIcon

                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.statusText)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.98))
                            .lineLimit(1)
                            .shadow(color: Color.black.opacity(0.36), radius: 3, x: 0, y: 1)

                        Text(model.detailText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: Color.black.opacity(0.32), radius: 2, x: 0, y: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: model.requestPersonaCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.18)),
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.20), lineWidth: 0.8),
                        )
                        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2)
                }
                .buttonStyle(.plain)
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(model.personaItems.enumerated()), id: \.element.id) {
                            index, item in
                            personaPickerRow(
                                item: item, index: index,
                                isSelected: index == model.personaSelectedIndex,
                            )
                            .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: model.personaViewportHeight)
                .onAppear {
                    scrollPersonaSelection(with: proxy)
                }
                .onChange(of: model.personaSelectedIndex) { _ in
                    scrollPersonaSelection(with: proxy)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 458, alignment: .leading)
        .background(personaPickerGlassBackground)
        .shadow(color: Color.black.opacity(0.30), radius: 24, x: 0, y: 16)
    }

    private var personaPickerGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return LiquidGlassShapeBackground(
            shape: shape,
            cornerRadius: 24,
            tintOpacity: 0.08,
            scrimOpacity: 0.28,
            strokeOpacity: 0.18,
            lineWidth: 1.0,
            interactive: true,
        )
        .overlay(
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear,
                            Color.black.opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                )
                .allowsHitTesting(false),
        )
    }

    @ViewBuilder
    private var personaPickerScopeIcon: some View {
        switch model.personaPickerIcon {
        case .none:
            EmptyView()
        case .global:
                Image(systemName: "globe")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
        case let .application(icon):
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
            }
        }
    }

    private var resultDialogCard: some View {
        OverlayCard(width: 446, compact: true, hostedInWindowChrome: true, shadowed: false) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(
                    icon: "info.circle",
                    accent: StudioTheme.accent,
                    title: model.statusText,
                    dismissible: true,
                    titleSize: 13.5,
                )

                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(showsIndicators: false) {
                        Text(model.detailText)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 126)

                    HStack {
                        Spacer()

                        Button(action: model.requestResultCopy) {
                            Text(L("common.copy"))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.96))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.14)),
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1),
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize()
    }

    private func personaPickerRow(
        item: OverlayController.PersonaPickerItem, index: Int, isSelected: Bool,
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? StudioTheme.accent.opacity(0.34)
                        : Color.black.opacity(0.16),
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(item.title.prefix(2)).uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.78)),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.20 : 0.10), lineWidth: 0.8),
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.94))
                    .shadow(color: Color.black.opacity(0.34), radius: 2, x: 0, y: 1)
                Text(item.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.76 : 0.58))
                    .lineLimit(2)
                    .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
            }

            Spacer(minLength: 0)

            if isSelected {
                ZStack {
                    Circle()
                        .fill(StudioTheme.accent.opacity(0.95))
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 21, height: 21)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    isSelected
                        ? StudioTheme.accent.opacity(0.18)
                        : Color.black.opacity(0.10),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected
                                ? StudioTheme.accent.opacity(0.95) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.15 : 0.8,
                        ),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? [Color.white.opacity(0.055), Color.white.opacity(0.01)]
                                    : [Color.clear, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom,
                            ),
                        ),
                ),
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            model.requestPersonaSelection(at: index)
        }
    }

    private func scrollPersonaSelection(with proxy: ScrollViewProxy) {
        guard model.personaItems.indices.contains(model.personaSelectedIndex) else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(model.personaSelectedIndex, anchor: .center)
        }
    }

    private func cardHeader(
        icon: String,
        accent: Color,
        title: String,
        dismissible: Bool,
        titleSize: CGFloat = 16.5,
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))

            Spacer(minLength: 0)

            if dismissible {
                Button(action: model.requestDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08)),
                        )
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }
}

private struct LockedRecordingCapsule: View {
    let level: Float
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            roundIconButton(systemName: "xmark", action: onCancel)

            LevelWaveform(level: level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: 14)

            roundIconButton(systemName: "checkmark", action: onConfirm, inverted: true)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5.5)
        .background(
            LiquidGlassShapeBackground(
                shape: Capsule(style: .continuous),
                cornerRadius: nil,
                tintOpacity: 0.05,
                strokeOpacity: 0.16,
                lineWidth: 1.0,
                interactive: true,
            ),
        )
        .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private func roundIconButton(
        systemName: String, action: @escaping () -> Void, inverted: Bool = false,
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.92) : Color.black.opacity(0.20)),
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(inverted ? 0.46 : 0.22), lineWidth: 0.8),
                )
                .shadow(color: Color.black.opacity(0.20), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct MorphingRecordingCapsule: View {
    let text: String
    let level: Float
    let expanded: Bool
    let showControls: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: expanded ? 22 : 999, style: .continuous)
        let width: CGFloat = expanded ? 360 : (showControls ? 114 : 78)
        let height: CGFloat = expanded ? LiveTranscriptPreviewLayout.expandedCapsuleHeight : 35

        ZStack(alignment: .bottom) {
            if expanded {
                LiveTranscriptPreviewText(text: text)
                    .padding(.horizontal, 15)
                    .padding(.top, 12)
                    .padding(.bottom, 43)
                    .opacity(expanded ? 1 : 0)
                    .transition(.opacity)
            }

            controlsRow
                .frame(height: showControls ? 24 : 14)
                .padding(.horizontal, showControls ? 7 : 20)
                .padding(.bottom, showControls ? 5.5 : 10.5)
        }
        .frame(width: width, height: height, alignment: .bottom)
        .background(
            LiquidGlassShapeBackground(
                shape: shape,
                cornerRadius: expanded ? 22 : nil,
                tintOpacity: expanded ? 0.06 : 0.045,
                strokeOpacity: 0.15,
                lineWidth: 0.9,
                interactive: showControls,
            ),
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.38), value: expanded)
    }

    @ViewBuilder
    private var controlsRow: some View {
        if showControls {
            HStack(spacing: 7) {
                roundIconButton(systemName: "xmark", action: onCancel)

                LevelWaveform(level: level, activeColor: Color.white.opacity(0.95))
                    .frame(width: 38, height: 14)

                roundIconButton(systemName: "checkmark", action: onConfirm, inverted: true)
            }
        } else {
            LevelWaveform(level: level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: 14)
        }
    }

    private func roundIconButton(
        systemName: String, action: @escaping () -> Void, inverted: Bool = false,
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.92) : Color.black.opacity(0.20)),
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(inverted ? 0.46 : 0.22), lineWidth: 0.8),
                )
                .shadow(color: Color.black.opacity(0.20), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct LiveTranscriptPreviewText: View {
    let text: String
    private let bottomID = "live-transcript-preview-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .shadow(color: Color.black.opacity(0.55), radius: 3, x: 0, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
            }
            .frame(height: LiveTranscriptPreviewLayout.textViewportHeight)
            .onAppear {
                scrollToLatest(using: proxy, animated: false)
            }
            .onChange(of: text) { _ in
                scrollToLatest(using: proxy, animated: true)
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}

private struct ThinkingProgressCapsule: View {
    let title: String
    let progress: CGFloat
    let epoch: Int
    let phase: Int
    @State private var displayProgress: CGFloat = 0

    var body: some View {
        let capsuleShape = Capsule(style: .continuous)

        ZStack {
            LiquidGlassShapeBackground(
                shape: capsuleShape,
                cornerRadius: nil,
                tintOpacity: 0.05,
                strokeOpacity: 0.16,
                lineWidth: 1.0,
            )

            GeometryReader { geo in
                let width = max(0, geo.size.width)

                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(0, width * displayProgress))
                }
            }
            .mask(capsuleShape)

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 35, maxHeight: 35)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
        .onAppear {
            startProcessingPhase()
        }
        .onChange(of: epoch) { _ in
            displayProgress = 0
            startProcessingPhase()
        }
        .onChange(of: phase) { newPhase in
            guard newPhase == 1, progress < 1 else { return }
            withAnimation(.easeOut(duration: 2.0)) {
                displayProgress = 0.85
            }
        }
        .onChange(of: progress) { newValue in
            if newValue >= 1 {
                withAnimation(.easeOut(duration: 0.22)) {
                    displayProgress = 1
                }
            }
        }
    }

    private func startProcessingPhase() {
        guard progress < 1 else { return }
        let targetProgress: CGFloat = phase == 1 ? 0.85 : 0.5
        withAnimation(.easeOut(duration: 1.5)) {
            displayProgress = targetProgress
        }
    }
}

private struct ProcessingTranscriptCapsule: View {
    let text: String
    let title: String
    let progress: CGFloat
    let epoch: Int
    let phase: Int
    @State private var displayProgress: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        ZStack(alignment: .bottom) {
            LiveTranscriptPreviewText(text: text)
                .padding(.horizontal, 15)
                .padding(.top, 12)
                .padding(.bottom, 43)

            processingRow
                .frame(width: 132, height: 35)
                .padding(.bottom, 0)
        }
        .frame(width: 360, height: 127, alignment: .bottom)
        .background(
            LiquidGlassShapeBackground(
                shape: shape,
                cornerRadius: 22,
                tintOpacity: 0.06,
                strokeOpacity: 0.15,
                lineWidth: 0.9,
            ),
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
        .onAppear {
            startProcessingPhase()
        }
        .onChange(of: epoch) { _ in
            displayProgress = 0
            startProcessingPhase()
        }
        .onChange(of: phase) { newPhase in
            guard newPhase == 1, progress < 1 else { return }
            withAnimation(.easeOut(duration: 2.0)) {
                displayProgress = 0.85
            }
        }
        .onChange(of: progress) { newValue in
            if newValue >= 1 {
                withAnimation(.easeOut(duration: 0.22)) {
                    displayProgress = 1
                }
            }
        }
    }

    private var processingRow: some View {
        let capsuleShape = Capsule(style: .continuous)

        return ZStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.08)
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: max(0, geo.size.width * displayProgress))
                }
            }
            .mask(capsuleShape)

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
        }
        .clipShape(capsuleShape)
        .overlay(
            capsuleShape
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8),
        )
    }

    private func startProcessingPhase() {
        guard progress < 1 else { return }
        let targetProgress: CGFloat = phase == 1 ? 0.85 : 0.5
        withAnimation(.easeOut(duration: 1.5)) {
            displayProgress = targetProgress
        }
    }
}

private struct OverlayCapsule<Content: View>: View {
    let horizontalPadding: CGFloat
    @ViewBuilder var content: Content

    init(horizontalPadding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 10.5)
            .background(
                LiquidGlassShapeBackground(
                    shape: Capsule(),
                    cornerRadius: nil,
                    tintOpacity: 0.05,
                    strokeOpacity: 0.16,
                    lineWidth: 1.0,
                ),
            )
            .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 12)
            .environment(\.colorScheme, .dark)
    }
}

private struct OverlayCard<Content: View>: View {
    let width: CGFloat
    let compact: Bool
    let hostedInWindowChrome: Bool
    let shadowed: Bool
    @ViewBuilder var content: Content

    init(
        width: CGFloat,
        compact: Bool = false,
        hostedInWindowChrome: Bool = false,
        shadowed: Bool = true,
        @ViewBuilder content: () -> Content,
    ) {
        self.width = width
        self.compact = compact
        self.hostedInWindowChrome = hostedInWindowChrome
        self.shadowed = shadowed
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, compact ? 16 : 23)
            .padding(.vertical, compact ? 12 : 21)
            .frame(width: width, alignment: .leading)
            .background(cardBackground)
            .shadow(
                color: Color.black.opacity(shadowed ? 0.32 : 0), radius: shadowed ? 26 : 0, x: 0,
                y: shadowed ? 16 : 0,
            )
    }

    @ViewBuilder
    private var cardBackground: some View {
        if hostedInWindowChrome {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                .fill(Color(red: 0.13, green: 0.11, blue: 0.11).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1),
                )
        }
    }
}

private struct OverlayCompactToast<Content: View>: View {
    let width: CGFloat
    let hostedInWindowChrome: Bool
    @ViewBuilder var content: Content

    init(width: CGFloat, hostedInWindowChrome: Bool = false, @ViewBuilder content: () -> Content) {
        self.width = width
        self.hostedInWindowChrome = hostedInWindowChrome
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: width, alignment: .leading)
            .background(toastBackground)
            .shadow(
                color: Color.black.opacity(hostedInWindowChrome ? 0 : 0.28),
                radius: hostedInWindowChrome ? 0 : 18, x: 0, y: hostedInWindowChrome ? 0 : 12,
            )
    }

    @ViewBuilder
    private var toastBackground: some View {
        if hostedInWindowChrome {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.13, green: 0.11, blue: 0.11).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1),
                )
        }
    }
}

private struct OverlayButton: View {
    let title: String
    let compact: Bool

    init(title: String, compact: Bool = false) {
        self.title = title
        self.compact = compact
    }

    var body: some View {
        Text(title)
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.96))
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 8.5 : 10.5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.14)),
            )
    }
}

private struct LevelWaveform: View {
    let level: Float
    let activeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0 ..< OverlayWaveformMetrics.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(activeColor)
                    .frame(
                        width: 2.3,
                        height: OverlayWaveformMetrics.barHeight(for: index, level: level),
                    )
                    .shadow(color: Color.black.opacity(0.34), radius: 1.6, x: 0, y: 0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
