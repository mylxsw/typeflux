import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

enum LiveTranscriptPreviewLayout {
    static let maxVisibleLineCount = 3
    static let lineHeight: CGFloat = 16
    static let textViewportHeight = lineHeight * CGFloat(maxVisibleLineCount)
    static let expandedCapsuleHeight: CGFloat = 103
    static let expandedOverlayHeight: CGFloat = 194
}

enum NoticeToastLayout {
    static let width: CGFloat = 344
    static let maxVisibleLineCount = 3
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

private final class OverlayPanel: NSPanel {
    var allowsKeyboardFocus = false
    var onMouseDown: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool {
        allowsKeyboardFocus
    }

    /// The notch island hangs from the very top of the screen, over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

struct LiquidGlassShapeBackground<S: InsettableShape>: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    let shape: S
    let cornerRadius: CGFloat?

    init(
        shape: S,
        cornerRadius: CGFloat? = nil
    ) {
        self.shape = shape
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        StyledGlassShapeBackground(shape: shape, cornerRadius: cornerRadius,
                                   opaqueFill: interfaceStyle == .classic ? .black : AskTheme.launcherSurface, placement: .floating)
    }
}

/// The native registrations reference this box, never an unretained controller.
/// Cleanup keeps the box alive on the main run loop after its owner is released.
final class OverlayCallbackTarget {
    weak var controller: OverlayController?

    init(_ controller: OverlayController) { self.controller = controller }
}

/// CGEventTap callback — intercepts and consumes keyboard events (Return/Esc/arrows)
/// system-wide so the panel never needs to steal focus from the original app.
private func overlayEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let target = Unmanaged<OverlayCallbackTarget>.fromOpaque(refcon).takeUnretainedValue()
    guard let controller = target.controller else { return Unmanaged.passUnretained(event) }
    return controller.handleEventTapEvent(type: type, event: event)
}

private let overlayPickerSystemKeySignature: OSType = 0x5450_4B59 // TPKY

private func overlayPickerSystemKeyCallback(
    nextHandler _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr, hotkeyID.signature == overlayPickerSystemKeySignature else {
        return noErr
    }

    let target = Unmanaged<OverlayCallbackTarget>.fromOpaque(userData).takeUnretainedValue()
    target.controller?.handlePickerSystemKey(keyCode: Int(hotkeyID.id))
    return noErr
}

struct OverlayFailureAction {
    enum Style: Equatable {
        case primary
        case secondary
        case text
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
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.isRetry = isRetry
        self.style = style
        self.trailingSystemImage = trailingSystemImage
        self.handler = handler
    }
}

enum OverlayFailureTone {
    case error
    case timeout
    case billing
}

final class OverlayController {
    private static let autoDismissDelay: TimeInterval = 6.0
    private static let shadowGutter: CGFloat = 32
    private static let processingStatusLocalizationKey = "overlay.processing.thinking"
    private static let processingProgressRefreshInterval: Duration = .milliseconds(50)

    static func noticeIsInteractive(dismissible: Bool) -> Bool {
        dismissible
    }

    var isShowingPassiveNotice: Bool {
        model.presentation == .notice && !model.noticeDismissible
    }

    var isShowingResultDialogForTesting: Bool {
        model.presentation == .resultDialog
    }

    var processingProgressForTesting: CGFloat {
        model.processingProgress
    }

    var isProcessingProgressActiveForTesting: Bool {
        processingProgressTask?.isCancelled == false
    }

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

    static let recordingWindowBottomInset: CGFloat = 16
    static let recordingContentBottomInset: CGFloat = 42
    static var recordingVisibleBottomInset: CGFloat { recordingWindowBottomInset + recordingContentBottomInset }
    private let appState: AppStateStore
    private let settingsStore: SettingsStore
    private var window: NSPanel?
    var presentedWindow: NSWindow? { window }
    private var interfaceStyleObserver: NSObjectProtocol?
    private var voiceCapsuleObserver: NSObjectProtocol?
    /// The display chosen when the overlay appeared; it stays put until the overlay hides.
    private var placementScreen: VoiceCapsuleScreenGeometry?
    private var hoverWorkItem: DispatchWorkItem?
    private var cardControlsHideWorkItem: DispatchWorkItem?
    private var failureDismissWorkItem: DispatchWorkItem?
    private var keyWindowObserver: NSObjectProtocol?
    private var keyboardCaptureSuspended = false
    var keyboardCaptureSuspendedForTesting: Bool { keyboardCaptureSuspended }
    private var callbackTarget: OverlayCallbackTarget?

    private let model = OverlayViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pickerSystemKeyHandlerRef: EventHandlerRef?
    private var pickerSystemKeyRefs: [Int: EventHotKeyRef] = [:]
    private var lastPositionedFrame: NSRect?
    private var lastPositionedPresentation: OverlayViewModel.Presentation?
    private var pendingFrameAnimationWorkItem: DispatchWorkItem?
    private var frameTransitionID = UUID()
    private var visibilityTransitionID = UUID()
    private var recordingHintAutoHideWorkItem: DispatchWorkItem?
    private var processingProgressTask: Task<Void, Never>?
    private var processingProgressStartedAt: TimeInterval?
    private var contentProcessingStartedElapsed: TimeInterval?
    private var processingProgressTimeline: ProcessingProgressTimeline?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Stretches capsule motion durations so tests can sample intermediate frames deterministically.
    var motionScale: Double {
        get { model.motionScale }
        set { model.motionScale = newValue }
    }

    init(appState: AppStateStore, settingsStore: SettingsStore) {
        self.appState = appState
        self.settingsStore = settingsStore
        model.interfaceStyle = settingsStore.interfaceStyle
        model.glassIntensity = LiquidGlassIntensity(settingsStore.liquidGlassIntensity)
        model.onDismissRequested = { [weak self] in
            self?.dismiss(after: 0)
        }
        interfaceStyleObserver = NotificationCenter.default.addObserver(
            forName: .interfaceStyleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previousStyle = model.interfaceStyle
            model.interfaceStyle = self.settingsStore.interfaceStyle
            model.glassIntensity = LiquidGlassIntensity(self.settingsStore.liquidGlassIntensity)
            if previousStyle != model.interfaceStyle { configureWindowAppearance() }
        }
        voiceCapsuleObserver = NotificationCenter.default.addObserver(
            forName: .voiceCapsuleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, window?.isVisible == true else { return }
            placementScreen = nil
            refreshWindow(preservingDismissal: true)
        }
        model.onCapsuleHoverChanged = { [weak self] hovering in
            self?.handleCapsuleHover(hovering)
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, window?.isVisible == true,
                  let focusedWindow = notification.object as? NSWindow else { return }
            keyboardCaptureSuspended = focusedWindow !== window
            updateKeyMonitoring()
        }
        callbackTarget = OverlayCallbackTarget(self)
    }

    convenience init(appState: AppStateStore) {
        self.init(appState: appState, settingsStore: SettingsStore())
    }

