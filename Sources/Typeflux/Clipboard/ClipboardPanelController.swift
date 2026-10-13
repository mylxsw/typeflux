import AppKit
import Combine
import Quartz
import QuartzCore
import SwiftUI

/// Hosts the clipboard panel in a non-activating panel that still takes keyboard focus, so the
/// app the user was typing in stays frontmost and receives the paste after the panel closes.
@preconcurrency @MainActor
final class ClipboardPanelController: NSObject, @preconcurrency ClipboardPanelPresenting {
    private let settingsStore: SettingsStore
    private var panel: ClipboardPanelWindow?
    private var hostingView: NSHostingView<AnyView>?
    private lazy var interfaceStyleObserver = InterfaceStyleObserver(settings: settingsStore)
    private weak var model: ClipboardPanelModel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var actionsMenu: NSMenu?
    private var focusRequest = 0
    private var quickLookURLs: [URL] = []
    private var previewObservation: AnyCancellable?
    private var styleObservation: AnyCancellable?
    private let layout = ClipboardPanelLayout()
    /// The launcher's scalar spring also drives the clipboard's width.
    private let previewWidthAnimator = AskLauncherHeightAnimator()
    private var previewCenterX: CGFloat?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    var isPresented: Bool {
        panel?.isVisible == true
    }

    var presentedWindow: NSWindow? { isPresented ? panel : nil }
    var isResizingPreview: Bool { previewWidthAnimator.isAnimating }
    var contentViewportWidth: CGFloat? { layout.width }

