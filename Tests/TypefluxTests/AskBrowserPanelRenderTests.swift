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
        var rows = 0
        for _ in 0 ..< 100 {
            hosting.layoutSubtreeIfNeeded()
            rows = descendants(hosting).filter { view in
                view is NSPopUpButton && !view.visibleRect.isEmpty &&
                    hosting.bounds.contains(hosting.convert(view.bounds, from: view))
            }.count
            if rows == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rows == 2, "Both exact-origin controls must be visible inside the sheet")
        let pickers = descendants(hosting).compactMap { $0 as? NSPopUpButton }
        for picker in pickers {
            #expect(picker.itemTitles == AskBrowserSitePermission.choices.map(\.title))
        }
        #expect(pickers.contains { $0.titleOfSelectedItem == AskBrowserSitePermission.read.title },
                "Persisted act must select the canonical read/navigation option")
        #expect(workspace.policy.permission(for: "https://mail.google.com") == .act,
                "Rendering must not rewrite compatibility storage")
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        try snapshot(hosting, name: "browser-sites")
    }

    @Test func conversationWindowOpensThePanelWhenTheAIAsks() async throws {
        let fixture = try AskTestFixture()
        let (workspace, _) = makeWorkspace()
        fixture.tools.browserWorkspace = workspace
        let size = NSSize(width: 1400, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model)
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
        try await loadPage(tab)
        try snapshot(hosting, name: "browser-window")
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
        try render(AskFolderPermissionControls(model: fixture.model, launcher: true).padding(12)
            .frame(width: 340, height: 160).background(AskTheme.surface),
                   name: "launcher-folder-permissions", size: NSSize(width: 340, height: 160), minimumPNGBytes: 4000)
    }
}
