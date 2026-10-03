import AppKit
import SwiftUI

final class TransparentAskHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// The launcher is a non-activating panel, so it is often not key when the
/// pointer reaches it. Without this the first click on a chip or button only
/// made the panel key and was otherwise dropped.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AskConversationWindowController: NSObject, NSWindowDelegate {
    let model: AskConversationModel
    private let dockVisibility: DockVisibilityController
    private let settings: SettingsStore
    private let tools: AskLocalTools?
    private var launcher: AskFloatingPanel?
    private var launcherHeight = AskMetrics.launcherHeight(editor: 32, banners: 0)
    private var conversationWindow: NSWindow?
    private var controlPanel: AskFloatingPanel?
    private var launchTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?

    init(settings: SettingsStore, injector: TextInjector, registry: MCPRegistry, modelLibrary: AskModelLibrary,
         dockVisibility: DockVisibilityController = .shared) throws {
        self.dockVisibility = dockVisibility
        self.settings = settings
        let tools = AskLocalTools(registry: registry, settings: settings)
        let sandbox = tools.sandbox
        Task.detached(priority: .utility) { sandbox.pruneWorkspaces() }
        self.tools = tools
        let cache = try AskConversationCache(url: AskConversationCache.defaultURL())
        let deviceKey = "ask.deviceId"
        let deviceId = settings.defaults.string(forKey: deviceKey) ?? UUID().uuidString
        settings.defaults.set(deviceId, forKey: deviceKey)
        let search = AskSearchSettings(defaults: settings.defaults)
        let api = AskRoutedAPI(cloud: AskAPIClient(), local: AskLocalEngine(webTools: AskLocalWebTools(searchProvider: {
            (search.provider, search.apiKey)
        })))
        model = AskConversationModel(api: api, cache: cache, tools: tools,
                                     capture: AskContextCapture(injector: injector,
                                                                memory: AskMemoryProvider(settings: settings)),
                                     deviceId: deviceId,
                                     modelLibrary: modelLibrary) {
            // Signing in is optional: without a Cloud session every conversation stays on this Mac.
            AskRoutedAPI.session(token: AuthState.shared.accessToken, owner: AuthState.shared.userProfile?.id)
        }
        super.init()
        model.commandSources = AskCommandSources(
            skills: { tools.enabledSkills },
            mcpServers: { MCPSettingsStore().servers.map { AskMCPServerSummary(name: $0.name, enabled: $0.enabled) } },
            remember: { text in try AskMemoryNoteStore.shared.add(text, owner: GlobalSoulOwner.currentID) },
            privateByDefault: { settings.askNewConversationsStayLocal }
        )
        bindCallbacks()
    }

    init(settings: SettingsStore, model: AskConversationModel, dockVisibility: DockVisibilityController = .shared) {
        self.dockVisibility = dockVisibility
        self.settings = settings; self.model = model; self.tools = nil
        super.init()
        bindCallbacks()
    }

    private func bindCallbacks() {
        model.onShowConversation = { [weak self] in self?.showConversation() }
        model.onControlChanged = { [weak self] active in self?.showControl(active) }
    }

    func toggleLauncher() {
        if launchTask != nil || launcher?.isVisible == true {
            dismissLauncher()
        } else {
            showLauncher()
        }
    }

    /// Shows the launcher at once, then fills in its context. The panel never
    /// activates the app, so the source app stays frontmost while its selection,
    /// screenshot and memory are captured behind the visible panel (our own
    /// windows are excluded from the screenshot). Capturing first used to hold
    /// the panel back by a few hundred milliseconds on every press.
    func showLauncher() {
        // Already open (its context may still be arriving): just bring the editor back.
        if launcher?.isVisible == true { launcher?.makeKeyAndOrderFront(nil); focusEditor(in: launcher); return }
        guard launchTask == nil else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            tools?.targetApplication = NSWorkspace.shared.frontmostApplication
        }
        let selectionRequest = model.makeLauncherSelectionRequest()
        let panel = launcherPanel()
        applyAppearance(panel)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let width = min(AskMetrics.launcherWidth, frame.width - 40)
            panel.setFrame(AskLauncherPlacement.frame(height: launcherHeight, width: width, screen: frame), display: true)
        }
        // Take keyboard focus without activating the app and raising its other windows.
        panel.makeKeyAndOrderFront(nil)
        focusEditor(in: panel)
        installClickMonitors()
        launchTask = Task { [weak self] in
            guard let self else { return }
            // A cancelled launch must not clear a newer launch task.
            defer { if !Task.isCancelled { launchTask = nil } }
            guard !Task.isCancelled else { return }
            await model.prepareLauncher(request: selectionRequest)
        }
    }

    /// The launcher panel, built once and reused. `prewarmLauncher()` builds it
    /// ahead of the first press so that press pays no setup cost.
    private func launcherPanel() -> AskFloatingPanel {
        if let launcher { return launcher }
        let panel = AskFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: AskMetrics.launcherWidth, height: launcherHeight),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.ask-launcher")
        panel.contentView = FirstMouseHostingView(rootView: AskLauncherView(model: model, onDismiss: { [weak self] in self?.dismissLauncher() }, onHeightChange: { [weak self] height in self?.resizeLauncher(height: height) }))
        launcher = panel
        return panel
    }

    /// Builds the launcher panel and lays out its view while the app is idle.
    func prewarmLauncher() {
        let panel = launcherPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeLauncher(height: CGFloat) {
        launcherHeight = height
        guard let launcher, abs(launcher.frame.height - height) > 1 else { return }
        launcher.setFrame(AskLauncherPlacement.resized(launcher.frame, height: height,
                                                       screen: launcher.screen?.visibleFrame), display: true)
    }

    func dismissLauncher() {
        // Menus and hover cards are child panels; close them with the launcher so
        // their buttons do not reopen into a stale state next time.
        AskGlassMenuPresenter.shared.hide()
        model.voiceInput.cancel()
        launchTask?.cancel()
        launchTask = nil
        model.persistDrafts()
        launcher?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
    }

    func showConversation() {
        dismissLauncher()
        if conversationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            // Translucent like the settings window, so both share the same glass.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.title = L("workflow.ask.answerTitle")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 560)
            window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.ask-conversations")
            window.setFrameAutosaveName("AskConversationWorkspace")
            window.delegate = self
            // An empty unified toolbar gives the title bar its 52pt height and centres
            // the traffic lights, so the in-window tools can share their centre line.
            window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.ask-conversations.toolbar")
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            let hosting = TransparentAskHostingView(rootView: AskConversationView(model: model))
            // The window owns its size: without this, resizing content (e.g. hiding
            // the sidebar) can make the hosting view resize or zoom the window.
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            conversationWindow = window
        }
        guard let conversationWindow else { return }
        applyAppearance(conversationWindow)
        dockVisibility.windowDidShow(conversationWindow)
        if conversationWindow.isMiniaturized { conversationWindow.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        conversationWindow.makeKeyAndOrderFront(nil)
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
        model.voiceInput.cancel()
        sender.orderOut(nil)
        dockVisibility.windowDidHide(sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        dockVisibility.windowDidHide(window)
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
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(StudioTheme.warning)
            Text(L("ask.controlling")).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Button(L("ask.stopControl")) { model.stop(id: model.controllingConversationId) }
                .foregroundStyle(StudioTheme.danger)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(AskTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.border))
    }
}