    func present(_ model: ClipboardPanelModel) {
        actionsMenu?.cancelTracking()
        previewWidthAnimator.stop()
        previewObservation = nil
        styleObservation = nil
        self.model = model
        model.onShowActions = { [weak self] in self?.showActionsMenu() }
        focusRequest += 1
        let style = settingsStore.interfaceStyle
        let size = ClipboardPanelView.size(showsPreview: model.showsPreview, style: style)
        layout.setWidth(size.width, style: style)
        let panel = panel(for: model)
        applyAppearance(to: panel)
        panel.setContentSize(size)
        position(panel)
        previewCenterX = settingsStore.clipboardPanelPosition == .mouse
            ? panel.frame.midX : panel.screen?.visibleFrame.midX
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        previewObservation = model.$showsPreview.dropFirst().removeDuplicates().sink { [weak self] shows in
            self?.resizeForPreview(shows)
        }
        styleObservation = interfaceStyleObserver.$style.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self, let model = self.model else { return }
            self.resizeForPreview(model.showsPreview, animated: false)
        }
    }

    /// One spring drives the native frame and content viewport around the same horizontal centre.
    private func resizeForPreview(_ shows: Bool, animated: Bool = true) {
        guard let panel, let hostingView else { return }
        let style = settingsStore.interfaceStyle
        let screen = panel.screen ?? NSScreen.main
        previewWidthAnimator.update(
            from: panel.frame.width, to: ClipboardPanelView.size(showsPreview: shows, style: style).width,
            animated: animated && panel.isVisible && !reduceMotion(),
            framesPerSecond: screen?.maximumFramesPerSecond ?? 60
        ) { [weak self, weak panel, weak hostingView] width in
            guard let self, let panel, let hostingView else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let frame = ClipboardPanelPlacement.resized(
                panel.frame, width: ClipboardPanelLayout.boundedWidth(width, style: style),
                screen: screen?.visibleFrame, centerX: self.previewCenterX
            )
            panel.setFrame(frame, display: false)
            // AppKit rounds window frames to pixels; the viewport must use the committed size.
            self.layout.setWidth(panel.frame.width, style: style)
            hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
            hostingView.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.commit()
        }
    }

    func dismiss() {
        actionsMenu?.cancelTracking()
        previewWidthAnimator.stop()
        previewObservation = nil
        styleObservation = nil
        closeQuickLook()
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func showActionsMenu() {
        guard let panel, panel.isVisible, let model, let host = panel.contentView,
              model.snippetDraft == nil, model.editingText == nil, model.pendingConfirmation == nil else { return }
        let presenter = ClipboardPanelActionsMenu(model: model)
        let menu = presenter.makeMenu()
        actionsMenu = menu
        defer { actionsMenu = nil }
        withExtendedLifetime(presenter) {
            let x = ClipboardPanelView.width(for: settingsStore.interfaceStyle) - 16
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: 32), in: host)
        }
    }

    func toggleQuickLook(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let previewPanel = QLPreviewPanel.shared()
        if QLPreviewPanel.sharedPreviewPanelExists(), previewPanel?.isVisible == true {
            previewPanel?.orderOut(nil)
            return
        }
        quickLookURLs = urls
        panel?.makeKey()
        previewPanel?.updateController()
        previewPanel?.reloadData()
        previewPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    private func panel(for model: ClipboardPanelModel) -> ClipboardPanelWindow {
        let rootView = AnyView(ClipboardPanelView(model: model, focusRequest: focusRequest, layout: layout)
            .interfaceStyle(following: interfaceStyleObserver))
        if let panel, let hostingView {
            hostingView.rootView = rootView
            return panel
        }
        let size = ClipboardPanelView.size(showsPreview: model.showsPreview, style: settingsStore.interfaceStyle)
        let panel = ClipboardPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.quickLookController = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.clipboard")
        let hostingView = NSHostingView(rootView: rootView)
        // The controller owns sizing; SwiftUI must not independently move the native window.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    /// Shares the launcher's visible top edge on the screen under the mouse.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let anchor = settingsStore.askLauncherPosition == .lastPosition
            ? settingsStore.askLauncherAnchors[AskLauncherPlacement.key(for: screen)] : nil
        panel.setFrameOrigin(ClipboardPanelPlacement.frame(
            size: panel.frame.size, screen: screen.visibleFrame, position: settingsStore.clipboardPanelPosition,
            launcherAnchor: anchor, mouse: NSEvent.mouseLocation
        ).origin)
    }

    private func applyAppearance(to panel: NSPanel) {
        switch settingsStore.appearanceMode {
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
    }

    // MARK: - Input

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, handleKeyDown(event) else { return event }
                return nil
            }
        }
        if clickMonitor == nil {
            // Clicks in other apps close the panel; clicks in our own windows arrive as local events.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.model?.onDismiss?()
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    /// Maps a key press in the panel (or in Quick Look) to the model. Returns whether it was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Let native menu tracking own arrows, Return, Escape and its key equivalents.
        guard actionsMenu == nil else { return false }
        guard let panel, let model, panel.isVisible else { return false }
        if isQuickLookVisible, event.window !== panel {
            return handleQuickLookKeyDown(event)
        }
        guard event.window === panel else { return false }
        // Native search and editors must finish input method composition before panel shortcuts run.
        let editor = panel.firstResponder as? NSTextView
        guard editor?.hasMarkedText() != true else { return false }
        if model.snippetDraft != nil {
            if event.keyCode == 53 { model.cancelSnippetEdit(); return true }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if [36, 76].contains(event.keyCode), flags == .command { model.commitSnippet(); return true }
            return false
        }
        if model.editingText != nil {
            return handleEditorKeyDown(event, model: model)
        }
        if model.pendingConfirmation != nil {
            return handleConfirmationKeyDown(event, model: model)
        }

        let command = ClipboardPanelKeyCommand.command(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            queryIsEmpty: model.query.isEmpty,
            hasTextSelection: (editor?.selectedRange().length ?? 0) > 0
        )
        guard let command else { return false }
        if command == .showActions {
            if !event.isARepeat { showActionsMenu() }
            return true
        }
        Self.run(command, on: model, isRepeat: event.isARepeat)
        return true
    }

    private static func run(_ command: ClipboardPanelKeyCommand, on model: ClipboardPanelModel, isRepeat: Bool) {
        switch command {
        case .moveUp: model.moveSelection(by: -1)
        case .moveDown: model.moveSelection(by: 1)
        case .nextCategory: model.cycleCategory(forward: true)
        case .previousCategory: model.cycleCategory(forward: false)
        case .cancel: model.cancel()
        case let .action(action): model.perform(action)
        case .quickPaste, .togglePreview, .showPreview, .hidePreview, .togglePause, .openSettings, .showActions:
            // Toggles and one-shot commands ignore key repeat.
            if !isRepeat { runOnce(command, on: model) }
        }
    }

    private static func runOnce(_ command: ClipboardPanelKeyCommand, on model: ClipboardPanelModel) {
        switch command {
        case let .quickPaste(number): model.quickPaste(number: number)
        case .togglePreview: model.togglePreview()
        case .showPreview:
            if !model.showsPreview { model.showsPreview = true }
        case .hidePreview:
            if model.showsPreview { model.showsPreview = false }
        case .togglePause: model.send(.togglePause)
        case .openSettings: model.send(.openSettings)
        default: break
        }
    }

    /// While editing before paste the text view gets the keys; Escape cancels and ⌘↩ pastes.
    private func handleEditorKeyDown(_ event: NSEvent, model: ClipboardPanelModel) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 {
            model.cancelEdit()
            return true
        }
        if [36, 76].contains(event.keyCode), flags == .command {
            model.commitEdit()
            return true
        }
        return false
    }

    /// A pending confirmation takes Return and Escape and holds the list still.
    private func handleConfirmationKeyDown(_ event: NSEvent, model: ClipboardPanelModel) -> Bool {
        switch event.keyCode {
        case 36, 76: model.confirmPending()
        case 53: model.cancelPending()
        case 125, 126, 48: break
        default: return false
        }
        return true
    }

    // MARK: - Quick Look

    /// Quick Look owns the keyboard while open; Escape, Space and ⌘Y close it.
    private func handleQuickLookKeyDown(_ event: NSEvent) -> Bool {
        let commandY = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "y"
        let closes = event.keyCode == 53 || event.keyCode == 49 || commandY
        if closes { closeQuickLook() }
        return closes
    }

    private var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    private func closeQuickLook() {
        guard isQuickLookVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
        panel?.makeKey()
    }

    fileprivate func beginQuickLook(_ previewPanel: QLPreviewPanel) {
        previewPanel.dataSource = self
        previewPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    fileprivate func endQuickLook(_ previewPanel: QLPreviewPanel) {
        previewPanel.dataSource = nil
    }
}

extension ClipboardPanelController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }
}

/// A borderless panel that can become key (for the search field) and drive Quick Look.
final class ClipboardPanelWindow: NSPanel {
    fileprivate weak var quickLookController: ClipboardPanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        quickLookController != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookController?.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookController?.endQuickLook(panel)
    }
}
