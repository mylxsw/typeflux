import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in render checks use the production views with isolated, synthetic data.
/// They never access a user's screens, microphone, account or desktop tools.
@Suite("Ask visual snapshots", .serialized)
@MainActor
struct AskConversationVisualTests {
    @Test func nativeWindowTransitionFollowsExplicitSubmission() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil else { return }
        _ = NSApplication.shared
        let fixture = try AskTestFixture()
        let suite = "ask-window-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model)
        func window(_ suffix: String) -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-" + suffix }
        }
        controller.showLauncher()
        try await fixture.wait { window("launcher")?.isVisible == true }
        let launcher = try #require(window("launcher"))
        #expect(launcher.styleMask == .borderless)
        try await fixture.wait { launcher.firstResponder is NSTextView }
        #expect(launcher.firstResponder is NSTextView)
        #expect(window("conversations")?.isVisible != true)
        controller.showLauncher()
        fixture.model.launcherDraft.text = "A real input, with a stubbed service"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(!launcher.isVisible)
        let chat = try #require(window("conversations"))
        #expect(chat.isVisible)
        #expect(chat.styleMask.contains(.resizable))
        fixture.model.onControlChanged?(true)
        #expect(!chat.isVisible)
        fixture.model.onControlChanged?(false)
        #expect(chat.isVisible)
        #expect(!controller.windowShouldClose(chat))
        #expect(!chat.isVisible)
        controller.showConversation()
        #expect(chat.isVisible)
        controller.dismissLauncher()
        _ = controller.windowShouldClose(chat)
        fixture.model.resetSession()
    }

    @Test func renderApprovedSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.screenshot = nil
        fixture.model.launcherDraft.text = "帮我总结这页内容，并查找相关资料"
        try await render(AskLauncherView(model: fixture.model, onVoice: {}, onDismiss: {}),
                         size: NSSize(width: 760, height: 192), appearance: .darkAqua, file: root.appendingPathComponent("launcher.png"))

        let call = AskToolCall(id: "browser-read", type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        let now = Date()
        let conversation = AskConversation(id: "design-conversation", title: "页面内容总结", revision: 4, updatedAt: now, messages: [
            .init(id: "1", role: "user", text: "帮我总结这页内容，并查找相关资料", selection: "快捷键唤起输入框，确认发送后进入完整会话。", source: "Safari", createdAt: now),
            .init(id: "2", role: "assistant", text: "你更关注哪方面？", createdAt: now),
            .init(id: "3", role: "user", text: "产品交互和使用成本", createdAt: now),
            .init(id: "4", role: "assistant", text: "", toolCalls: [call], createdAt: now),
            .init(id: "5", role: "tool", text: "已读取当前页面的正文与链接。", toolCallId: "browser-read", isError: false, createdAt: now),
            .init(id: "6", role: "assistant", text: "## 交互要点\n\n- 先在屏幕中央输入，确认后再进入对话。\n- 键盘与现有语音输入共用同一个输入框。\n- 截图与选区可在发送前预览和移除。\n\n使用成本信息仍需进一步核对。你也可以继续追问具体的使用场景。", createdAt: now)
        ], run: .init(id: "run", deviceId: "device", status: "completed", steps: 2, updatedAt: now, tools: [], pending: []))
        await fixture.api.seed(conversation)
        await fixture.api.seed(.init(id: "older", title: "整理会议要点", revision: 1, updatedAt: now.addingTimeInterval(-60), messages: []))
        await fixture.model.refreshHistory()
        await fixture.model.select(conversation.id)
        try await render(AskConversationView(model: fixture.model, onVoice: {}), size: NSSize(width: 1040, height: 740), appearance: .aqua, file: root.appendingPathComponent("conversation.png"))
        await fixture.api.setTool(call)
        fixture.model.draft.text = "读取当前页面"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        try await render(AskConversationView(model: fixture.model, onVoice: {}), size: NSSize(width: 1040, height: 740), appearance: .darkAqua, file: root.appendingPathComponent("tool-approval.png"))
        fixture.model.approve(conversationId: conversation.id, allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        fixture.model.resetSession()
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 10000)
    }
}
