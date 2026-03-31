import AppKit
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// CGEventTap callback — intercepts and consumes keyboard events (Return/Esc/arrows)
// system-wide so the panel never needs to steal focus from the original app.
private func overlayEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<OverlayController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handleEventTapEvent(type: type, event: event)
}

final class OverlayController {
    private static let autoDismissDelay: TimeInterval = 10.0

    struct PersonaPickerItem: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
    }

    private let appState: AppStateStore
    private var window: NSPanel?

    private let model = OverlayViewModel()
    private var dismissWorkItem: DispatchWorkItem?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        model.onFailureRetryRequested = onRetry
    }

    func show() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.show() }
            return
        }
        ensureWindow()
        model.presentation = .recordingHold
        model.statusText = L("overlay.recording.listening")
        model.detailText = ""
        model.processingProgress = 0
        refreshWindow()
    }

    private func ensureWindow() {
        if window == nil {
            let view = OverlayView(model: model)
            let hosting = TransparentHostingView(rootView: view)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            let metrics = metrics(for: .recordingHold)
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: metrics.size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level.statusBar
            panel.backgroundColor = NSColor.clear
            panel.hasShadow = false
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.transient]
            panel.contentView = hosting
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

            window = panel
        }
    }

    func showLockedRecording() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showLockedRecording() }
            return
        }
        ensureWindow()
        model.presentation = .recordingLocked
        refreshWindow()
    }

    func updateRecordingPreviewText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updateRecordingPreviewText(text) }
            return
        }

        model.detailText = text
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
        ensureWindow()
        model.presentation = .processing
        model.statusText = L("overlay.processing.thinking")
        model.detailText = ""
        model.processingProgress = 0
        refreshWindow()
    }

    func showFailure(message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showFailure(message: message) }
            return
        }
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.failure.title")
        model.detailText = message
        model.failureRetryable = false
        refreshWindow()
    }

    func showTimeoutFailure() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showTimeoutFailure() }
            return
        }
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .failure
        model.statusText = L("overlay.timeout.title")
        model.detailText = L("overlay.timeout.message")
        model.failureRetryable = true
        refreshWindow()
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
        if model.presentation == .transcriptPreview {
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
        model.presentation = .notice
        model.statusText = L("overlay.notice.title")
        model.detailText = message
        refreshWindow()
        dismiss(after: Self.autoDismissDelay)
    }

    func showResultDialog(title: String, message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showResultDialog(title: title, message: message) }
            return
        }
        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .resultDialog
        model.statusText = title
        model.detailText = message
        refreshWindow()
    }

    func showPersonaPicker(items: [PersonaPickerItem], selectedIndex: Int, title: String, instructions: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showPersonaPicker(items: items, selectedIndex: selectedIndex, title: title, instructions: instructions)
            }
            return
        }

        dismissWorkItem?.cancel()
        ensureWindow()
        model.presentation = .personaPicker
        model.personaItems = items
        model.personaSelectedIndex = max(0, min(selectedIndex, max(0, items.count - 1)))
        model.personaViewportHeight = min(360, CGFloat(max(1, items.count)) * 84)
        model.statusText = title
        model.detailText = instructions
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

        if model.presentation == .processing {
            model.processingProgress = 1
            dismiss(after: 0.18)
        } else if model.presentation == .notice || model.presentation == .resultDialog {
            return
        } else {
            dismiss(after: StudioTheme.Durations.overlayDismissDelay)
        }
    }

    /// Immediately hides the overlay window and resets state, running synchronously
    /// on the main thread. Use this before returning focus to the original application
    /// so the panel is guaranteed to be hidden before activation.
    func dismissImmediately() {
        let work = { [weak self] in
            guard let self else { return }
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil
            self.window?.orderOut(nil)
            self.model.detailText = ""
            self.model.level = 0
            self.model.processingProgress = 0
            self.removeKeyMonitoring()
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
        if model.presentation == .failure && delay > 0 {
            return
        }
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.model.detailText = ""
            self?.model.level = 0
            self?.model.processingProgress = 0
            self?.removeKeyMonitoring()
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
            alpha: 0.96
        )

        switch presentation {
        case .recordingHoldPreview, .recordingLockedPreview, .transcriptPreview, .notice:
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

        window.setContentSize(metrics.size)
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.ignoresMouseEvents = !metrics.interactive
    }

    private func metrics(for presentation: OverlayViewModel.Presentation) -> OverlayMetrics {
        switch presentation {
        case .recordingHold:
            return OverlayMetrics(size: NSSize(width: 118, height: 72), anchor: .bottom, offset: 24, interactive: false)
        case .recordingHoldPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 118), anchor: .bottom, offset: 24, interactive: false)
        case .recordingLocked:
            return OverlayMetrics(size: NSSize(width: 158, height: 66), anchor: .bottom, offset: 26, interactive: true)
        case .recordingLockedPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 124), anchor: .bottom, offset: 24, interactive: true)
        case .processing:
            return OverlayMetrics(size: NSSize(width: 118, height: 72), anchor: .bottom, offset: 24, interactive: false)
        case .transcriptPreview:
            return OverlayMetrics(size: NSSize(width: 344, height: 108), anchor: .bottom, offset: 80, interactive: false)
        case .notice:
            return OverlayMetrics(size: NSSize(width: 344, height: 108), anchor: .bottom, offset: 80, interactive: true)
        case .failure:
            let failureHeight: CGFloat = model.failureRetryable ? 248 : 216
            return OverlayMetrics(size: NSSize(width: 352, height: failureHeight), anchor: .bottom, offset: 80, interactive: true)
        case .personaPicker:
            let viewportHeight = min(320, max(180, model.personaViewportHeight))
            return OverlayMetrics(size: NSSize(width: 458, height: viewportHeight + 132), anchor: .center, offset: 36, interactive: true)
        case .resultDialog:
            return OverlayMetrics(size: NSSize(width: 446, height: 236), anchor: .bottom, offset: 36, interactive: true)
        }
    }

    private func updateKeyMonitoring() {
        if model.presentation == .recordingLocked
            || model.presentation == .recordingLockedPreview
            || model.presentation == .failure
            || model.presentation == .personaPicker
            || model.presentation == .resultDialog {
            installKeyMonitoringIfNeeded()
        } else {
            removeKeyMonitoring()
        }
    }

    private func installKeyMonitoringIfNeeded() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: overlayEventTapCallback,
            userInfo: selfPtr
        ) else {
            NSLog("[OverlayController] Failed to create CGEventTap — falling back to NSEvent monitors")
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
            return self.handleKeyCode(Int(event.keyCode)) ? nil : event
        }
        // Store monitors in the eventTap/runLoopSource slots is not possible,
        // so we use associated-object-free approach: keep them as "Any" via a side channel.
        _fallbackGlobalMonitor = globalMon
        _fallbackLocalMonitor = localMon
    }
    private var _fallbackGlobalMonitor: Any?
    private var _fallbackLocalMonitor: Any?

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

    fileprivate func handleKeyCode(_ keyCode: Int) -> Bool {
        if model.presentation == .recordingLocked || model.presentation == .recordingLockedPreview {
            if keyCode == 53 {
                model.requestCancel()
                return true
            }
            return false
        }

        switch model.presentation {
        case .failure:
            if keyCode == 53 {
                model.requestDismiss()
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
        case transcriptPreview
        case notice
        case failure
        case personaPicker
        case resultDialog
    }

    @Published var presentation: Presentation = .recordingHold
    @Published var statusText: String = ""
    @Published var detailText: String = ""
    @Published var level: Float = 0
    @Published var processingProgress: CGFloat = 0
    @Published var personaItems: [OverlayController.PersonaPickerItem] = []
    @Published var personaSelectedIndex: Int = 0
    @Published var personaViewportHeight: CGFloat = 240
    @Published var failureRetryable: Bool = false
    var onDismissRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onConfirmRequested: (() -> Void)?
    var onPersonaMoveUpRequested: (() -> Void)?
    var onPersonaMoveDownRequested: (() -> Void)?
    var onPersonaSelectRequested: ((Int) -> Void)?
    var onPersonaConfirmRequested: (() -> Void)?
    var onPersonaCancelRequested: (() -> Void)?
    var onResultCopyRequested: (() -> Void)?
    var onFailureRetryRequested: (() -> Void)?

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

    func requestFailureRetry() {
        onFailureRetryRequested?()
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        if usesWindowChrome {
            Group {
                switch model.presentation {
                case .recordingHold:
                    recordingCapsule
                case .recordingHoldPreview:
                    recordingPreviewCard(showControls: false)
                case .recordingLocked:
                    lockedRecordingCapsule
                case .recordingLockedPreview:
                    recordingPreviewCard(showControls: true)
                case .processing:
                    processingCapsule
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
                    recordingCapsule
                case .recordingHoldPreview:
                    recordingPreviewCard(showControls: false)
                case .recordingLocked:
                    lockedRecordingCapsule
                case .recordingLockedPreview:
                    recordingPreviewCard(showControls: true)
                case .processing:
                    processingCapsule
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
        }
    }

    private var usesWindowChrome: Bool {
        switch model.presentation {
        case .recordingHoldPreview, .recordingLockedPreview, .transcriptPreview, .notice, .failure, .personaPicker, .resultDialog:
            return true
        default:
            return false
        }
    }

    private var contentAlignment: Alignment {
        switch model.presentation {
        case .recordingHold, .recordingHoldPreview, .recordingLocked, .recordingLockedPreview, .processing, .notice, .transcriptPreview, .failure, .personaPicker, .resultDialog:
            return .bottom
        }
    }

    private var containerPadding: EdgeInsets {
        switch model.presentation {
        case .recordingHold, .processing:
            return EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        case .recordingHoldPreview:
            return EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        case .recordingLocked:
            return EdgeInsets(top: 15, leading: 14, bottom: 15, trailing: 14)
        case .recordingLockedPreview:
            return EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        case .transcriptPreview, .notice, .failure:
            return EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        case .personaPicker, .resultDialog:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
    }

    private var recordingCapsule: some View {
        OverlayCapsule {
            LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                .frame(width: 38, height: 14)
        }
    }

    private var processingCapsule: some View {
        ThinkingProgressCapsule(
            title: model.statusText.isEmpty ? L("overlay.processing.thinking") : model.statusText,
            progress: model.processingProgress
        )
    }

    private var lockedRecordingCapsule: some View {
        LockedRecordingCapsule(
            level: model.level,
            onCancel: model.requestCancel,
            onConfirm: model.requestConfirm
        )
    }

    private func recordingPreviewCard(showControls: Bool) -> some View {
        OverlayCompactToast(width: 344, hostedInWindowChrome: true) {
            VStack(alignment: .leading, spacing: 10) {
                if showControls {
                    HStack(spacing: 8) {
                        Button(action: model.requestCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.96))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)

                        LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                            .frame(width: 38, height: 14)

                        Spacer(minLength: 0)

                        Button(action: model.requestConfirm) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.9))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.98)))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    LevelWaveform(level: model.level, activeColor: Color.white.opacity(0.95))
                        .frame(width: 38, height: 14)
                }

                Text("“\(model.detailText)”")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
                    .lineLimit(2)
            }
        }
    }

    private var previewCard: some View {
        OverlayCompactToast(width: 344, hostedInWindowChrome: true) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.43, green: 0.56, blue: 1.0))

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
                cardHeader(icon: "exclamationmark.circle", accent: Color(red: 1.0, green: 0.42, blue: 0.08), title: model.statusText, dismissible: true)

                ScrollView(showsIndicators: false) {
                    Text(model.detailText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: model.failureRetryable ? 124 : 92)

                if model.failureRetryable {
                    Button(action: model.requestFailureRetry) {
                        Text(L("common.retry"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1.0, green: 0.42, blue: 0.08).opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var noticeToast: some View {
        OverlayCompactToast(width: 344, hostedInWindowChrome: true) {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(
                    icon: "info.circle",
                    accent: Color(red: 0.43, green: 0.56, blue: 1.0),
                    title: model.statusText,
                    dismissible: true,
                    titleSize: 13.5
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
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.statusText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.98))

                    Text(model.detailText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button(action: model.requestPersonaCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(model.personaItems.enumerated()), id: \.element.id) { index, item in
                            personaPickerRow(item: item, index: index, isSelected: index == model.personaSelectedIndex)
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
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.44))
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                )
        )
        .shadow(color: Color.black.opacity(0.32), radius: 32, x: 0, y: 18)
    }

    private var resultDialogCard: some View {
        OverlayCard(width: 446, compact: true, hostedInWindowChrome: true, shadowed: false) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(
                    icon: "info.circle",
                    accent: Color(red: 0.43, green: 0.56, blue: 1.0),
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

    private func personaPickerRow(item: OverlayController.PersonaPickerItem, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : Color.white.opacity(0.045)
                )
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(item.title.prefix(2)).uppercased())
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.96) : Color.white.opacity(0.7))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.94))
                Text(item.subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(isSelected ? 0.7 : 0.5))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.95))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor.opacity(0.68) : Color.white.opacity(0.045),
                            lineWidth: isSelected ? 1 : 0.8
                        )
                )
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
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.9))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1.2)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
    }

    private func roundIconButton(systemName: String, action: @escaping () -> Void, inverted: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(inverted ? Color.black.opacity(0.9) : Color.white.opacity(0.96))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(inverted ? Color.white.opacity(0.98) : Color.white.opacity(0.22))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkingProgressCapsule: View {
    let title: String
    let progress: CGFloat
    @State private var displayProgress: CGFloat = 0

    var body: some View {
        let capsuleShape = Capsule(style: .continuous)

        ZStack {
            capsuleShape
                .fill(Color.black.opacity(0.9))

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

            capsuleShape
                .stroke(Color.white.opacity(0.22), lineWidth: 1.2)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 12)
        }
        .frame(width: 78, height: 35)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
        .onAppear {
            advanceProgress()
        }
        .onChange(of: progress) { newValue in
            if newValue >= 1 {
                withAnimation(.easeOut(duration: 0.16)) {
                    displayProgress = 1
                }
            } else if newValue <= 0.0001 {
                displayProgress = 0
                advanceProgress()
            }
        }
    }

    private func advanceProgress() {
        guard progress <= 0.0001 else { return }

        withAnimation(.linear(duration: 0.9)) {
            displayProgress = 0.68
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard progress < 0.69, displayProgress < 0.69 else { return }
            withAnimation(.easeOut(duration: 1.4)) {
                displayProgress = 0.9
            }
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
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1.2)
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 12)
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
            .shadow(color: Color.black.opacity(shadowed ? 0.32 : 0), radius: shadowed ? 26 : 0, x: 0, y: shadowed ? 16 : 0)
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
            .shadow(color: Color.black.opacity(hostedInWindowChrome ? 0 : 0.28), radius: hostedInWindowChrome ? 0 : 18, x: 0, y: hostedInWindowChrome ? 0 : 12)
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
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
                    .fill(Color.white.opacity(0.14))
            )
    }
}

private struct LevelWaveform: View {
    let level: Float
    let activeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(activeColor)
                    .frame(width: 2.3, height: barHeight(for: index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedLevel = CGFloat(max(0.08, min(1.0, level)))
        let profile: [CGFloat] = [0.34, 0.52, 0.72, 0.9, 1.0, 0.86, 0.7, 0.5, 0.32]
        return 4.5 + (10.8 * normalizedLevel * profile[index])
    }
}
