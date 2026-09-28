import AppKit
import SwiftUI

@MainActor
final class AskConversationWindowController: NSObject, NSWindowDelegate {
    let model: AskConversationModel
    private let settings: SettingsStore
    private let tools: AskLocalTools?
    private var launcher: AskFloatingPanel?
    private var launcherHeight: CGFloat = 100
    private var conversationWindow: NSWindow?
    private var controlPanel: AskFloatingPanel?
    private var launchTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    var onVoice: () -> Void = {}

    init(settings: SettingsStore, injector: TextInjector, registry: MCPRegistry) throws {
        self.settings = settings
        let tools = AskLocalTools(registry: registry)
        self.tools = tools
        let cache = try AskConversationCache(url: AskConversationCache.defaultURL())
        let deviceKey = "ask.deviceId"
        let deviceId = settings.defaults.string(forKey: deviceKey) ?? UUID().uuidString
        settings.defaults.set(deviceId, forKey: deviceKey)
        model = AskConversationModel(api: AskAPIClient(), cache: cache, tools: tools,
                                     capture: AskContextCapture(injector: injector), deviceId: deviceId) {
            guard let token = AuthState.shared.accessToken, let owner = AuthState.shared.userProfile?.id else { return nil }
            return (owner, token)
        }
        super.init()
        bindCallbacks()
    }

    init(settings: SettingsStore, model: AskConversationModel) {
        self.settings = settings; self.model = model; self.tools = nil
        super.init()
        bindCallbacks()
    }

    private func bindCallbacks() {
        model.onShowConversation = { [weak self] in self?.dismissLauncher(); self?.showConversation() }
        model.onControlChanged = { [weak self] active in self?.showControl(active) }
    }

    func showLauncher() {
        guard launchTask == nil else { return }
        if launcher?.isVisible == true { launcher?.makeKeyAndOrderFront(nil); focusEditor(in: launcher); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            tools?.targetApplication = NSWorkspace.shared.frontmostApplication
        }
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { launchTask = nil }
            await model.prepareLauncher()
            guard !Task.isCancelled else { return }
            if launcher == nil {
                let panel = AskFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
                panel.level = .floating
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.isMovableByWindowBackground = false
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.ask-launcher")
                panel.contentView = NSHostingView(rootView: AskLauncherView(model: model, onVoice: { [weak self] in self?.startVoiceInput() }, onDismiss: { [weak self] in self?.dismissLauncher() }, onHeightChange: { [weak self] height in self?.resizeLauncher(height: height) }))
                launcher = panel
            }
            applyAppearance(launcher)
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let width = min(640, frame.width - 40)
                let height = launcherHeight
                launcher?.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
            }
            NSApp.activate(ignoringOtherApps: true)
            launcher?.makeKeyAndOrderFront(nil)
            focusEditor(in: launcher)
            installClickMonitors()
        }
    }

    private func resizeLauncher(height: CGFloat) {
        launcherHeight = height
        guard let launcher, abs(launcher.frame.height - height) > 1 else { return }
        var frame = launcher.frame
        frame.origin.y -= height - frame.height
        frame.size.height = height
        launcher.setFrame(frame, display: true)
    }

    func dismissLauncher() {
        launchTask?.cancel()
        model.persistDrafts()
        launcher?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }

    func showConversation() {
        if conversationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("workflow.ask.answerTitle")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 560)
            window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.ask-conversations")
            window.setFrameAutosaveName("AskConversationWorkspace")
            window.delegate = self
            window.contentView = NSHostingView(rootView: AskConversationView(model: model, onVoice: { [weak self] in self?.startVoiceInput() }))
            window.center()
            conversationWindow = window
        }
        applyAppearance(conversationWindow)
        NSApp.activate(ignoringOtherApps: true)
        conversationWindow?.makeKeyAndOrderFront(nil)
        focusEditor(in: conversationWindow)
        Task { await model.refreshHistory() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.persistDrafts()
        if model.isBusy || !model.busyIds.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("ask.close.running")
            alert.addButton(withTitle: L("ask.close.continue"))
            alert.addButton(withTitle: L("ask.close.stop"))
            alert.addButton(withTitle: L("ask.close.cancel"))
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                var ids = model.busyIds
                if let selected = model.selected, selected.run?.isActive == true { ids.insert(selected.id) }
                for id in ids { model.stop(id: id) }
            case .alertThirdButtonReturn: return false
            default: break
            }
        }
        sender.orderOut(nil)
        return false
    }

    private func showControl(_ active: Bool) {
        guard active else {
            let wasVisible = controlPanel?.isVisible == true
            controlPanel?.orderOut(nil)
            if wasVisible { conversationWindow?.makeKeyAndOrderFront(nil) }
            return
        }
        conversationWindow?.orderOut(nil)
        if controlPanel == nil {
            let panel = AskFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: AskControlView(model: model))
            controlPanel = panel
        }
        if let frame = NSScreen.main?.visibleFrame { controlPanel?.setFrameOrigin(NSPoint(x: frame.midX - 190, y: frame.minY + 24)) }
        controlPanel?.orderFrontRegardless()
    }

    private func installClickMonitors() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !self.model.recordingIsActive() else { return }
                self.dismissLauncher()
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                if let self, event.window != self.launcher, event.window == self.conversationWindow, !self.model.recordingIsActive() { self.dismissLauncher() }
                return event
            }
        }
    }

    private func startVoiceInput() {
        focusEditor(in: launcher?.isVisible == true ? launcher : conversationWindow)
        onVoice()
    }

    private func applyAppearance(_ window: NSWindow?) {
        switch settings.appearanceMode {
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
    }
    private func focusEditor(in window: NSWindow?) {
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let editor = editor(in: content) { window?.makeFirstResponder(editor) }
    }
}

private final class AskFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct AskControlView: View {
    @ObservedObject var model: AskConversationModel
    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer")
            Text(L("ask.controlling")).font(.system(size: 13))
            Spacer()
            Button(L("ask.stopControl")) { model.stop(id: model.controllingConversationId) }.foregroundStyle(.red)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
