import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Typeflux

/// Renders the embedded browser panel and the window that hosts it.
/// Set `TYPEFLUX_BROWSER_SNAPSHOTS=<dir>` to keep the PNGs.
@Suite("Ask embedded browser rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskBrowserPanelRenderTests {
    private func makeWorkspace() -> (AskBrowserWorkspace, UserDefaults) {
        let defaults = UserDefaults(suiteName: "AskBrowserPanelRenderTests." + UUID().uuidString)!
        return (AskBrowserWorkspace(policy: AskBrowserSitePolicy(defaults: defaults), dataStore: .nonPersistent()), defaults)
    }

    private func loadPage(_ tab: AskBrowserTab) async throws {
        tab.webView.loadHTMLString("""
        <title>Notifications</title><body style="font:15px -apple-system;padding:20px">
        <h2>Notifications</h2><button>Unread · 5</button><p>Ask: support embedded browser panel</p></body>
        """, baseURL: URL(string: "https://github.com/notifications"))
        for _ in 0 ..< 150 where tab.webView.isLoading || tab.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
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

    @discardableResult
    private func render<V: View>(_ root: V, name: String, size: NSSize, dark: Bool = false, minimumPNGBytes: Int = 8000) throws -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: root.environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try snapshot(hosting, name: name, minimumBytes: minimumPNGBytes)
        return hosting
    }

    private func snapshot(_ hosting: NSView, name: String, minimumBytes: Int = 8000) throws {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > minimumBytes, "\(name) rendered blank")
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_BROWSER_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    private func panel(_ workspace: AskBrowserWorkspace, runActive: Bool = false) -> some View {
        AskBrowserPanel(workspace: workspace, runningConversationId: runActive ? "c1" : nil,
                        stopRun: {}, close: {}, resize: { _ in })
    }

    @Test func panelStatesRender() async throws {
        let (workspace, _) = makeWorkspace()
        let size = NSSize(width: 560, height: 640)
        try render(panel(workspace), name: "browser-empty", size: size)

        let tab = try workspace.newTab()
        try render(panel(workspace), name: "browser-start-page", size: size)
        try await loadPage(tab)
        workspace.policy.set(.act, for: "https://github.com")
        let hosting = try render(panel(workspace), name: "browser-page", size: size)
        #expect(descendants(hosting).contains { $0 === tab.webView }, "The tab's own web view is hosted")

        workspace.beginActivity(L("ask.web.action.click"), conversationId: "c1", tab: tab)
        try render(panel(workspace, runActive: true), name: "browser-agent", size: size, dark: true)
        workspace.setPaused(true, takenOver: true)
        try render(panel(workspace, runActive: true), name: "browser-taken-over", size: size)
        workspace.setPaused(false)

        let handoff = Task { await workspace.requestHandoff(tab: tab, reason: .login, message: "Sign in to GitHub") }
        for _ in 0 ..< 100 where workspace.handoff == nil { try await Task.sleep(for: .milliseconds(10)) }
        try render(panel(workspace, runActive: true), name: "browser-handoff", size: size)
        workspace.finishHandoff(completed: true)
        #expect(await handoff.value)

        tab.notice = L("ask.web.downloadUnsupported")
        try render(panel(workspace), name: "browser-notice", size: size)
        _ = try workspace.newTab(isPrivate: true)
        try render(panel(workspace), name: "browser-private", size: size, dark: true)
        workspace.tabs.forEach { workspace.close($0) }
    }

    @Test func sitesSheetRenders() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let (workspace, defaults) = makeWorkspace()
        defaults.set(["legacy.invalid": "act"], forKey: AskBrowserSitePolicy.defaultsKey)
        try render(AskBrowserSitesView(workspace: workspace), name: "browser-sites-empty", size: NSSize(width: 560, height: 360))
        workspace.policy.set(.act, for: "https://mail.google.com")
        workspace.policy.set(.off, for: "https://example.com")
        let size = NSSize(width: 560, height: 420)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AskBrowserSitesView(workspace: workspace).background(AskTheme.surface))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let hosts = ["https://example.com", "https://mail.google.com"]
        let labels = hosts.map { L("ask.web.permission.label", $0) }
        var pickers: [SettingsBehaviorTestSupport.Element] = []
        for _ in 0 ..< 100 {
            hosting.layoutSubtreeIfNeeded()
            pickers = SettingsBehaviorTestSupport.elements(in: window).filter { labels.contains($0.label) }
            if pickers.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pickers.count == 2, "Both exact-origin controls must be visible inside the sheet")
        for picker in pickers {
            let frame = hosting.convert(window.convertFromScreen(picker.frame), from: nil)
            #expect(frame.width > 0 && frame.height > 0 && hosting.bounds.contains(frame))
        }
        #expect(pickers.contains { $0.label == labels[1] && $0.text == AskBrowserSitePermission.read.title },
                "Persisted act must select the canonical read/navigation option")
        #expect(workspace.policy.permission(for: "https://mail.google.com") == .act,
                "Rendering must not rewrite compatibility storage")
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        try snapshot(hosting, name: "browser-sites")
    }

    @Test(arguments: [CGFloat(1400), 1026, 800, 760, 440, 360])
    func conversationWindowOpensThePanelWhenTheAIAsks(width: CGFloat) async throws {
        let (workspace, defaults) = makeWorkspace()
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        let fixture = try AskTestFixture(defaults: defaults)
        defer { fixture.model.resetSession() }
        fixture.tools.browserWorkspace = workspace
        await fixture.api.seed(.init(id: "browser-chat", title: "Build a browser game", revision: 1,
                                    updatedAt: Date(), messages: []))
        await fixture.model.select("browser-chat")
        fixture.model.draft.text = "Keep this unfinished question"
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let size = NSSize(width: width, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, .dark)
            .environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        #expect(workspace.tabs.isEmpty)
        workspace.requestPresentation()
        for _ in 0 ..< 100 where workspace.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        #expect(workspace.tabs.count == 1, "Opening the panel with no tabs starts a blank one")
        let tab = try #require(workspace.selectedTab)
        #expect(descendants(hosting).contains { $0 === tab.webView })
        let expected = AskWorkspaceLayout(size: size, sidebarCollapsed: false, showsUsage: true,
                                           rightPanelWidth: 560, docksRightPanel: true)
        try await SettingsBehaviorTestSupport.wait {
            hosting.layoutSubtreeIfNeeded()
            let frame = hosting.convert(tab.webView.bounds, from: tab.webView)
            return abs(frame.minX - (width - expected.usageWidth + 8)) < 1
        }
        let pageFrame = hosting.convert(tab.webView.bounds, from: tab.webView)
        #expect(abs(pageFrame.minX - (width - expected.usageWidth + 8)) < 1)
        #expect(pageFrame.maxX <= width)
        let editor = try #require(descendants(hosting).compactMap { $0 as? AskComposerTextView.Editor }.first)
        if expected.mainWidth > 0 {
            let viewport = try #require(editor.enclosingScrollView)
            let composerFrame = hosting.convert(viewport.bounds, from: viewport)
            #expect(composerFrame.maxX <= pageFrame.minX)
            #expect(editor.isEditable, "The docked browser must leave the conversation interactive")
            #expect(find("ask.workspace.browser", in: window) != nil)
        } else {
            #expect(!editor.isEditable, "A hidden conversation must not keep accepting keyboard input")
        }
        try await loadPage(tab)
        try snapshot(hosting, name: "browser-window-\(Int(width))")
        let close = try #require(find("ask.workspace.drawer.close", in: window))
        _ = close.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        #expect(find("ask.web.panel", in: window) == nil)
        #expect(editor.isEditable)
        #expect(fixture.model.draft.text == "Keep this unfinished question")
        #expect(fixture.model.selectedId == "browser-chat")
        #expect(await fixture.api.sends.isEmpty)
        #expect(defaults.bool(forKey: "ask.sidebarCollapsed") == false)
        workspace.tabs.forEach { workspace.close($0) }
    }
}

