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
    private func render<V: View>(_ root: V, name: String, size: NSSize, dark: Bool = false) throws -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: root.environment(\.askGlassMaterialOverride, .opaque))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try snapshot(hosting, name: name)
        return hosting
    }

    private func snapshot(_ hosting: NSView, name: String) throws {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 8000, "\(name) rendered blank")
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
        workspace.policy.set(.act, for: "github.com")
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
        let (workspace, _) = makeWorkspace()
        try render(AskBrowserSitesView(workspace: workspace), name: "browser-sites-empty", size: NSSize(width: 560, height: 360))
        workspace.policy.set(.read, for: "mail.google.com")
        workspace.policy.set(.off, for: "example.com")
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
            rows = descendants(hosting).filter { $0 is NSSegmentedControl }.count
            if rows == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rows == 2, "One permission control per site")
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