    deinit {
        // Copy resources to locals before cleanup. Calling instance methods from deinit can
        // transiently retain `self` under Swift's ownership lowering and abort destruction.
        // This also makes every AppKit/CoreGraphics registration visibly symmetric.
        let styleObserver = interfaceStyleObserver
        let capsuleObserver = voiceCapsuleObserver
        let focusObserver = keyWindowObserver
        let queuedWork = [
            dismissWorkItem,
            pendingFrameAnimationWorkItem,
            recordingHintAutoHideWorkItem,
            hoverWorkItem,
            cardControlsHideWorkItem
        ]
        let progressTask = processingProgressTask
        let tap = eventTap
        let source = runLoopSource
        let fallbackGlobalMonitor = _fallbackGlobalMonitor
        let fallbackLocalMonitor = _fallbackLocalMonitor
        let mouseOutsideMonitor = _mouseOutsideMonitor
        let systemKeyRefs = Array(pickerSystemKeyRefs.values)
        let systemKeyHandlerRef = pickerSystemKeyHandlerRef
        let target = callbackTarget
        let ownedWindow = window

        queuedWork.forEach { $0?.cancel() }
        progressTask?.cancel()
        let cleanup = {
            // Registration callbacks execute on the main run loop. Retain their
            // weak target box until unregistration has finished on that run loop.
            withExtendedLifetime(target) {
                ownedWindow?.orderOut(nil)
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    if let source {
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    }
                    CFMachPortInvalidate(tap)
                }
                if let fallbackGlobalMonitor { NSEvent.removeMonitor(fallbackGlobalMonitor) }
                if let fallbackLocalMonitor { NSEvent.removeMonitor(fallbackLocalMonitor) }
                if let mouseOutsideMonitor { NSEvent.removeMonitor(mouseOutsideMonitor) }
                systemKeyRefs.forEach { UnregisterEventHotKey($0) }
                if let systemKeyHandlerRef { RemoveEventHandler(systemKeyHandlerRef) }
                if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
                if let capsuleObserver { NotificationCenter.default.removeObserver(capsuleObserver) }
                if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
            }
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
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
        onCancel: (() -> Void)?
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

    @MainActor
    func prepareRecordingPresentation() {
        ensureWindow()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    var recordingPresentationForTesting: OverlayViewModel.Presentation { model.presentation }

    func show(hintText: String? = nil, autoHideHintAfter: TimeInterval? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(hintText: hintText, autoHideHintAfter: autoHideHintAfter)
            }
            return
        }
        stopProcessingProgress()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        cancelRecordingHintAutoHide()
        ensureWindow()
        beginCapsuleSessionIfNeeded()
        model.presentation = .recordingHold
        model.recordingPreviewExpanded = false
        model.statusText = L("overlay.recording.listening")
        model.detailText = ""
        model.recordingHintText = hintText ?? ""
        model.processingProgress = 0
        refreshWindow()
        RecordingStartupLatencyTrace.shared.mark("ui.recording_ordered_front", logSummary: true)
        scheduleRecordingHintAutoHideIfNeeded(after: autoHideHintAfter, expectedText: hintText)
    }

