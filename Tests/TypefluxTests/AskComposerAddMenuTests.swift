import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The "+" menu holds the context switches the bar no longer shows, the selected
/// text keeps its icon chip, and a task's folders and permission share one control.
@Suite("Ask composer add menu", .serialized, .exclusiveUIState)
@MainActor
struct AskComposerAddMenuTests {
    private func items(screenshot: AskScreenshotState = .off, source: String? = nil, selection: String? = nil,
                       selectionOff: Bool = false, memory: AskMemory? = nil, memoryOff: Bool = false,
                       pinned: AskMemory? = nil) -> [AskContextItem] {
        AskContextChips.items(screenshot: screenshot, source: source, sourceBundleID: nil, selection: selection,
                              selectionOff: selectionOff, memory: memory, memoryOff: memoryOff,
                              memoryPinned: pinned != nil, pinnedMemory: pinned)
    }

    // MARK: - Switches

    @Test func switchesFollowTheMenuOrderAndLeaveSourceOut() {
        let switches = AskAddMenuSwitch.make(
            items: items(source: "Safari — Docs", selection: "a\nb", memory: AskMemory(global: "short")),
            selectionText: "a\nb", actions: { _ in {} })
        #expect(switches.map(\.kind) == [.screenshot, .memory, .selection])
        #expect(switches.map(\.title) == [L("ask.add.screenshot"), L("ask.memory"), L("ask.selection")])
        let allEnabled = switches.allSatisfy { $0.enabled }
        #expect(allEnabled)
    }

