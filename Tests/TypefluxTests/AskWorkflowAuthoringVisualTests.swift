import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Chat workflow preview rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowAuthoringVisualTests {
    @Test func previewFitsWideAndNarrowWorkspaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try AskWorkflowFixture(), chat = try AskTestFixture()
        defer { chat.model.resetSession(); try? FileManager.default.removeItem(at: chat.root) }
        let authoring = AskWorkflowAuthoringStore(workflows: fixture.store,
            root: fixture.home.appendingPathComponent("Authoring"), owner: { "o" })
        chat.model.workflowAuthoring = authoring
        authoring.onChange = { [weak model = chat.model] in model?.objectWillChange.send() }
        let messages: [AskMessage] = [
            .init(id: "u", role: "user", text: "帮我做一个去除重复行的工具，保留原来的顺序。", createdAt: Date()),
            .init(id: "a", role: "assistant", text: "草稿已准备好。输入一段文本试一试；你还可以让我忽略大小写或调整排序。满意后保存到启动器。", createdAt: Date())
        ]
        await chat.api.seed(.init(id: "workflow", title: "创建文本去重工具", revision: 1, updatedAt: Date(), messages: messages))
        await chat.model.refreshHistory(); await chat.model.select("workflow")
        let session = try authoring.start("workflow", name: "Unique lines", workflowID: nil)
        let object = AskWorkflowFixture.inline("local.unique-lines", keyword: "uniq", script: "print 'Apple\nBanana\nOrange'",
            extra: ["name": "文本去重", "description": "去除重复行，保留首次出现的顺序。"])
        _ = session.submit(.init(summary: "Ready", manifestText: AskWorkflowDraft.format(object), files: [:], deletes: []))
        session.query = "Apple\nBanana\nApple\nOrange\nBanana"
        session.tester.searchPath = { "/bin:/usr/bin" }
        _ = await session.testLatestProposal([.init(query: session.query)])
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, width, appearance) in [("wide-light", 1280.0, NSAppearance.Name.aqua),
                                          ("wide-dark", 1280.0, .darkAqua), ("narrow-light", 560.0, .aqua)] {
            let size = NSSize(width: width, height: 800)
            let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            let hosting = NSHostingView(rootView: AskConversationView(model: chat.model))
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(500))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("workflow-chat-\(name).png"))
            #expect(png.count > 4000)
            window.orderOut(nil); window.close()
        }
    }

    @Test func workflowPanelUsesExistingDrawerThresholds() {
        for width in [360.0, 560, 980, 1100, 1280] {
            let layout = AskWorkspaceLayout(size: .init(width: width, height: 800), sidebarCollapsed: false,
                                             showsUsage: true, rightPanelWidth: 390)
            #expect(layout.usageInline == (width >= 990))
            #expect(layout.usageOverlay == (width < 990))
            #expect(layout.drawerWidth <= width - 16)
            #expect(layout.mainWidth <= width)
            #expect(layout.usageWidth == 390)
        }
    }
}
