import AppKit
import QuartzCore
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
    var confirmRunningClose: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    let model: AskConversationModel
    private let dockVisibility: DockVisibilityController
    private let settings: SettingsStore
    private let launcherInputSource: any AskLauncherInputSourceSelecting
    private let tools: AskLocalTools?
    private let conversationFrameAutosaveName: NSWindow.FrameAutosaveName
    private var launcher: AskFloatingPanel?
    private var launcherHeight = AskMetrics.launcherHeight(editor: 32, banners: 0)
    private let launcherHeightAnimator = AskLauncherHeightAnimator()
    /// The top edge the launcher opened with; every resize keeps it.
    private var launcherTop: CGFloat?
    private(set) var conversationWindow: NSWindow?
    private var controlPanel: AskFloatingPanel?
    private var launchTask: Task<Void, Never>?
    private(set) var conversationRefreshTask: Task<Void, Never>?
    private(set) var maintenanceTasks: [Task<Void, Never>] = []
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    /// Restyles the launcher, the conversation window and the control panel
    /// as soon as the interface style changes in Settings.
    private lazy var interfaceStyle = InterfaceStyleObserver(settings: settings)

    init(settings: SettingsStore, injector: TextInjector, registry: MCPRegistry, modelLibrary: AskModelLibrary,
         llmService: LLMService? = nil, dockVisibility: DockVisibilityController = .shared,
         launcherInputSource: any AskLauncherInputSourceSelecting = SystemAskLauncherInputSourceSelector(),
         services: AskConversationWindowServices? = nil) throws {
        self.dockVisibility = dockVisibility
        self.settings = settings
        self.launcherInputSource = launcherInputSource
        conversationFrameAutosaveName = services?.frameAutosaveName ?? "AskConversationWorkspace"
        let tools = services?.tools ?? AskLocalTools(registry: registry, settings: settings)
        let sandbox = tools.sandbox
        self.tools = tools
        let cache = try services?.cache ?? AskConversationCache(url: AskConversationCache.defaultURL())
        let deviceKey = "ask.deviceId"
        let deviceId = settings.defaults.string(forKey: deviceKey) ?? UUID().uuidString
        settings.defaults.set(deviceId, forKey: deviceKey)
        let search = AskSearchSettings(defaults: settings.defaults)
        let api: any AskAPI = services?.api ?? AskRoutedAPI(
            cloud: AskAPIClient(), local: AskLocalEngine(webTools: AskLocalWebTools(searchProvider: {
            search.configuration
        }), budgetEnabled: settings.defaults.bool(forKey: "ask.budgetEnabled"), contextLimits: { reference in
            let model = ModelRegistry.read(search.defaults)?.resolve(reference)?.1
            return AskContextLimits(window: model?.contextWindowTokens ?? 32768,
                                    maxOutput: model?.maxOutputTokens ?? 4096,
                                    known: model?.contextWindowTokens != nil)
        }))
        model = AskConversationModel(api: api, cache: cache, tools: tools,
                                     capture: services?.capture ?? AskContextCapture(injector: injector,
                                                                memory: AskMemoryProvider(settings: settings)),
                                     deviceId: deviceId,
                                     modelLibrary: modelLibrary, session: services?.session ?? {
            // Signing in is optional: without a Cloud session every conversation stays on this Mac.
            AskRoutedAPI.session(token: AuthState.shared.accessToken, owner: AuthState.shared.userProfile?.id)
        })
        super.init()
        maintenanceTasks.append(Task.detached(priority: .utility) { sandbox.pruneWorkspaces() })
        // Keyword plugins: translation falls back to the text-processing model, and
        // ⌥Return types results into the app the launcher came from.
        if let llmService {
            // Translation may have a model of its own; without one it uses the text-processing model.
            model.translationAI = AskAITranslationEngine(
                service: AskTranslationLLMService(settings: settings, textProcessing: llmService)
            ) { [weak settings] in
                AskPluginRegistry.translationModelName(settings)
            }
            model.promptAI = AskLLMTextGenerator(service: llmService)
        }
        let workflows = services?.workflows ?? AskWorkflowStore.shared
        model.workflows = workflows
        let authoring = AskWorkflowAuthoringStore(workflows: workflows, owner: { GlobalSoulOwner.currentID })
        tools.workflowAuthoring = authoring
        model.workflowAuthoring = authoring
        authoring.onChange = { [weak model] in model?.objectWillChange.send() }
        // The word book: words the translation plugin looked up, and the ones starred.
        let wordBook = services?.wordBook ?? SQLiteAskWordBookStore(url: SQLiteAskWordBookStore.defaultURL())
        // Forever keeps everything; `purgeHistory(before: nil)` would clear it instead.
        if let cutoff = settings.askWordBookRetention.cutoff(now: Date()) {
            maintenanceTasks.append(Task.detached(priority: .utility) { wordBook.purgeHistory(before: cutoff) })
        }
        model.wordBook = AskWordBookRecorder(store: wordBook) { [weak settings] in
            settings?.askWordBookRecordsHistory ?? true
        }
        let wordBookWindow = services?.wordBookWindow ?? AskWordBookWindowController.shared
        wordBookWindow.configure(
            store: wordBook, dictionary: model.translationAI as? any AskWordLookingUp, settings: settings,
            askAI: { [weak model] prompt in
                // A new conversation about the word, without the launcher's selection or screenshot.
                model?.launcherDraft = AskDraft(text: prompt, includeScreenshot: false, selection: nil)
                model?.submitLauncher()
            }
        ) { [weak settings] in AskPluginRegistry.translationModelName(settings) }
        model.deliverText = { text in
            let result = try await injector.deliver(text: text, to: .currentInput)
            if case .notApplied = result { throw TextDeliveryError.noInput }
        }
        // Saved AI prompt results, and the windows results and notes open in.
        let notes = services?.notes ?? SQLiteAskNoteStore(url: SQLiteAskNoteStore.defaultURL())
        model.notes = notes
        let askAboutResult: @MainActor (String) -> Void = { [weak model] prompt in
            // A new conversation about the result, without the launcher's selection or screenshot.
            model?.launcherDraft = AskDraft(text: prompt, includeScreenshot: false, selection: nil)
            model?.submitLauncher()
        }
        let notesWindow = services?.notesWindow ?? AskNotesWindowController.shared
        notesWindow.configure(store: notes, askAI: askAboutResult) { [weak settings] in
            settings.flatMap { AppAppearance.nsAppearance(for: $0.appearanceMode) }
        }
        let resultWindow = services?.resultWindow ?? AskResultWindowController.shared
        resultWindow.appearance = { [weak settings] in
            settings.flatMap { AppAppearance.nsAppearance(for: $0.appearanceMode) }
        }
        resultWindow.services = AskResultDocument.Services(
            saveNote: { draft in
                let note = AskNote(draft: draft, at: Date())
                return notes.save(note) ? note.id : nil
            },
            removeNote: { id in
                guard let note = notes.note(id: id), !note.isEdited else { return false }
                notes.delete(ids: [id])
                return true
            },
            noteExists: { notes.note(id: $0) != nil },
            openNotes: { notesWindow.show(selecting: $0) },
            insert: { text, bundleID in
                guard let bundleID,
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                else { return false }
                app.activate(options: [.activateIgnoringOtherApps])
                // Let the app take focus back before typing into it.
                try? await Task.sleep(for: .milliseconds(300))
                guard let result = try? await injector.deliver(text: text, to: .currentInput) else { return false }
                if case .notApplied = result { return false }
                return true
            },
            askAI: askAboutResult,
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        )
        model.commandSources = AskCommandSources(
            skills: { tools.enabledSkills },
            mcpServers: { MCPSettingsStore().servers.map { AskMCPServerSummary(name: $0.name, enabled: $0.enabled) } },
            remember: { text in try AskMemoryNoteStore.shared.add(text, owner: GlobalSoulOwner.currentID) },
            privateByDefault: { settings.askNewConversationsStayLocal }
        )
        bindCallbacks()
    }

    init(settings: SettingsStore, model: AskConversationModel, dockVisibility: DockVisibilityController = .shared,
         conversationFrameAutosaveName: NSWindow.FrameAutosaveName = "AskConversationWorkspace",
         launcherInputSource: any AskLauncherInputSourceSelecting = SystemAskLauncherInputSourceSelector()) {
        self.dockVisibility = dockVisibility
        self.settings = settings; self.model = model; self.tools = nil
        self.launcherInputSource = launcherInputSource
        self.conversationFrameAutosaveName = conversationFrameAutosaveName
        super.init()
        bindCallbacks()
    }

    private func bindCallbacks() {
        model.onShowConversation = { [weak self] in self?.showConversation() }
        model.onControlChanged = { [weak self] active in self?.showControl(active) }
        model.onCreditsExhausted = {
            Task { @MainActor in
                AuthState.shared.invalidateAccountSummary()
                await AuthState.shared.refreshAccountSummary()
            }
        }
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
        model.quickSearch.setVisible(true)
        model.refreshQuickApps()
        Task { [model] in await model.refreshLauncherWorkflows() }
        Task { [model] in await model.loadCachedHistoryIfNeeded() }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            tools?.targetApplication = NSWorkspace.shared.frontmostApplication
        }
        let selectionRequest = model.makeLauncherSelectionRequest()
        let panel = launcherPanel()
        applyAppearance(panel)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let width = min(AskMetrics.launcherWidth, frame.width - 40)
            let anchor = launcherAnchor(on: screen)
            panel.setFrame(AskLauncherPlacement.frame(height: launcherHeight, width: width, screen: frame, anchor: anchor),
                           display: true)
            launcherTop = AskLauncherPlacement.top(on: frame, anchor: anchor)
        }
        // Take keyboard focus without activating the app and raising its other windows.
        panel.makeKeyAndOrderFront(nil)
        // Select after focus: AppKit may restore the editor's previous source
        // when it becomes first responder. Do this only on a fresh opening.
        if focusEditor(in: panel) { launcherInputSource.selectEnglish() }
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
        let drag = AskWindowDragHandlers(
            move: { [weak self] origin in self?.dragLauncher(to: origin) ?? origin },
            end: { [weak self] in self?.finishLauncherDrag() },
            reset: { [weak self] in self?.recenterLauncher() }
        )
        let hosting = FirstMouseHostingView(rootView: AskLauncherView(model: model, onDismiss: { [weak self] in self?.dismissLauncher() }, onHeightChange: { [weak self] height in self?.resizeLauncher(height: height) }, drag: drag)
            .interfaceStyle(following: interfaceStyle))
        // Only `resizeLauncher` sizes the panel. Left to itself, the hosting view resizes the
        // window from its bottom edge as content changes, moving the top edge while typing.
        hosting.sizingOptions = []
        panel.contentView = hosting
        launcher = panel
        return panel
    }

    /// Builds the launcher panel and lays out its view while the app is idle.
    func prewarmLauncher() {
        model.quickSearch.setVisible(launcher?.isVisible == true)
        model.refreshQuickApps()
        Task { [model] in await model.refreshLauncherWorkflows() }
        Task { [model] in await model.loadCachedHistoryIfNeeded() }
        let panel = launcherPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeLauncher(height: CGFloat) {
        launcherHeight = height
        guard let launcher else { return }
        launcherHeightAnimator.update(from: launcher.frame.height, to: height,
                                      animated: launcher.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                      framesPerSecond: launcher.screen?.maximumFramesPerSecond ?? 60,
                                      rate: model.launcherDraft.text.isEmpty ? 60 : 28) { [weak self, weak launcher] height in
            guard let self, let launcher else { return }
            // Commit bounds and content together; controls must never animate their
            // layer positions separately from the window's changing coordinate space.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            launcher.setFrame(AskLauncherPlacement.resized(launcher.frame, height: height, top: self.launcherTop,
                                                           screen: launcher.screen?.visibleFrame), display: false)
            launcher.contentView?.layoutSubtreeIfNeeded()
            launcher.displayIfNeeded()
            CATransaction.commit()
        }
    }

    // MARK: - Launcher position

    /// Where the launcher opens on `screen`: centred, or where it was left there.
    private func launcherAnchor(on screen: NSScreen) -> AskLauncherPlacement.Anchor? {
        guard settings.askLauncherPosition == .lastPosition else { return nil }
        return settings.askLauncherAnchors[AskLauncherPlacement.key(for: screen)]
    }

    /// The launcher panel once it has been shown, for tests that move it.
    var launcherWindow: NSWindow? { launcher }

    var controlWindow: NSWindow? { controlPanel }

    /// Whether the launcher is still moving to the height its content last asked for.
    var launcherIsResizing: Bool { launcherHeightAnimator.isAnimating }

    /// The screen the launcher is on, or the main one before it has been shown.
    private var launcherScreen: NSScreen? { launcher?.screen ?? NSScreen.main }

    /// While dragged the launcher follows the pointer, snapping to its screen's centre line.
    /// Results arriving mid-drag grow it down from where it is now, not where it opened.
    func dragLauncher(to origin: NSPoint) -> NSPoint {
        guard let launcher, let screen = launcherScreen else { return origin }
        let snapped = AskLauncherPlacement.snapped(origin: origin, width: launcher.frame.width, screen: screen.visibleFrame)
        launcherTop = snapped.y + launcher.frame.height
        return snapped
    }

    /// Let go: back inside the screen, growing down from its new top edge, and
    /// remembered for next time when the user chose that.
    func finishLauncherDrag() {
        guard let launcher, let screen = launcherScreen else { return }
        let visible = screen.visibleFrame
        let frame = AskLauncherPlacement.clamped(launcher.frame, screen: visible)
        if frame != launcher.frame { launcher.setFrame(frame, display: true) }
        launcherTop = frame.maxY
        guard settings.askLauncherPosition == .lastPosition else { return }
        settings.askLauncherAnchors[AskLauncherPlacement.key(for: screen)] = AskLauncherPlacement.anchor(of: frame, on: visible)
    }

    /// Double-clicking the top edge: back to the middle, forgetting this screen's position.
    func recenterLauncher() {
        guard let launcher, let screen = launcherScreen else { return }
        settings.askLauncherAnchors[AskLauncherPlacement.key(for: screen)] = nil
        let visible = screen.visibleFrame
        launcher.setFrame(AskLauncherPlacement.frame(height: launcher.frame.height, width: launcher.frame.width,
                                                     screen: visible), display: true)
        launcherTop = AskLauncherPlacement.top(on: visible)
    }

    func dismissLauncher() {
        launcherHeightAnimator.stop()
        // Menus and hover cards are child panels; close them with the launcher so
        // their buttons do not reopen into a stale state next time.
        AskGlassMenuPresenter.shared.hide()
        model.voiceInput.cancel()
        launchTask?.cancel()
        launchTask = nil
        model.foldLauncherKeyword()
        model.persistDrafts()
        model.quickSearch.setVisible(false)
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
            window.identifier = NSUserInterfaceItemIdentifier("ai.gulu.app.typeflux.window.ask-conversations")
            window.delegate = self
            // An empty unified toolbar gives the title bar its 52pt height and centres
            // the traffic lights, so the in-window tools can share their centre line.
            window.toolbar = NSToolbar(identifier: "ai.gulu.app.typeflux.ask-conversations.toolbar")
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            let hosting = TransparentAskHostingView(rootView: AskConversationView(model: model)
                .interfaceStyle(following: interfaceStyle))
            // The window owns its size: without this, resizing content (e.g. hiding
            // the sidebar) can make the hosting view resize or zoom the window.
            hosting.sizingOptions = []
            window.contentView = hosting
            // NSHostingView uses Auto Layout, which supersedes NSWindow.minSize.
            // Constrain its actual viewport after installation so subsequent SwiftUI
            // layouts cannot silently remove the supported minimum window size.
            let minimum = AskWorkspaceLayout.minimumWindowSize
            NSLayoutConstraint.activate([
                hosting.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width),
                hosting.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height)
            ])
            window.contentMinSize = minimum
            window.setFrameAutosaveName(conversationFrameAutosaveName)
            if window.setFrameUsingName(conversationFrameAutosaveName) {
                // Growing an obsolete undersized frame must not push its controls
                // below the visible screen, including after a display change.
                let visibleFrame = window.constrainFrameRect(window.frame, to: window.screen)
                window.setFrame(visibleFrame, display: false)
            } else {
                window.center()
            }
            conversationWindow = window
        }
        guard let conversationWindow else { return }
        applyAppearance(conversationWindow)
        dockVisibility.windowDidShow(conversationWindow)
        if conversationWindow.isMiniaturized { conversationWindow.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        conversationWindow.makeKeyAndOrderFront(nil)
        focusEditor(in: conversationWindow)
        conversationRefreshTask = Task { await model.refreshHistory(); await model.loadSavedChatDrafts() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.persistDrafts()
        // A run paused for credits waits on the server; closing the window loses nothing.
        if (model.isBusy && model.selected?.run?.isPausedForCredits != true) || !model.busyIds.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("ask.close.running")
            alert.addButton(withTitle: L("ask.close.continue"))
            alert.addButton(withTitle: L("ask.close.stop"))
            alert.addButton(withTitle: L("ask.close.cancel"))
            switch confirmRunningClose(alert) {
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
            panel.contentView = NSHostingView(rootView: AskControlView(model: model)
                .interfaceStyle(following: interfaceStyle))
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
    @discardableResult
    private func focusEditor(in window: NSWindow?) -> Bool {
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        guard let content = window?.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        guard let editor = editor(in: content) else { return false }
        return window?.makeFirstResponder(editor) == true
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
