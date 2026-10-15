import AppKit
import Combine
import SwiftUI

@MainActor
final class AskTranslationPanelController: NSObject, NSWindowDelegate {
    let model: AskTranslationPanelModel
    private var panel: AskTranslationPanelWindow?
    private var host: NSHostingView<AnyView>?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var observation: AnyCancellable?
    private var appearanceObservation: NSObjectProtocol?
    private var measuredContentHeight: CGFloat?
    private var layoutPosition: AskTranslationPanelPosition = .lastPosition
    private var updatingFrame = false
    private lazy var style = InterfaceStyleObserver(settings: model.settings)

    init(model: AskTranslationPanelModel) {
        self.model = model
        super.init()
        model.onDismiss = { [weak self] in self?.hide() }
        observation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshLayout() }
        }
        appearanceObservation = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.applyAppearance(panel)
            }
        }
    }

    deinit {
        if let appearanceObservation {
            NotificationCenter.default.removeObserver(appearanceObservation)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    var isPresented: Bool {
        panel?.isVisible == true
    }

    var presentedWindow: NSWindow? {
        isPresented ? panel : nil
    }

    func prewarm() {
        let window = makePanel()
        applyAppearance(window)
        updateRoot()
    }

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
        if let content = panel?.contentView, let editor = editor(in: content) {
            panel?.makeFirstResponder(editor)
        }
    }

    func present(selection: CGRect? = nil, focusEditor: Bool = true) {
        let window = makePanel()
        applyAppearance(window)
        let mouse = NSEvent.mouseLocation
        let screen = selection.flatMap { bounds in NSScreen.screens.first { $0.frame.intersects(bounds) } }
            ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            updateResizeLimits(window, on: screen)
            let last = model.settings.defaults.dictionary(forKey: "ask.translation.panel.origin")
            let origin: CGPoint? = (last?["x"] as? Double).flatMap { horizontal in
                (last?["y"] as? Double).map { CGPoint(x: horizontal, y: $0) }
            }
            let frame = AskTranslationPanelPlacement.frame(size: desiredSize(on: screen),
                                                           screen: screen.visibleFrame,
                                                           position: model.settings.askTranslationSettings
                                                               .panelPosition,
                                                           mouse: mouse, last: origin)
            setFrame(frame, on: window, display: false)
            layoutPosition = model.settings.askTranslationSettings.panelPosition
        }
        updateRoot()
        if focusEditor {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Keep the source application's selection focused while capture runs.
            window.orderFrontRegardless()
        }
        installMonitors()
        if focusEditor { focus() }
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    func refreshLayout() {
        guard let panel, panel.isVisible, !panel.inLiveResize,
              let screen = panel.screen ?? NSScreen.main else { return }
        updateResizeLimits(panel, on: screen)
        let size = desiredSize(on: screen)
        let frame = AskTranslationPanelPlacement.frame(size: size, screen: screen.visibleFrame,
                                                       position: !model
                                                           .pinned && layoutPosition == .center ? .center :
                                                           .lastPosition,
                                                       mouse: NSEvent.mouseLocation,
                                                       last: CGPoint(
                                                           x: panel.frame.minX,
                                                           y: panel.frame.maxY - size.height
                                                       ))
        setFrame(frame, on: panel, display: true)
        updateRoot()
    }

    private func setFrame(_ frame: CGRect, on window: NSWindow, display: Bool) {
        updatingFrame = true
        defer { updatingFrame = false }
        window.setFrame(frame, display: display)
    }

    private func desiredSize(on screen: NSScreen) -> CGSize {
        let chrome = AskTranslationPanelView.estimatedChromeHeight(
            text: model.text, screenshot: model.screenshot != nil, notice: model.notice != nil
        )
        let stored = model.settings.defaults.dictionary(forKey: "ask.translation.panel.size")
        let remembered: CGSize? = (stored?["width"] as? Double).flatMap { width in
            (stored?["height"] as? Double).map { CGSize(width: width, height: $0) }
        }
        return AskTranslationPanelPlacement.size(
            content: measuredContentHeight ?? (chrome + AskTranslationStackView.height(model.stack)),
            screen: screen.visibleFrame, preference: model.settings.askTranslationSettings.maxHeight,
            remembered: remembered
        )
    }

    private func makePanel() -> AskTranslationPanelWindow {
        if let panel {
            return panel
        }
        let window = AskTranslationPanelWindow(
            contentRect: CGRect(x: 0, y: 0, width: AskTranslationPanelPlacement.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.translation")
        panel = window
        let host = NSHostingView(rootView: root(height: window.frame.height))
        host.sizingOptions = []
        window.contentView = host
        self.host = host
        return window
    }

    private func root(height: CGFloat) -> AnyView {
        AnyView(AskTranslationPanelView(model: model, history: model.history, height: height,
                                        onContentHeightChange: { [weak self] height in
                                            self?.contentHeightChanged(height)
                                        })
                                        .interfaceStyle(following: style))
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(height - (measuredContentHeight ?? 0)) > 0.5 else { return }
        measuredContentHeight = height
        DispatchQueue.main.async { [weak self] in self?.refreshLayout() }
    }

    private func updateRoot() {
        guard let panel, let host else { return }
        host.rootView = root(height: panel.frame.height)
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.layoutSubtreeIfNeeded()
    }

    private func applyAppearance(_ window: NSWindow) {
        switch model.settings.appearanceMode {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView {
            return editor
        }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, event.window === panel, panel.attachedSheet == nil else { return false }
        let editor = panel.firstResponder as? NSTextView
        guard editor?.hasMarkedText() != true else { return false }
        let range = editor?.selectedRange() ?? NSRange(location: 0, length: 0)
        guard let command = AskTranslationPanelKeyCommand.command(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            atStart: editor?.isEditable == true && range.location == 0,
            atEnd: editor?.isEditable == true && range.location == (editor?.string.utf16.count ?? 0),
            hasSelection: range.length > 0
        ) else { return false }
        if event.isARepeat, ![.move(-1), .move(1), .history(-1), .history(1)].contains(command) {
            return true
        }
        run(command)
        return true
    }

    private func run(_ command: AskTranslationPanelKeyCommand) {
        switch command {
        case .submit: model.submit()
        case .clear: model.clear()
        case .escape: model.escape()
        case .pin: model.pinned.toggle()
        case .swap: model.swapLanguages()
        case let .copy(number): model.copy(number: number, closes: true)
        case let .move(step): model.moveSelection(step)
        case let .history(step): model.navigateHistory(step)
        case let .language(step): model.cycleLanguage(step)
        case let .action(shortcut): model.shortcut(shortcut)
        }
    }

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) == true ? nil : event
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
                .leftMouseDown,
                .rightMouseDown
            ]) { [weak self] _ in
                self?.model.lostFocus()
            }
        }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.model.lostFocus() } }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        keyMonitor = nil
        clickMonitor = nil
        activationObserver = nil
    }
}