    @Test func screenshotSwitchReflectsEveryCaptureState() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        func screenshot(_ state: AskScreenshotState, action: Bool = true) -> AskAddMenuSwitch? {
            AskAddMenuSwitch.make(items: items(screenshot: state), selectionText: nil, screenshot: image,
                                  actions: { _ in action ? {} : nil }).first
        }
        let off = try #require(screenshot(.off))
        #expect(!off.isOn)
        #expect(off.detail == L("ask.add.screenshot.offDetail"))
        let attached = screenshot(.attached)
        #expect(attached?.isOn == true)
        #expect(attached?.detail == L("ask.context.screen.scope"))
        #expect(attached?.thumbnail === image)
        let failed = screenshot(.failed(permission: true, message: "Allow screen recording"))
        #expect(failed?.isOn == true, "A failed capture is still included until switched off")
        #expect(failed?.warning == true)
        #expect(failed?.detail == "Allow screen recording")
        #expect(failed?.thumbnail == nil)
        let unavailable = screenshot(.unavailable(reason: "No vision"), action: false)
        #expect(unavailable?.enabled == false)
        #expect(unavailable?.detail == "No vision")
        #expect(unavailable?.thumbnail == nil)
    }

    @Test func memorySwitchDescribesNewAndPinnedMemory() {
        let fresh = AskAddMenuSwitch.make(items: items(memory: AskMemory(global: "short"), memoryOff: true),
                                          selectionText: nil, actions: { _ in {} })
        let freshMemory = fresh.last
        #expect(freshMemory?.kind == .memory)
        #expect(freshMemory?.isOn == false)
        #expect(freshMemory?.detail == L("ask.memory.help"))
        let pinned = AskAddMenuSwitch.make(items: items(pinned: AskMemory(global: "short")),
                                           selectionText: nil, actions: { _ in {} })
        let pinnedMemory = pinned.last
        #expect(pinnedMemory?.kind == .memory)
        #expect(pinnedMemory?.isOn == true)
        #expect(pinnedMemory?.detail == L("ask.memory.pinned"))
        let none = AskAddMenuSwitch.make(items: items(), selectionText: nil, actions: { _ in {} })
        #expect(none.map(\.kind) == [.screenshot], "No memory, no switch")
    }

    @Test func selectionSwitchNamesItsAppLinesAndPreview() throws {
        let text = "first line\nsecond line\nthird"
        let withApp = try #require(AskAddMenuSwitch.make(
            items: items(source: "Safari — Docs", selection: text), selectionText: text,
            actions: { _ in {} }).last)
        #expect(withApp.kind == .selection && withApp.isOn)
        #expect(withApp.detail == L("ask.add.selection.detail", "Safari", 3))
        #expect(withApp.preview == AskContextChips.selectionPreview(text))
        let off = try #require(AskAddMenuSwitch.make(items: items(selection: text, selectionOff: true),
                                                     selectionText: text, actions: { _ in nil }).last)
        #expect(!off.isOn && !off.enabled)
        #expect(off.detail == L("ask.selection.lines", 3))
    }

    @Test func switchActionRunsTheComposerToggle() throws {
        var toggled: [AskContextItem.Kind] = []
        let switches = AskAddMenuSwitch.make(items: items(selection: "x", memory: AskMemory(global: "m")),
                                             selectionText: "x", actions: { kind in { toggled.append(kind) } })
        switches.forEach { $0.action() }
        #expect(toggled == [.screenshot, .memory, .selection])
    }

    // MARK: - Menu rendering

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 420, height: 520)) -> NSWindow {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height,
                                                                 alignment: .bottomLeading))
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> NSObject? {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }

    private func press(_ identifier: String, in window: NSWindow) throws {
        let element = try #require(find(identifier, in: window), "Missing \(identifier)")
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
    }

    @Test func menuListsFilesSwitchesStorageAndRestoreRows() async throws {
        var picked = 0
        var chosen: [AskStorageKind] = []
        var restored = 0
        var memoryToggles = 0
        let storage = AskLocalModeStatus(source: "Cloud", offersSignIn: false, local: false, changeable: true,
                                         choices: [.cloud, .local, .temporary])
        let context = AskAddMenuContext(
            switches: AskAddMenuSwitch.make(items: items(selection: "x", memory: AskMemory(global: "m")),
                                            selectionText: "x",
                                            actions: { kind in kind == .memory ? { memoryToggles += 1 } : {} }),
            storage: storage, chooseStorage: { chosen.append($0) },
            sourceToRestore: "Safari", restoreSource: { restored += 1 })
        let window = host(AskComposerAddMenu(context: context) { picked += 1 })
        defer { window.close() }
        try await settle(window)
        for identifier in ["ask.add.menu", "ask.add.files", "ask.add.screenshot", "ask.add.memory",
                           "ask.add.selection", "ask.context.restore.source",
                           "ask.add.storage.cloud", "ask.add.storage.local", "ask.add.storage.temporary"] {
            #expect(find(identifier, in: window) != nil, "Missing \(identifier)")
        }
        try press("ask.add.files", in: window)
        try press("ask.add.memory", in: window)
        try press("ask.add.storage.temporary", in: window)
        try press("ask.context.restore.source", in: window)
        #expect(picked == 1)
        #expect(memoryToggles == 1)
        #expect(chosen == [.temporary])
        #expect(restored == 1)
    }

    @Test func startedConversationMenuHasNoStorageChoice() async throws {
        let window = host(AskComposerAddMenu(context: AskAddMenuContext(
            switches: AskAddMenuSwitch.make(items: items(), selectionText: nil, actions: { _ in {} })), pickFiles: {}))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.add.screenshot", in: window) != nil)
        #expect(find("ask.add.storage.cloud", in: window) == nil)
        #expect(find("ask.context.restore.source", in: window) == nil)
    }

    // MARK: - Composer integration

    @Test func workspaceFooterKeepsOnlyTheSelectionChip() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.draft.memory = AskMemory(global: "short")
        let window = host(AskComposer(model: fixture.model, launcher: false), size: NSSize(width: 760, height: 240))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.composer.attach", in: window) != nil)
        #expect(find("ask.context.screenshot.toggle", in: window) == nil)
        #expect(find("ask.context.memory.toggle", in: window) == nil)
        #expect(find("ask.context.menu", in: window) == nil)
        #expect(find("ask.context.selection.toggle", in: window) == nil, "No selected text, no chip")
        #expect(find("ask.composer.voice", in: window) != nil, "Voice keeps its own button")

        fixture.model.draft.selection = "picked text"
        try await settle(window)
        #expect(find("ask.context.selection.toggle", in: window) != nil)
        try press("ask.context.selection.toggle", in: window)
        try await fixture.wait { fixture.model.draft.selectionOff == true }
        #expect(find("ask.context.selection.toggle", in: window) != nil,
                "An excluded selection keeps its grey chip so it can be included again")
    }

    @Test func workspacePlusMenuTogglesMemoryAndLeavesStorageToTheBar() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        fixture.model.draft.memory = AskMemory(global: "short")
        let window = host(AskComposer(model: fixture.model, launcher: false), size: NSSize(width: 760, height: 240))
        defer { window.close() }
        try await settle(window)
        try press("ask.composer.attach", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await fixture.wait { self.find("ask.add.screenshot", in: panel) != nil }
        // The new page's bar chooses storage; memory stays in the "+" menu.
        #expect(find("ask.add.storage.cloud", in: panel) == nil)
        try press("ask.add.memory", in: panel)
        try await fixture.wait { fixture.model.memorySwitchedOff(launcher: false) }
        AskGlassMenuPresenter.shared.hide()

        fixture.model.draft.text = "Hello"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.selectedId != nil }
        try await settle(window)
        try press("ask.composer.attach", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let started = try #require(AskGlassMenuPresenter.shared.panel)
        try await settle(started)
        #expect(find("ask.add.menu", in: started) != nil)
        #expect(find("ask.add.storage.cloud", in: started) == nil, "A started conversation keeps where it is stored")
    }

    @Test func environmentMenuPicksPermissionAndOffersFolders() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        fixture.model.setConversationKind(.work, launcher: false)
        let window = host(AskWorkEnvironmentButton(model: fixture.model), size: NSSize(width: 400, height: 80))
        defer { window.close() }
        try await settle(window)
        let button = try #require(find("ask.composer.permissionMode", in: window))
        #expect(button.value(forKey: "accessibilityValue") as? String == L("ask.kind.defaultWorkspace"))
        try press("ask.composer.permissionMode", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await settle(panel)
        #expect(find("ask.env.addFolder", in: panel) != nil)
        for mode in AskPermissionMode.allCases {
            #expect(find("ask.env.mode." + mode.rawValue, in: panel) != nil)
        }
        try press("ask.env.mode.yolo", in: panel)
        try await fixture.wait { fixture.model.permissionMode(launcher: false) == .yolo }
        // Choosing a mode closes the menu.
        try await fixture.wait { !AskGlassMenuPresenter.shared.isShowing }
    }

    @Test func foldersStayInEnvironmentMenuAndCanBeRemovedIndividually() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession(); AskGlassMenuPresenter.shared.hide() }
        fixture.model.setConversationKind(.work, launcher: false)
        let first = AskAttachment(kind: .folder, name: "Project", path: "/tmp/project")
        let second = AskAttachment(kind: .folder, name: "Docs", path: "/tmp/docs")
        let file = AskAttachment(kind: .file, name: "notes.txt", text: "Notes")
        fixture.model.draft.attachments = [first, second, file]
        #expect(AskComposer.inlineAttachments(fixture.model.draft) == [file])
        let window = host(AskWorkEnvironmentButton(model: fixture.model), size: NSSize(width: 400, height: 80))
        defer { window.close() }
        try await settle(window)
        try press("ask.composer.permissionMode", in: window)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let panel = try #require(AskGlassMenuPresenter.shared.panel)
        try await settle(panel)
        #expect(find("ask.env.folder." + first.id, in: panel) != nil)
        #expect(find("ask.env.folder." + second.id, in: panel) != nil)
        try press("ask.env.removeFolder." + first.id, in: panel)
        try await settle(panel)
        #expect(find("ask.env.folder." + first.id, in: panel) == nil)
        #expect(find("ask.env.folder." + second.id, in: panel) != nil)
        #expect(fixture.model.draft.attachments == [second, file])
    }

    @Test func temporarySidebarRowSeparatesResumeAndCloseActions() async throws {
        var selected = 0, closed = 0
        let window = host(AskTemporaryHistoryRow(selected: false, onSelect: { selected += 1 }, onClose: { closed += 1 }),
                          size: NSSize(width: 260, height: 60))
        defer { window.close() }
        try await settle(window)
        try press("ask.history.temporary.select", in: window)
        #expect(selected == 1 && closed == 0)
        try press("ask.history.temporary.close", in: window)
        #expect(selected == 1 && closed == 1)
    }

    @Test func chatComposerHasNoEnvironmentControl() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.setConversationKind(.chat, launcher: false)
        let window = host(AskComposer(model: fixture.model, launcher: false), size: NSSize(width: 760, height: 240))
        defer { window.close() }
        try await settle(window)
        #expect(find("ask.composer.permissionMode", in: window) == nil)
        fixture.model.setConversationKind(.work, launcher: false)
        try await settle(window)
        #expect(find("ask.composer.permissionMode", in: window) != nil)
    }

    // MARK: - Snapshots

    /// Renders the redesign for review when `TYPEFLUX_ASK_SNAPSHOTS` names a directory.
    @Test func renderComposerRedesign() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        func save<V: View>(_ view: V, size: NSSize, name: String) async throws {
            let window = host(view, size: size)
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            try await settle(window)
            let content = try #require(window.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent(name + ".png"))
        }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.setConversationKind(.work, launcher: false)
        fixture.model.draft.attachments = [.init(kind: .folder, name: "Downloads", path: "/tmp/Downloads"),
                                            .init(kind: .folder, name: "Project", path: "/tmp/Project")]
        fixture.model.draft.selection = "Liquid Glass 是一种动态材质"
        fixture.model.draft.memory = AskMemory(global: "short")
        try await save(AskComposer(model: fixture.model, launcher: false).padding(20)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 800, height: 170), name: "gul462-window-composer")
        let environmentWindow = host(AskWorkEnvironmentButton(model: fixture.model), size: NSSize(width: 400, height: 80))
        defer { environmentWindow.close(); AskGlassMenuPresenter.shared.hide() }
        try await settle(environmentWindow)
        try press("ask.composer.permissionMode", in: environmentWindow)
        try await fixture.wait { AskGlassMenuPresenter.shared.panel?.isVisible == true }
        let environmentPanel = try #require(AskGlassMenuPresenter.shared.panel)
        try await settle(environmentPanel)
        let environmentContent = try #require(environmentPanel.contentView)
        let environmentBitmap = try #require(environmentContent.bitmapImageRepForCachingDisplay(in: environmentContent.bounds))
        environmentContent.cacheDisplay(in: environmentContent.bounds, to: environmentBitmap)
        try #require(environmentBitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("work-environment-menu.png"))
        AskGlassMenuPresenter.shared.hide()
        let text = "Liquid Glass 是一种动态材质，它会折射和反射周围的内容，同时根据光线和动作实时变化。"
        let storage = AskLocalModeStatus(source: "Cloud", offersSignIn: false, local: false, changeable: true,
                                         choices: [.cloud, .local, .temporary])
        let menu = AskAddMenuContext(
            switches: AskAddMenuSwitch.make(items: items(screenshot: .attached, source: "Safari — Docs",
                                                         selection: text, memory: AskMemory(global: "m")),
                                            selectionText: text, actions: { _ in {} }),
            storage: storage)
        try await save(AskGlassCardSurface(kind: .menu) { AskComposerAddMenu(context: menu, pickFiles: {}) }
                        .padding(20).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 400, height: 480), name: "gul462-plus-menu")
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.selection = text
        fixture.model.launcherDraft.memory = AskMemory(global: "m")
        try await save(AskLauncherView(model: fixture.model, onDismiss: {}),
                       size: NSSize(width: AskMetrics.launcherWidth, height: 200), name: "gul462-launcher")
    }
}
