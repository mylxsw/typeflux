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
    private var measuredContentHeight: CGFloat?
    private lazy var style = InterfaceStyleObserver(settings: model.settings)

    init(model: AskTranslationPanelModel) {
        self.model = model
        super.init()
        model.onDismiss = { [weak self] in self?.hide() }
        observation = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshLayout() }
        }
    }

    deinit {
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

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
        if let content = panel?.contentView, let editor = editor(in: content) {
            panel?.makeFirstResponder(editor)
        }
    }

    func present(selection: CGRect? = nil) {
        let window = makePanel()
        applyAppearance(window)
        let mouse = NSEvent.mouseLocation
        let screen = selection.flatMap { bounds in NSScreen.screens.first { $0.frame.intersects(bounds) } }
            ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            let last = model.settings.defaults.dictionary(forKey: "ask.translation.panel.origin")
            let origin: CGPoint? = (last?["x"] as? Double).flatMap { horizontal in
                (last?["y"] as? Double).map { CGPoint(x: horizontal, y: $0) }
            }
            let frame = AskTranslationPanelPlacement.frame(size: desiredSize(on: screen),
                                                           screen: screen.visibleFrame,
                                                           position: model.settings.askTranslationSettings
                                                               .panelPosition,
                                                           mouse: mouse, last: origin,
                                                           selection: selection)
            window.setFrame(frame, display: false)
        }
        updateRoot()
        window.makeKeyAndOrderFront(nil)
        installMonitors()
        focus()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel?.attachedSheet == nil else { return }
        model.lostFocus()
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, let panel else { return }
        model.settings.defaults.set(["x": Double(panel.frame.minX), "y": Double(panel.frame.minY)],
                                    forKey: "ask.translation.panel.origin")
    }

    func refreshLayout() {
        guard let panel, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        let size = desiredSize(on: screen)
        let frame = AskTranslationPanelPlacement.frame(size: size, screen: screen.visibleFrame,
                                                       position: .lastPosition, mouse: NSEvent.mouseLocation,
                                                       last: CGPoint(
                                                           x: panel.frame.minX,
                                                           y: panel.frame.maxY - size.height
                                                       ))
        panel.setFrame(frame, display: true)
        updateRoot()
    }

    private func desiredSize(on screen: NSScreen) -> CGSize {
        let editor = min(
            96,
            max(48, CGFloat(model.text.split(separator: "\n", omittingEmptySubsequences: false).count) * 21)
        )
        let chrome = AskTranslationPanelView.chromeHeight(screenshot: model.screenshot != nil) + editor - 48
            + (model.notice == nil ? 0 : 24)
        return CGSize(width: min(AskTranslationPanelPlacement.width, screen.visibleFrame.width),
                      height: AskTranslationPanelPlacement.height(
                          content: measuredContentHeight ?? (chrome + AskTranslationStackView.height(model.stack)),
                          screen: screen.visibleFrame,
                          preference: model.settings.askTranslationSettings.maxHeight
                      ))
    }

    private func makePanel() -> AskTranslationPanelWindow {
        if let panel {
            return panel
        }
        let window = AskTranslationPanelWindow(contentRect: CGRect(x: 0, y: 0, width: 452, height: 400),
                                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                               defer: false)
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

final class AskTranslationPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
