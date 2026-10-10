import AppKit
import Combine
import Quartz
import SwiftUI

/// Hosts the clipboard panel in a non-activating panel that still takes keyboard focus, so the
/// app the user was typing in stays frontmost and receives the paste after the panel closes.
final class ClipboardPanelController: NSObject, ClipboardPanelPresenting {
    private let settingsStore: SettingsStore
    private var panel: ClipboardPanelWindow?
    private var hostingView: NSHostingView<ClipboardPanelView>?
    private weak var model: ClipboardPanelModel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var focusRequest = 0
    private var quickLookURLs: [URL] = []
    private var previewObservation: AnyCancellable?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    var isPresented: Bool {
        panel?.isVisible == true
    }

    func present(_ model: ClipboardPanelModel) {
        self.model = model
        focusRequest += 1
        let panel = panel(for: model)
        applyAppearance(to: panel)
        panel.setContentSize(ClipboardPanelView.size(showsPreview: model.showsPreview))
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        previewObservation = model.$showsPreview.dropFirst().removeDuplicates().sink { [weak self] shows in
            self?.resizeForPreview(shows)
        }
    }

    /// The preview pane widens the panel to the right; the list stays where it was.
    private func resizeForPreview(_ shows: Bool) {
        guard let panel, let hostingView else { return }
        let size = ClipboardPanelView.size(showsPreview: shows)
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = panel.screen ?? NSScreen.main {
            frame = AskLauncherPlacement.clamped(frame, screen: screen.visibleFrame)
        }
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    func dismiss() {
        previewObservation = nil
        closeQuickLook()
        removeMonitors()
        panel?.orderOut(nil)
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
        let rootView = ClipboardPanelView(model: model, focusRequest: focusRequest,
                                          interfaceStyle: settingsStore.interfaceStyle)
        if let panel, let hostingView {
            hostingView.rootView = rootView
            return panel
        }
        let size = NSSize(width: ClipboardPanelView.width, height: ClipboardPanelView.height)
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
            size: panel.frame.size, screen: screen.visibleFrame, launcherAnchor: anchor
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
        guard let panel, let model, panel.isVisible else { return false }
        if isQuickLookVisible, event.window !== panel {
            return handleQuickLookKeyDown(event)
        }
        guard event.window === panel else { return false }

        let editor = panel.firstResponder as? NSTextView
        let command = ClipboardPanelKeyCommand.command(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            queryIsEmpty: model.query.isEmpty,
            hasTextSelection: (editor?.selectedRange().length ?? 0) > 0
        )
        guard let command else { return false }
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
        case let .quickPaste(number):
            if !isRepeat { model.quickPaste(number: number) }
        case .togglePreview:
            if !isRepeat { model.togglePreview() }
        }
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

extension ClipboardPanelController: QLPreviewPanelDataSource {
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