    private func ensureWindow() {
        if window == nil {
            let view = OverlayView(model: model)
            let hosting = TransparentHostingView(rootView: view)
            // The controller owns panel geometry, including temporary animation space.
            hosting.sizingOptions = []
            hosting.wantsLayer = true
            hosting.layer?.isOpaque = false
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            let metrics = metrics(for: .recordingHold)
            let panel = OverlayPanel(
                contentRect: NSRect(origin: .zero, size: metrics.size),
                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level.statusBar
            panel.backgroundColor = NSColor.clear
            panel.hasShadow = false
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [
                NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.transient
            ]
            panel.contentView = hosting
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.isOpaque = false
            panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            panel.onMouseDown = { [weak self] in
                self?.keyboardCaptureSuspended = false
                self?.updateKeyMonitoring()
            }

            window = panel
        }
    }

    func showLockedRecording(hintText: String? = nil, autoHideHintAfter: TimeInterval? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showLockedRecording(hintText: hintText, autoHideHintAfter: autoHideHintAfter)
            }
            return
        }
        stopProcessingProgress()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        cancelRecordingHintAutoHide()
        ensureWindow()
        beginCapsuleSessionIfNeeded()
        keyboardCaptureSuspended = false
        model.presentation = .recordingLocked
        model.recordingPreviewExpanded = false
        model.recordingHintText = hintText ?? ""
        refreshWindow()
        scheduleRecordingHintAutoHideIfNeeded(after: autoHideHintAfter, expectedText: hintText)
    }

    func updateRecordingPreviewText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateRecordingPreviewText(text) }
            return
        }

        guard model.presentation.isRecording,
              dismissWorkItem == nil, window?.isVisible == true else { return }
        let expanded = settingsStore.voiceCapsule.showsLivePreview
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Keep the last text mounted while it fades out during collapse.
        if expanded { model.detailText = text }
        model.recordingPreviewExpanded = expanded
        model.presentation = model.presentation.showsRecordingControls
            ? (expanded ? .recordingLockedPreview : .recordingLocked)
            : (expanded ? .recordingHoldPreview : .recordingHold)
        refreshWindow()
    }

    func showProcessing(timeout: TimeInterval = 120) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showProcessing(timeout: timeout) }
            return
        }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        startProcessingProgress(timeout: timeout)
        showProcessingImmediately()
    }

    private func showProcessingImmediately() {
        ensureWindow()
        model.presentation = .processing
        model.recordingPreviewExpanded = false
        model.statusText = L(Self.processingStatusLocalizationKey)
        model.recordingHintText = ""
        cancelRecordingHintAutoHide()
        refreshWindow()
    }

    func showLLMProcessing(timeout: TimeInterval = 120) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showLLMProcessing(timeout: timeout) }
            return
        }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        ensureWindow()
        model.presentation = .processing
        model.recordingPreviewExpanded = false
        model.statusText = L(Self.processingStatusLocalizationKey)
        model.recordingHintText = ""
        cancelRecordingHintAutoHide()
        startProcessingProgress(timeout: timeout, contentProcessingAlreadyStarted: true)
        refreshWindow()
    }

    func transitionToLLMPhase(timeout: TimeInterval? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.transitionToLLMPhase(timeout: timeout) }
            return
        }
        var shouldRefresh = false
        if model.presentation.isRecordingPreview { showProcessingImmediately() }
        guard model.presentation.isProcessing else { return }
        if contentProcessingStartedElapsed == nil,
           let startedAt = processingProgressStartedAt {
            contentProcessingStartedElapsed = ProcessInfo.processInfo.systemUptime - startedAt
            model.processingProgress = ProcessingProgressTimeline.recognitionCompleteProgress
        }
        if let timeout {
            startProcessingProgress(timeout: timeout, contentProcessingAlreadyStarted: true)
        }
        if model.statusText.isEmpty {
            model.statusText = L(Self.processingStatusLocalizationKey)
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
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureTone = .error
        model.failureActions = []
        startFailureCountdown()
        refreshWindow()
    }

    func showRetryableFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showRetryableFailure(message: message) }
            return
        }
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureTone = .error
        model.failureActions = wrapFailureActions([
            OverlayFailureAction(
                title: L("common.retry"),
                isRetry: true,
                handler: { [weak self] in self?.model.onFailureRetryHandler?() }
            )
        ])
        startFailureCountdown()
        refreshWindow()
    }

    func showTimeoutFailure(timeoutSeconds: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showTimeoutFailure(timeoutSeconds: timeoutSeconds)
            }
            return
        }
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.timeout.title")
        model.detailText = L("overlay.timeout.message", timeoutSeconds)
        model.failureTone = .timeout
        model.failureActions = wrapFailureActions([
            OverlayFailureAction(
                title: L("common.retry"),
                isRetry: true,
                handler: { [weak self] in self?.model.onFailureRetryHandler?() }
            )
        ])
        startFailureCountdown()
        refreshWindow()
    }

    func showFailureWithActions(
        title: String = L("overlay.failure.title"),
        message: String,
        tone: OverlayFailureTone = .error,
        actions: [OverlayFailureAction]
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showFailureWithActions(
                    title: title,
                    message: message,
                    tone: tone,
                    actions: actions
                )
            }
            return
        }
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.presentation = .failure
        model.statusText = title
        model.detailText = message
        model.failureTone = tone
        model.failureActions = wrapFailureActions(actions)
        startFailureCountdown()
        refreshWindow()
    }

    static func wrapFailureActions(
        _ actions: [OverlayFailureAction],
        beforeAction: @escaping () -> Void
    ) -> [OverlayFailureAction] {
        actions.map { action in
            OverlayFailureAction(
                title: action.title,
                isRetry: action.isRetry,
                style: action.style,
                trailingSystemImage: action.trailingSystemImage,
                handler: {
                    beforeAction()
                    action.handler()
                }
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
        if model.presentation.isProcessing {
            guard window?.isVisible == true, dismissWorkItem == nil else { return }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.presentation.isProcessing || !trimmed.isEmpty { model.detailText = text }
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
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.noticeDismissible = true
        model.presentation = .notice
        model.statusText = L("overlay.notice.title")
        model.detailText = message
        refreshWindow()
        dismiss(after: Self.autoDismissDelay)
    }

    func showPassiveNotice(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showPassiveNotice(message: message) }
            return
        }
        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        model.noticeDismissible = false
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
        dismissWorkItem?.cancel()
        stopProcessingProgress()
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
        icon: PersonaPickerIcon
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showPersonaPicker(
                    items: items, selectedIndex: selectedIndex, title: title,
                    instructions: instructions, icon: icon
                )
            }
            return
        }

        dismissWorkItem?.cancel()
        stopProcessingProgress()
        ensureWindow()
        keyboardCaptureSuspended = false
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

        if model.presentation.isProcessing {
            stopProcessingProgress(resetProgress: false)
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
            visibilityTransitionID = UUID()
            stopProcessingProgress()
            hideWindowAndResetState()
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
        stopProcessingProgress(resetProgress: false)
        if model.presentation == .failure, delay > 0 {
            return
        }
        dismissWorkItem?.cancel()
        visibilityTransitionID = UUID()
        let transitionID = visibilityTransitionID
        let workItem = DispatchWorkItem { [weak self] in
            self?.beginDismissal(transitionID: transitionID)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func beginDismissal(transitionID: UUID) {
        guard visibilityTransitionID == transitionID else { return }
        cancelRecordingHintAutoHide()
        removeKeyMonitoring()
        removePickerSystemKeyCapture()
        removeMouseMonitoring()
        window?.ignoresMouseEvents = true
        guard model.presentation.isCapsule, !reduceMotion, window?.isVisible == true else {
            hideWindowAndResetState()
            return
        }
        withAnimation(OverlayMotion.dismissal(scale: model.motionScale)) { model.isPresented = false }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, visibilityTransitionID == transitionID else { return }
            hideWindowAndResetState()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayMotion.dismissalDuration * model.motionScale, execute: workItem)
    }

    private func hideWindowAndResetState() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        pendingFrameAnimationWorkItem?.cancel()
        pendingFrameAnimationWorkItem = nil
        frameTransitionID = UUID()
        cancelRecordingHintAutoHide()
        window?.orderOut(nil)
        keyboardCaptureSuspended = false
        lastPositionedFrame = nil
        lastPositionedPresentation = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isPresented = false }
        model.detailText = ""
        model.recordingHintText = ""
        model.level = 0
        model.processingProgress = 0
        model.recordingStartedAt = nil
        model.capsuleHovered = false
        model.cardControlsRevealed = false
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        cardControlsHideWorkItem?.cancel()
        cardControlsHideWorkItem = nil
        cancelFailureCountdown()
        placementScreen = nil
        removeKeyMonitoring()
        removePickerSystemKeyCapture()
        removeMouseMonitoring()
    }

    private func scheduleRecordingHintAutoHideIfNeeded(after delay: TimeInterval?, expectedText: String?) {
        guard let delay, delay > 0, let expectedText, !expectedText.isEmpty else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearRecordingHintText(expectedText: expectedText)
        }
        recordingHintAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startProcessingProgress(
        timeout: TimeInterval,
        contentProcessingAlreadyStarted: Bool = false
    ) {
        stopProcessingProgress()
        processingProgressStartedAt = ProcessInfo.processInfo.systemUptime
        contentProcessingStartedElapsed = contentProcessingAlreadyStarted ? 0 : nil
        processingProgressTimeline = ProcessingProgressTimeline(timeout: timeout)
        model.processingProgress = contentProcessingAlreadyStarted
            ? ProcessingProgressTimeline.recognitionCompleteProgress
            : ProcessingProgressTimeline.initialProgress
        processingProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.processingProgressRefreshInterval)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.updateProcessingProgress()
                }
            }
        }
    }

    private func updateProcessingProgress() {
        guard let startedAt = processingProgressStartedAt,
              let timeline = processingProgressTimeline
        else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        model.processingProgress = timeline.progress(
            elapsed: elapsed,
            contentProcessingStartedAt: contentProcessingStartedElapsed
        )
    }

    private func stopProcessingProgress(resetProgress: Bool = true) {
        processingProgressTask?.cancel()
        processingProgressTask = nil
        processingProgressStartedAt = nil
        contentProcessingStartedElapsed = nil
        processingProgressTimeline = nil
        if resetProgress {
            model.processingProgress = 0
        }
    }

    private func cancelRecordingHintAutoHide() {
        recordingHintAutoHideWorkItem?.cancel()
        recordingHintAutoHideWorkItem = nil
    }

    private func clearRecordingHintText(expectedText: String) {
        guard model.recordingHintText == expectedText else { return }
        switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview:
            model.recordingHintText = ""
            refreshWindow()
        default:
            break
        }
    }

    private func refreshWindow(preservingDismissal: Bool = false) {
        guard let window else { return }
        // Preference synchronization updates geometry without extending a notice's lifetime.
        if !preservingDismissal {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            visibilityTransitionID = UUID()
        }
        let transitionID = visibilityTransitionID
        if let panel = window as? OverlayPanel {
            panel.allowsKeyboardFocus = model.presentation.acceptsKeyboardFocus
            if panel.isKeyWindow, !panel.allowsKeyboardFocus {
                panel.orderOut(nil)
            }
        }
        let wasVisible = window.isVisible
        resolvePlacement(windowVisible: wasVisible)
        positionWindow()
        configureWindowAppearance()
        // Always use orderFrontRegardless — never makeKeyAndOrderFront.
        // Stealing key window status from the original app causes it to lose
        // focus and selection, which breaks write-back after LLM processing.
        if !wasVisible, model.presentation.isCapsule, !reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.isPresented = false }
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            window.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, visibilityTransitionID == transitionID else { return }
                withAnimation(OverlayMotion.appearance(scale: self.model.motionScale)) { self.model.isPresented = true }
            }
        } else {
            window.orderFrontRegardless()
            if !model.isPresented {
                withAnimation(reduceMotion ? nil : OverlayMotion.appearance(scale: model.motionScale)) { model.isPresented = true }
            }
        }
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
            contentView.layer?.borderWidth = 0
            contentView.layer?.borderColor = nil
        } else {
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = 0
            contentView.layer?.masksToBounds = false
            contentView.layer?.borderWidth = 0
            contentView.layer?.borderColor = nil
        }
    }

    private func windowChrome(for presentation: OverlayViewModel.Presentation) -> WindowChromeStyle? {
        if model.drawsVoiceCapsuleSkin { return nil }
        let background = model.interfaceStyle == .classic
            ? NSColor.black
            : NSColor.clear

        switch presentation {
        case .transcriptPreview, .notice:
            return WindowChromeStyle(background: background, cornerRadius: 14)
        case .resultDialog:
            // The result card draws its own surface in SwiftUI in every interface style.
            return nil
        default:
            return nil
        }
    }

    private func positionWindow() {
        guard let window, let screen = placementScreen ?? NSScreen.main.map(VoiceCapsuleScreenGeometry.init(screen:))
        else { return }
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
        case .voiceCapsule:
            let origin = VoiceCapsuleLayout.windowOrigin(windowSize: metrics.size, skin: model.skin, screen: screen)
            x = origin.x
            y = origin.y
        case .belowCapsule:
            // Notices follow a top skin: below the menu bar, under the island or in the card's corner.
            y = frame.maxY - metrics.offset - metrics.size.height
            switch model.skin {
            case .cornerCard(.trailing): x = frame.maxX - VoiceCapsuleLayout.cardEdgeInset - metrics.size.width
            case .cornerCard(.leading): x = frame.minX + VoiceCapsuleLayout.cardEdgeInset
            case let .notchIsland(notch): x = notch.midX - metrics.size.width / 2
            case .bottomCapsule, .orbCapsule: x = frame.midX - metrics.size.width / 2
            }
        }

        let contentRect = NSRect(origin: NSPoint(x: x, y: y), size: metrics.size)
        let targetFrame = window.frameRect(forContentRect: contentRect)
        let previousPresentation = lastPositionedPresentation
        let previousFrame = lastPositionedFrame
        let shouldAnimate = model.presentation != .notice
            && !reduceMotion
            && window.isVisible
            && previousFrame != nil
            && targetFrame != previousFrame

        window.ignoresMouseEvents = !metrics.interactive
        // Text updates must not restart an in-flight resize or postpone its cleanup.
        if window.isVisible, targetFrame == previousFrame {
            lastPositionedPresentation = model.presentation
            return
        }

        pendingFrameAnimationWorkItem?.cancel()
        pendingFrameAnimationWorkItem = nil
        frameTransitionID = UUID()
        let transitionID = frameTransitionID

        if shouldAnimate, previousPresentation?.isCapsule == true, model.presentation.isCapsule {
            // Reserve space immediately, then let the persistent SwiftUI capsule
            // perform the only visible resize. Reclaim space after it has settled.
            let envelope = window.frame.union(targetFrame)
            window.setFrame(envelope, display: true)
            let workItem = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, frameTransitionID == transitionID else { return }
                window.setFrame(targetFrame, display: true)
                pendingFrameAnimationWorkItem = nil
            }
            pendingFrameAnimationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + OverlayMotion.geometrySettleDelay(scale: model.motionScale), execute: workItem)
        } else if shouldAnimate {
            animateWindow(window, to: targetFrame, duration: 0.28)
        } else {
            window.setFrame(targetFrame, display: true)
        }
        lastPositionedFrame = targetFrame
        lastPositionedPresentation = model.presentation
    }

    // MARK: - Voice capsule skins

    /// Starts the timer and remembers the target app when a new recording session begins.
    private func beginCapsuleSessionIfNeeded() {
        if window?.isVisible == true, model.presentation.isRecording, dismissWorkItem == nil { return }
        model.recordingStartedAt = Date()
        model.capsuleHovered = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isTypeflux = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        model.targetAppName = settingsStore.voiceCapsule.showsTargetApp && !isTypeflux ? frontmost?.localizedName : nil
    }

    /// Chooses the display once per appearance and applies the notch fallback for it.
    private func resolvePlacement(windowVisible: Bool) {
        let preferences = settingsStore.voiceCapsule
        if !windowVisible || placementScreen == nil {
            placementScreen = Self.placementScreenGeometry(for: preferences.screen)
        }
        guard let screen = placementScreen else { return }
        let skin = VoiceCapsuleLayout.skin(for: preferences, on: screen)
        guard skin != model.skin else { return }
        // Jump to the new anchor; morphing between anchors would sweep an envelope across the screen.
        lastPositionedFrame = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.skin = skin }
    }

    static func placementScreenGeometry(for choice: VoiceCapsuleScreenChoice) -> VoiceCapsuleScreenGeometry? {
        let screens = NSScreen.screens
        let activeIndex = NSScreen.main.flatMap { main in screens.firstIndex { $0 == main } }
        guard let index = VoiceCapsuleLayout.screenIndex(
            for: choice, frames: screens.map(\.frame), mouseLocation: NSEvent.mouseLocation, activeIndex: activeIndex
        ) else { return nil }
        return VoiceCapsuleScreenGeometry(screen: screens[index])
    }

    private func voiceCapsuleMetrics(for presentation: OverlayViewModel.Presentation) -> OverlayMetrics? {
        let skin = model.skin
        switch presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview,
             .processing, .processingPreview:
            let content = VoiceCapsuleLayout.contentSize(
                for: skin, sizeClass: model.voiceCapsuleExpanded ? .expanded : .compact,
                transcriptLines: model.voiceCapsuleTranscriptLines
            )
            return OverlayMetrics(
                size: VoiceCapsuleLayout.windowSize(contentSize: content, skin: skin),
                anchor: .voiceCapsule, offset: 0,
                // Recording accepts the pointer for hover; the corner card also offers cancel while processing.
                interactive: presentation.isRecording || (presentation.isProcessing && skin.isCornerCard)
            )
        case .failure:
            let measured = NSHostingView(rootView: OverlayView(model: model)).fittingSize
            return OverlayMetrics(size: NSSize(width: ceil(measured.width), height: ceil(measured.height)),
                                  anchor: .voiceCapsule, offset: 0, interactive: true)
        case .notice, .transcriptPreview:
            let measured = NSHostingView(rootView: OverlayView(model: model)).fittingSize
            return OverlayMetrics(
                size: NSSize(width: ceil(measured.width), height: ceil(measured.height)),
                anchor: .belowCapsule, offset: VoiceCapsuleLayout.cardTopSpacing,
                interactive: presentation == .notice && Self.noticeIsInteractive(dismissible: model.noticeDismissible)
            )
        case .personaPicker, .resultDialog:
            return nil
        }
    }

    static let cardControlsHideDelay: TimeInterval = 0.25

    private func handleCapsuleHover(_ hovering: Bool) {
        if model.presentation == .failure {
            pauseFailureCountdown(hovering)
            return
        }
        if model.skin.isCornerCard || model.skin == .orbCapsule {
            revealCardControls(hovering)
            return
        }
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        let supportsHover = switch model.skin {
        case .notchIsland: settingsStore.voiceCapsule.notchHoverExpands
        case .cornerCard, .bottomCapsule, .orbCapsule: false
        }
        guard !hovering || supportsHover else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, model.capsuleHovered != hovering else { return }
            guard !hovering || model.presentation.isRecording else { return }
            model.capsuleHovered = hovering
            // Never resurrect an overlay that is already on its way out.
            if model.presentation.isRecording, dismissWorkItem == nil, window?.isVisible == true {
                refreshWindow()
            }
        }
        hoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? 0.15 : 0.4), execute: workItem)
    }

    /// The corner card keeps its size on hover; the pointer only reveals its controls.
    /// They appear at once and linger briefly after the pointer leaves, so a pass across does not flicker.
    private func revealCardControls(_ hovering: Bool) {
        cardControlsHideWorkItem?.cancel()
        cardControlsHideWorkItem = nil
        if hovering {
            model.cardControlsRevealed = true
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.model.cardControlsRevealed = false
            self?.cardControlsHideWorkItem = nil
        }
        cardControlsHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardControlsHideDelay, execute: workItem)
    }

    var cardControlsRevealedForTesting: Bool { model.cardControlsRevealed }

    /// How long a failure without actions stays; tests shorten it.
    var failureAutoDismissDelay: TimeInterval = 6

    /// A failure without actions leaves on its own after a while; one with actions waits for the user.
    private func startFailureCountdown() {
        cancelFailureCountdown()
        guard model.failureActions.isEmpty else { return }
        model.failureCountdown = OverlayFailureCountdown(total: failureAutoDismissDelay, startedAt: Date())
        scheduleFailureDismissal(after: failureAutoDismissDelay)
    }

    private func scheduleFailureDismissal(after delay: TimeInterval) {
        failureDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            failureDismissWorkItem = nil
            guard model.presentation == .failure, model.failureCountdown?.isPaused == false else { return }
            dismiss(after: 0)
        }
        failureDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelFailureCountdown() {
        failureDismissWorkItem?.cancel()
        failureDismissWorkItem = nil
        model.failureCountdown = nil
    }

    /// The pointer over the card stops the countdown; leaving resumes it where it stopped.
    private func pauseFailureCountdown(_ hovering: Bool) {
        guard let countdown = model.failureCountdown else { return }
        let now = Date()
        if hovering {
            failureDismissWorkItem?.cancel()
            failureDismissWorkItem = nil
            model.failureCountdown = countdown.paused(at: now)
        } else if countdown.isPaused {
            model.failureCountdown = countdown.resumed(at: now)
            scheduleFailureDismissal(after: countdown.remaining)
        }
    }

    var failureCountdownForTesting: OverlayFailureCountdown? { model.failureCountdown }

    var voiceCapsuleSkinForTesting: VoiceCapsuleSkin { model.skin }
    var isCapsulePresentedForTesting: Bool { model.isPresented }

    func simulateCapsuleHoverForTesting(_ hovering: Bool) {
        handleCapsuleHover(hovering)
    }

    private func animateWindow(_ window: NSWindow, to targetFrame: NSRect, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    /// Only the orb capsule reveals controls on hover; the original capsule keeps ignoring the pointer
    /// until hands-free recording shows its buttons.
    private var revealsControlsOnHover: Bool { model.skin == .orbCapsule }

    private func metrics(for presentation: OverlayViewModel.Presentation) -> OverlayMetrics {
        if model.skin.isTopAnchored, let metrics = voiceCapsuleMetrics(for: presentation) {
            return metrics
        }
        switch presentation {
        case .recordingHold:
            return OverlayMetrics(
                size: recordingOverlaySize(baseWidth: 146, baseHeight: 112), anchor: .bottom, offset: Self.recordingWindowBottomInset,
                // The orb capsule accepts the pointer so hovering can reveal cancel and confirm.
                interactive: revealsControlsOnHover
            )
        case .recordingHoldPreview:
            let isExpanded = model.recordingPreviewExpanded
            return OverlayMetrics(
                size: recordingOverlaySize(
                    baseWidth: isExpanded ? 428 : 146,
                    baseHeight: isExpanded ? LiveTranscriptPreviewLayout.expandedOverlayHeight : 112
                ), anchor: .bottom, offset: Self.recordingWindowBottomInset,
                interactive: revealsControlsOnHover
            )
        case .recordingLocked:
            return OverlayMetrics(
                size: recordingOverlaySize(baseWidth: 196, baseHeight: 120), anchor: .bottom, offset: Self.recordingWindowBottomInset,
                interactive: true
            )
        case .recordingLockedPreview:
            let isExpanded = model.recordingPreviewExpanded
            return OverlayMetrics(
                size: recordingOverlaySize(
                    baseWidth: isExpanded ? 428 : 196,
                    baseHeight: isExpanded ? LiveTranscriptPreviewLayout.expandedOverlayHeight : 120
                ), anchor: .bottom, offset: Self.recordingWindowBottomInset,
                interactive: true
            )
        case .processing:
            return OverlayMetrics(
                size: NSSize(width: processingOverlayWidth() + Self.shadowGutter * 2, height: 112), anchor: .bottom,
                offset: Self.recordingWindowBottomInset,
                interactive: revealsControlsOnHover
            )
        case .processingPreview:
            return OverlayMetrics(
                size: NSSize(width: 428, height: LiveTranscriptPreviewLayout.expandedOverlayHeight),
                anchor: .bottom, offset: Self.recordingWindowBottomInset,
                interactive: revealsControlsOnHover
            )
        case .transcriptPreview, .notice, .failure, .personaPicker, .resultDialog:
            // Every non-capsule presentation owns its height through its content.
            // Keep native sizing disabled: capsule transitions still own their
            // animated envelope, and scroll views retain their explicit limits.
            let measured = NSHostingView(rootView: OverlayView(model: model)).fittingSize
            let offset: CGFloat = switch presentation {
            case .personaPicker, .resultDialog: 36
            // The failure card rises out of the capsule, so it shares the capsule's window inset.
            case .failure: Self.recordingWindowBottomInset
            default: 80
            }
            return OverlayMetrics(
                size: NSSize(width: ceil(measured.width), height: ceil(measured.height)),
                anchor: presentation == .personaPicker ? .center : .bottom,
                offset: offset,
                interactive: presentation != .transcriptPreview
                    && (presentation != .notice || Self.noticeIsInteractive(dismissible: model.noticeDismissible))
            )
        }
    }

    private func recordingOverlaySize(baseWidth: CGFloat, baseHeight: CGFloat) -> NSSize {
        guard !model.recordingHintText.isEmpty else {
            return NSSize(width: baseWidth, height: baseHeight)
        }

        let hint = RecordingHintLayout(text: model.recordingHintText)
        return NSSize(
            width: max(baseWidth, hint.size.width + RecordingHintLayout.containerInset * 2),
            height: baseHeight + hint.size.height + RecordingHintLayout.spacing
        )
    }

    private func processingOverlayWidth() -> CGFloat {
        let title = model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText
        return OverlayMotion.processingWidth(for: title)
    }

    private func updateKeyMonitoring() {
        if keyboardCaptureSuspended {
            removePickerSystemKeyCapture()
            removeKeyMonitoring()
            return
        }
        if model.presentation == .personaPicker {
            installPickerSystemKeyCaptureIfNeeded()
            if pickerSystemKeyRefs.isEmpty {
                installKeyMonitoringIfNeeded()
            } else {
                removeKeyMonitoring()
            }
        } else if model.presentation == .recordingLocked
            || model.presentation == .recordingLockedPreview
            || model.presentation == .failure
            || model.presentation == .resultDialog {
            removePickerSystemKeyCapture()
            installKeyMonitoringIfNeeded()
        } else {
            removePickerSystemKeyCapture()
            removeKeyMonitoring()
        }

        if model.presentation == .personaPicker {
            installMouseMonitoringIfNeeded()
        } else {
            removeMouseMonitoring()
        }
    }

    private func installPickerSystemKeyCaptureIfNeeded() {
        guard pickerSystemKeyRefs.isEmpty else { return }
        installPickerSystemKeyHandlerIfNeeded()
        guard pickerSystemKeyHandlerRef != nil else { return }

        for keyCode in [53, 125, 126, 36, 76] {
            let hotkeyID = EventHotKeyID(signature: overlayPickerSystemKeySignature, id: UInt32(keyCode))
            var hotkeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                0,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )
            if status == noErr, let hotkeyRef {
                pickerSystemKeyRefs[keyCode] = hotkeyRef
            } else {
                ErrorLogStore.shared.log("Overlay: failed to register picker system key \(keyCode), status \(status)")
            }
        }
    }

    private func installPickerSystemKeyHandlerIfNeeded() {
        guard pickerSystemKeyHandlerRef == nil, let callbackTarget else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(callbackTarget).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            overlayPickerSystemKeyCallback,
            1,
            &eventType,
            userData,
            &pickerSystemKeyHandlerRef
        )
        if status != noErr {
            ErrorLogStore.shared.log("Overlay: failed to install picker system key handler, status \(status)")
        }
    }

    private func removePickerSystemKeyCapture() {
        for ref in pickerSystemKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        pickerSystemKeyRefs = [:]
    }

    private func installKeyMonitoringIfNeeded() {
        guard eventTap == nil, let callbackTarget else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(callbackTarget).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: overlayEventTapCallback,
                userInfo: selfPtr
            )
        else {
            NSLog(
                "[OverlayController] Failed to create CGEventTap — falling back to NSEvent monitors"
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
            matching: [.leftMouseDown, .rightMouseDown]
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

    fileprivate func handlePickerSystemKey(keyCode: Int) {
        DispatchQueue.main.async { [weak self] in
            _ = self?.handleKeyCode(keyCode)
        }
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
        guard !keyboardCaptureSuspended else { return false }
        if model.presentation == .recordingHold || model.presentation == .recordingHoldPreview || model
            .presentation == .recordingLocked || model.presentation == .recordingLockedPreview {
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
        /// A top skin's own placement (`VoiceCapsuleLayout.windowOrigin`).
        case voiceCapsule
        /// Toasts below the menu bar, aligned with the current top skin.
        case belowCapsule
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

        var isRecording: Bool {
            self == .recordingHold || self == .recordingLocked || isRecordingPreview
        }

        var showsRecordingControls: Bool {
            self == .recordingLocked || self == .recordingLockedPreview
        }

        var isCapsule: Bool { isRecording || isProcessing }

        var isProcessing: Bool {
            self == .processing || self == .processingPreview
        }

        /// Pickers use the existing system key capture. Mouse clicks must not
        /// take keyboard focus (and selection) away from the source editor.
        var acceptsKeyboardFocus: Bool { self == .resultDialog }
    }

    @Published var presentation: Presentation = .recordingHold
    @Published var isPresented = false
    @Published var statusText: String = ""
    @Published var detailText: String = ""
    @Published var recordingHintText: String = ""
    @Published var recordingPreviewExpanded: Bool = false
    @Published var level: Float = 0
    @Published var processingProgress: CGFloat = 0
    @Published var personaItems: [OverlayController.PersonaPickerItem] = []
    @Published var personaSelectedIndex: Int = 0
    @Published var personaViewportHeight: CGFloat = 240
    @Published var personaPickerIcon: OverlayController.PersonaPickerIcon = .none
    @Published var failureActions: [OverlayFailureAction] = []
    @Published var failureTone: OverlayFailureTone = .error
    @Published var failureCountdown: OverlayFailureCountdown?
    @Published var noticeDismissible = true
    @Published var interfaceStyle: InterfaceStyle = .liquidGlass
    @Published var glassIntensity = LiquidGlassIntensity()
    @Published var skin: VoiceCapsuleSkin = .bottomCapsule
    @Published var targetAppName: String?
    @Published var recordingStartedAt: Date?
    @Published var capsuleHovered = false
    /// The pointer is over the corner card, so its cancel/confirm controls are shown.
    @Published var cardControlsRevealed = false
    var onCapsuleHoverChanged: ((Bool) -> Void)?
    /// Stretches capsule motion durations; only rendering tests set it above 1.
    var motionScale: Double = 1
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if usesWindowChrome {
                content
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
                    .padding(containerPadding)
            }
        }
        .scaleEffect(isHiddenCapsule && !reduceMotion ? 0.96 : 1, anchor: model.skin.isTopAnchored ? .top : .bottom)
        .offset(y: isHiddenCapsule && !reduceMotion ? (model.skin.isTopAnchored ? -6 : 6) : 0)
        .opacity(isHiddenCapsule ? 0 : 1)
        .environment(\.interfaceStyle, model.interfaceStyle)
        .environment(\.liquidGlassIntensity, model.glassIntensity)
        .environment(\.overlayAnimationsActive, model.isPresented)
    }

    private var isHiddenCapsule: Bool { model.presentation.isCapsule && !model.isPresented }

    @ViewBuilder
    private var content: some View {
        if model.drawsVoiceCapsuleSkin, let snapshot = model.voiceCapsuleSnapshot {
            voiceCapsuleSkin(snapshot)
        } else {
            sharedContent
        }
    }

    @ViewBuilder
    private func voiceCapsuleSkin(_ snapshot: VoiceCapsuleSnapshot) -> some View {
        Group {
            switch model.skin {
            case .cornerCard:
                CornerCardCapsule(snapshot: snapshot, actions: model.voiceCapsuleActions)
            case let .notchIsland(notch):
                NotchIslandCapsule(snapshot: snapshot, notch: notch, actions: model.voiceCapsuleActions)
            case .bottomCapsule, .orbCapsule:
                EmptyView()
            }
        }
        .fixedSize(horizontal: true, vertical: snapshot.phase == .failure)
        .onHover { model.onCapsuleHoverChanged?($0) }
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: snapshot.showsBody)
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: snapshot.phase)
        // A caption that wraps onto another line grows the skin smoothly too.
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: snapshot.transcriptLines)
    }

    @ViewBuilder
    private var sharedContent: some View {
        switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview,
             .processing, .processingPreview:
            // Keep one structural identity while captions and controls change.
            recordingMorphCapsule(
                expanded: model.presentation.isRecording
                    ? model.recordingPreviewExpanded : model.presentation == .processingPreview
            )
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

    private var usesWindowChrome: Bool {
        if model.drawsVoiceCapsuleSkin { return false }
        switch model.presentation {
        case .transcriptPreview, .notice, .personaPicker, .resultDialog:
            return true
        default:
            return false
        }
    }

    private var contentAlignment: Alignment {
        if model.drawsVoiceCapsuleSkin { return .top }
        return switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview,
             .processing, .processingPreview, .notice, .transcriptPreview, .failure, .personaPicker, .resultDialog:
            .bottom
        }
    }

    private var containerPadding: EdgeInsets {
        if model.drawsVoiceCapsuleSkin {
            let gutter = VoiceCapsuleLayout.gutter(for: model.skin)
            return EdgeInsets(top: gutter.top, leading: gutter.left, bottom: gutter.bottom, trailing: gutter.right)
        }
        return switch model.presentation {
        case .recordingHold, .recordingLocked, .processing,
             .recordingHoldPreview, .recordingLockedPreview, .processingPreview:
            EdgeInsets(
                top: model.presentation.isRecordingPreview || model.presentation == .processingPreview ? 30 : 28,
                leading: RecordingHintLayout.containerInset,
                bottom: OverlayController.recordingContentBottomInset,
                trailing: RecordingHintLayout.containerInset
            )
        case .transcriptPreview, .notice:
            EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        case .failure:
            // The card's bottom sits where the capsule's was; the rest leaves room for its shadow.
            EdgeInsets(top: 24, leading: 28, bottom: OverlayController.recordingContentBottomInset, trailing: 28)
        case .personaPicker, .resultDialog:
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
    }

    @ViewBuilder
    private func recordingMorphCapsule(expanded: Bool) -> some View {
        if model.skin == .orbCapsule {
            orbRecordingCapsule(expanded: expanded)
        } else {
            classicRecordingCapsule(expanded: expanded, showControls: model.presentation.showsRecordingControls)
        }
    }

    @ViewBuilder
    private func orbRecordingCapsule(expanded: Bool) -> some View {
        if let snapshot = model.voiceCapsuleSnapshot {
            let revealed = model.cardControlsRevealed && !snapshot.phase.cardControls.isEmpty
            OrbRecordingCapsule(
                snapshot: snapshot,
                hintText: model.recordingHintText,
                expanded: expanded,
                controlsRevealed: revealed,
                actions: model.voiceCapsuleActions
            )
            .fixedSize(horizontal: true, vertical: true)
            .onHover { model.onCapsuleHoverChanged?($0) }
            .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: expanded)
            .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: revealed)
            .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: snapshot.phase)
        }
    }

    private func classicRecordingCapsule(expanded: Bool, showControls: Bool) -> some View {
        MorphingRecordingCapsule(
            text: model.detailText,
            hintText: model.recordingHintText,
            level: model.level,
            expanded: expanded,
            showControls: showControls,
            isProcessing: model.presentation.isProcessing,
            processingTitle: model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText,
            processingProgress: model.processingProgress,
            onCancel: model.requestCancel,
            onConfirm: model.requestConfirm
        )
        .fixedSize(horizontal: true, vertical: true)
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: expanded)
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: showControls)
        .animation(reduceMotion ? nil : OverlayMotion.morph(scale: model.motionScale), value: model.presentation.isProcessing)
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
        OverlayFailureCard(
            title: model.statusText,
            message: model.detailText,
            tone: model.failureTone,
            actions: model.failureActions,
            countdown: model.failureCountdown,
            onAction: model.requestFailureAction(at:),
            onDismiss: model.requestDismiss
        )
        .onHover { model.onCapsuleHoverChanged?($0) }
    }

    private var noticeToast: some View {
        OverlayCompactToast(width: NoticeToastLayout.width, hostedInWindowChrome: true) {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(
                    icon: "info.circle",
                    accent: StudioTheme.accent,
                    title: model.statusText,
                    dismissible: model.noticeDismissible,
                    titleSize: 13.5
                )

                Text(model.detailText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(NoticeToastLayout.maxVisibleLineCount)
            }
        }
    }

    private var personaPickerCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return VStack(alignment: .leading, spacing: 18) {
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
                                .fill(Color.black.opacity(0.18))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
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
                                isSelected: index == model.personaSelectedIndex
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
        .clipShape(shape)
        .contentShape(shape)
    }

    @ViewBuilder
    private var personaPickerGlassBackground: some View {
        LiquidGlassShapeBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                                   cornerRadius: 24)
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
        OverlayCard(width: 446, compact: true, shadowed: false) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(
                    icon: "info.circle",
                    accent: StudioTheme.accent,
                    title: model.statusText,
                    dismissible: true,
                    titleSize: 13.5
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
                                        .fill(Color.white.opacity(0.14))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
        item: OverlayController.PersonaPickerItem, index: Int, isSelected: Bool
    ) -> some View {
        OverlayPickerRow(
            model: model,
            item: item,
            index: index,
            isSelected: isSelected
        )
    }

    private func scrollPersonaSelection(with proxy: ScrollViewProxy) {
        guard model.personaItems.indices.contains(model.personaSelectedIndex) else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(model.personaSelectedIndex, anchor: .center)
        }
    }

    private struct OverlayPickerRow: View {
        @ObservedObject var model: OverlayViewModel
        let item: OverlayController.PersonaPickerItem
        let index: Int
        let isSelected: Bool

        var body: some View {
            rowContent
        }

        private var rowContent: some View {
            HStack(spacing: 12) {
                personaAvatar

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.94))
                        .lineLimit(1)
                        .shadow(color: Color.black.opacity(0.34), radius: 2, x: 0, y: 1)
                    Text(item.subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.76 : 0.58))
                        .lineLimit(2)
                        .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                }

                Spacer(minLength: 0)

                if isSelected {
                    selectedCheckmark
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                model.requestPersonaSelection(at: index)
            }
        }

        private var personaAvatar: some View {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? StudioTheme.accent.opacity(0.34)
                        : Color.black.opacity(0.16)
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(item.title.prefix(2)).uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.20 : 0.10), lineWidth: 0.8)
                )
        }

        private var selectedCheckmark: some View {
            ZStack {
                Circle()
                    .fill(StudioTheme.accent.opacity(0.95))
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 21, height: 21)
        }

        private var rowBackground: some View {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    isSelected
                        ? StudioTheme.accent.opacity(0.18)
                        : Color.black.opacity(0.10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected
                                ? StudioTheme.accent.opacity(0.95) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.15 : 0.8
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSelected
                                    ? [Color.white.opacity(0.055), Color.white.opacity(0.01)]
                                    : [Color.clear, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
    }

    private func cardHeader(
        icon: String,
        accent: Color,
        title: String,
        dismissible: Bool,
        titleSize: CGFloat = 16.5
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
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("overlay.dismiss")
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
                .frame(width: 38, height: OverlayWaveformMetrics.maximumBarHeight)

            roundIconButton(systemName: "checkmark", action: onConfirm, inverted: true)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5.5)
        .background(
            LiquidGlassShapeBackground(
                shape: Capsule(style: .continuous),
                cornerRadius: nil)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private func roundIconButton(
        systemName: String, action: @escaping () -> Void, inverted: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.92) : Color.black.opacity(0.20))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(inverted ? 0.46 : 0.22), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.20), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingHintBanner: View {
    let text: String

    var body: some View {
        let layout = RecordingHintLayout(text: text)
        Text(text)
            .font(Font(RecordingHintLayout.font))
            .foregroundStyle(Color.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: layout.textSize.width, height: layout.textSize.height)
            .padding(.horizontal, RecordingHintLayout.horizontalPadding)
            .padding(.vertical, RecordingHintLayout.verticalPadding)
            .background(
                LiquidGlassShapeBackground(
                    shape: RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous),
                    cornerRadius: layout.cornerRadius)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

/// The orb capsule: the orb shows the voice, a slot on the right shows the timer or progress,
/// and the controls appear there only while the pointer is over the capsule. One shape morphs
/// between 78×35 at rest, 114×35 with listening controls and 360×103 with a live caption.
private struct OrbRecordingCapsule: View, Animatable {
    static let height = VoiceCapsuleLayout.bottomHeight

    let snapshot: VoiceCapsuleSnapshot
    let hintText: String
    let expanded: Bool
    let controlsRevealed: Bool
    let actions: VoiceCapsuleActions
    private var expansion: CGFloat
    private var controlsVisibility: CGFloat
    private var processingVisibility: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(snapshot: VoiceCapsuleSnapshot, hintText: String, expanded: Bool, controlsRevealed: Bool,
         actions: VoiceCapsuleActions) {
        self.snapshot = snapshot
        self.hintText = hintText
        self.expanded = expanded
        self.controlsRevealed = controlsRevealed
        self.actions = actions
        expansion = expanded ? 1 : 0
        controlsVisibility = controlsRevealed ? 1 : 0
        processingVisibility = snapshot.phase == .processing ? 1 : 0
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(expansion, AnimatablePair(controlsVisibility, processingVisibility)) }
        set {
            expansion = newValue.first
            controlsVisibility = newValue.second.first
            processingVisibility = newValue.second.second
        }
    }

    var body: some View {
        let cornerRadius: CGFloat = 17.5 + 4.5 * expansion
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let compactWidth = VoiceCapsuleLayout.bottomCompactWidth(controlsVisibility: controlsVisibility,
                                                                 processingVisibility: processingVisibility)
        let width = compactWidth + (360 - compactWidth) * expansion
        let height = Self.height + (LiveTranscriptPreviewLayout.expandedCapsuleHeight - Self.height) * expansion
        // Reveal text only when there is room for its fixed-width viewport.
        let captionVisibility = max(0, min(1, (expansion - 0.9) / 0.1))
        let controls = snapshot.phase.cardControls

        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.2 * processingVisibility))
                .frame(width: width * max(0, min(1, snapshot.progress)), height: Self.height)
                .frame(width: width, height: Self.height, alignment: .leading)
                .animation(.linear(duration: 0.06), value: snapshot.progress)
                .allowsHitTesting(false)

            LiveTranscriptPreviewText(text: snapshot.text)
                .frame(width: 330, height: LiveTranscriptPreviewLayout.textViewportHeight, alignment: .topLeading)
                .padding(.top, 12)
                .padding(.bottom, 43)
                .opacity(captionVisibility)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)

            // Explicit gaps keep the resting row inside 78pt: 7 + orb 21 + timer + 9.
            HStack(spacing: 0) {
                VoiceCapsuleOrb(phase: snapshot.phase, level: snapshot.level, diameter: 21, showsRipples: true)
                Spacer(minLength: 0)
                slot(controls: controls)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(width: width, height: Self.height)
        }
        .frame(width: width, height: height, alignment: .bottom)
        .clipShape(shape)
        .background(
            LiquidGlassShapeBackground(
                shape: shape,
                cornerRadius: cornerRadius)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
        .overlay(alignment: .bottom) {
            if !hintText.isEmpty {
                RecordingHintBanner(text: hintText)
                    .offset(y: -height - RecordingHintLayout.spacing)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("voiceCapsule.accessibility.label"))
        // Hidden controls stay reachable for VoiceOver without hovering.
        .accessibilityAction(named: L("common.cancel")) {
            if controls.contains(.cancel) { actions.cancel() }
        }
        .accessibilityAction(named: L("common.done")) {
            if controls.contains(.confirm) { actions.confirm() }
        }
        // Geometry is interpolated once, above. Re-lay out children at each
        // intermediate size instead of animating their positions a second time.
        .transaction { $0.animation = nil }
    }

    /// The timer or progress at rest, the controls under the pointer, in the same place.
    @ViewBuilder
    private func slot(controls: [VoiceCapsuleCardControl]) -> some View {
        if snapshot.phase != .failure {
            let reveal = controls.isEmpty ? 0 : controlsVisibility
            // The controls overlay the timer so they take no width until the capsule widens.
            meta.opacity(1 - reveal).overlay(alignment: .trailing) {
                HStack(spacing: 6) {
                    if controls.contains(.cancel) {
                        VoiceCapsuleRoundButton(systemName: "xmark", inverted: false,
                                                accessibilityLabel: L("common.cancel"), action: actions.cancel)
                    }
                    if controls.contains(.confirm) {
                        VoiceCapsuleRoundButton(systemName: "checkmark", inverted: true,
                                                accessibilityLabel: L("common.done"), action: actions.confirm)
                    }
                }
                .fixedSize()
                .opacity(reveal)
                .scaleEffect(reduceMotion ? 1 : 0.88 + 0.12 * reveal, anchor: .trailing)
                .allowsHitTesting(controlsRevealed)
                .accessibilityHidden(!controlsRevealed)
            }
            .frame(minWidth: 24, alignment: .trailing)
            .padding(.leading, 6)
        }
    }

    @ViewBuilder
    private var meta: some View {
        switch snapshot.phase {
        case .listening:
            if let startedAt = snapshot.recordingStartedAt {
                Text(timerInterval: startedAt ... Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .fixedSize()
            }
        case .processing:
            Text(VoiceCapsuleCopy.percent(snapshot.progress))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize()
        case .failure:
            EmptyView()
        }
    }
}

private struct MorphingRecordingCapsule: View, Animatable {
    let text: String
    let hintText: String
    let level: Float
    let expanded: Bool
    let showControls: Bool
    let isProcessing: Bool
    let processingTitle: String
    let processingProgress: CGFloat
    let onCancel: () -> Void
    let onConfirm: () -> Void
    private var expansion: CGFloat
    private var controlsVisibility: CGFloat
    private var processingVisibility: CGFloat

    init(
        text: String, hintText: String, level: Float, expanded: Bool, showControls: Bool,
        isProcessing: Bool, processingTitle: String, processingProgress: CGFloat,
        onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void
    ) {
        self.text = text
        self.hintText = hintText
        self.level = level
        self.expanded = expanded
        self.showControls = showControls
        self.isProcessing = isProcessing
        self.processingTitle = processingTitle
        self.processingProgress = processingProgress
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        expansion = expanded ? 1 : 0
        controlsVisibility = showControls ? 1 : 0
        processingVisibility = isProcessing ? 1 : 0
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(expansion, AnimatablePair(controlsVisibility, processingVisibility)) }
        set {
            expansion = newValue.first
            controlsVisibility = newValue.second.first
            processingVisibility = newValue.second.second
        }
    }

    var body: some View {
        let cornerRadius: CGFloat = 17.5 + 4.5 * expansion
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let recordingWidth: CGFloat = 78 + 36 * controlsVisibility
        let processingWidth = OverlayMotion.processingWidth(for: processingTitle)
        let compactWidth = recordingWidth + (processingWidth - recordingWidth) * processingVisibility
        let width = compactWidth + (360 - compactWidth) * expansion
        let height = 35 + (LiveTranscriptPreviewLayout.expandedCapsuleHeight - 35) * expansion
        // Reveal text only when there is room for its fixed-width viewport.
        let captionVisibility = max(0, min(1, (expansion - 0.9) / 0.1))
        let recordingOpacity = max(0, 1 - processingVisibility / 0.35)
        let processingOpacity = max(0, (processingVisibility - 0.35) / 0.65)

        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.22 * processingVisibility))
                .frame(width: processingWidth * max(0, min(1, processingProgress)), height: 35)
                .frame(width: processingWidth, height: 35, alignment: .leading)
                .clipShape(Capsule(style: .continuous))
                .animation(.linear(duration: 0.06), value: processingProgress)
                .allowsHitTesting(false)

            LiveTranscriptPreviewText(text: text)
                .frame(width: 330, height: LiveTranscriptPreviewLayout.textViewportHeight, alignment: .topLeading)
                .padding(.top, 12)
                .padding(.bottom, 43)
                .opacity(captionVisibility)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)

            controlsRow
                .frame(height: OverlayWaveformMetrics.maximumBarHeight)
                .padding(.horizontal, 20 - 13 * controlsVisibility)
                .padding(.bottom, 5.5)
                .opacity(recordingOpacity)
                .allowsHitTesting(!isProcessing)
                .accessibilityHidden(isProcessing)

            Text(processingTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, 12)
                .frame(width: processingWidth, height: 35)
                .opacity(processingOpacity)
                .accessibilityHidden(!isProcessing)
        }
        .frame(width: width, height: height, alignment: .bottom)
        .clipShape(shape)
        .background(
            LiquidGlassShapeBackground(
                shape: shape,
                cornerRadius: cornerRadius)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
        .overlay(alignment: .bottom) {
            if !hintText.isEmpty {
                RecordingHintBanner(text: hintText)
                    .offset(y: -height - RecordingHintLayout.spacing)
            }
        }
        .environment(\.colorScheme, .dark)
        // Geometry is interpolated once, above. Re-lay out children at each
        // intermediate size instead of animating their positions a second time.
        .transaction { $0.animation = nil }
    }

    private var controlsRow: some View {
        HStack(spacing: 7 * controlsVisibility) {
            roundIconButton(systemName: "xmark", action: onCancel)
                .frame(width: 24 * controlsVisibility)
                .opacity(controlsVisibility)
                .clipped()
                .allowsHitTesting(showControls)
                .accessibilityHidden(!showControls)

            LevelWaveform(level: level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: OverlayWaveformMetrics.maximumBarHeight)

            roundIconButton(systemName: "checkmark", action: onConfirm, inverted: true)
                .frame(width: 24 * controlsVisibility)
                .opacity(controlsVisibility)
                .clipped()
                .allowsHitTesting(showControls)
                .accessibilityHidden(!showControls)
        }
    }

    private func roundIconButton(
        systemName: String, action: @escaping () -> Void, inverted: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.92) : Color.black.opacity(0.20))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(inverted ? 0.46 : 0.22), lineWidth: 0.8)
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