extension AskTranslationPanelController {
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel?.attachedSheet == nil else { return }
        model.lostFocus()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, let panel else { return }
        if !updatingFrame {
            layoutPosition = .lastPosition
        }
        model.settings.defaults.set(["x": Double(panel.frame.minX), "y": Double(panel.frame.minY)],
                                    forKey: "ask.translation.panel.origin")
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel, let screen = sender.screen ?? NSScreen.main else { return frameSize }
        let limit = screen.visibleFrame
        return CGSize(width: min(limit.width, max(AskTranslationPanelPlacement.minimumSize.width, frameSize.width)),
                      height: min(limit.height * model.settings.askTranslationSettings.maxHeight.fraction,
                                  max(AskTranslationPanelPlacement.minimumSize.height, frameSize.height)))
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel?.inLiveResize == true else { return }
        updateRoot()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, let panel else { return }
        model.settings.defaults.set(["width": Double(panel.frame.width), "height": Double(panel.frame.height)],
                                    forKey: "ask.translation.panel.size")
        layoutPosition = .lastPosition
        measuredContentHeight = nil
        refreshLayout()
    }

    private func updateResizeLimits(_ window: NSWindow, on screen: NSScreen) {
        let maximum = CGSize(width: screen.visibleFrame.width,
                             height: screen.visibleFrame.height * model.settings.askTranslationSettings.maxHeight
                                 .fraction)
        window.minSize = CGSize(width: min(AskTranslationPanelPlacement.minimumSize.width, maximum.width),
                                height: min(AskTranslationPanelPlacement.minimumSize.height, maximum.height))
        window.maxSize = maximum
    }

}

final class AskTranslationPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