extension AskBrowserPanelRenderTests {
    @Test func temporaryFolderControlsOmitLifetimePickerAndKeepRevocation() async throws {
        let root = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.askFileAccessFolders = [root.path]
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: defaults)),
                                  settings: settings, owner: { "owner" })
        let fixture = try AskTestFixture(modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), toolsOverride: tools)
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "c", title: "Folder fixture", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.select("c")
        try tools.stageFolders([root.path], lifetime: .conversationSession, ownerId: "owner",
                               deviceId: "device", conversationId: "c", messageID: "m", generation: UUID())
        try tools.admitFolders(messageID: "m", conversationId: "c", runId: "r")
        #expect(fixture.model.hasSettingsFolder(root.path))
        #expect(fixture.model.hasSettingsFolder(root.appendingPathComponent("nested").path))
        #expect(fixture.model.temporaryFolderGrants().count == 1)
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let size = NSSize(width: 340, height: 300)
        let view = AskFolderPermissionControls(model: fixture.model, launcher: false)
            .padding(12).frame(width: size.width, height: size.height, alignment: .topLeading).background(AskTheme.surface)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await SettingsBehaviorTestSupport.wait {
            SettingsBehaviorTestSupport.contains(L("ask.folder.revoke"), in: window)
        }
        #expect(!SettingsBehaviorTestSupport.contains(L("ask.folder.lifetime"), in: window))
        #expect(!SettingsBehaviorTestSupport.contains(L("ask.folder.task"), in: window))
        try snapshot(hosting, name: "temporary-folder-permissions")
        try SettingsBehaviorTestSupport.button(L("ask.folder.revoke"), in: window).press()
        try await SettingsBehaviorTestSupport.wait { fixture.model.temporaryFolderGrants().isEmpty }
        #expect(tools.fileTools(conversationId: "c").roots.contains(root.path))
        for launcher in [false, true] {
            let empty = NSHostingView(rootView: AskFolderPermissionControls(model: fixture.model, launcher: launcher))
            #expect(empty.fittingSize.height == 0)
        }
    }
}