struct ThinkingProgressCapsule: View {
    let title: String
    let progress: CGFloat

    var body: some View {
        let capsuleShape = Capsule(style: .continuous)

        ZStack {
            LiquidGlassShapeBackground(
                shape: capsuleShape,
                cornerRadius: nil)

            GeometryReader { geo in
                let width = max(0, geo.size.width)

                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(0, width * progress))
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
        .animation(.linear(duration: 0.06), value: progress)
    }
}

struct ProcessingTranscriptCapsule: View {
    let text: String
    let title: String
    let progress: CGFloat

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
                cornerRadius: 22)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
        .animation(.linear(duration: 0.06), value: progress)
    }

    private var processingRow: some View {
        let capsuleShape = Capsule(style: .continuous)

        return ZStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.08)
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: max(0, geo.size.width * progress))
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
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
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
                    cornerRadius: nil)
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
        @ViewBuilder content: () -> Content
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
                y: shadowed ? 16 : 0
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
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                radius: hostedInWindowChrome ? 0 : 18, x: 0, y: hostedInWindowChrome ? 0 : 12
            )
    }

    private var toastBackground: some View {
        // Window chrome can be transparent in glass mode. Text-only overlays still
        // need a stable surface, including notices and transcript previews.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(red: 0.13, green: 0.11, blue: 0.11).opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
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
                    .fill(Color.white.opacity(0.14))
            )
    }
}

struct LevelWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Float
    let activeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0 ..< OverlayWaveformMetrics.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(activeColor)
                    .frame(
                        width: 2.3,
                        height: OverlayWaveformMetrics.barHeight(for: index, level: level)
                    )
                    .shadow(color: Color.black.opacity(0.34), radius: 1.6, x: 0, y: 0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
    }
}
