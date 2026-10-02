import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in renders of the GUL-151 agent surfaces with production views and synthetic
/// data (set TYPEFLUX_ASK_SNAPSHOTS). They never touch real accounts, screens or tools.
@Suite("Ask agent harness snapshots", .serialized)
@MainActor
struct AskHarnessVisualTests {
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 4000)
    }

    /// A small bar chart standing in for a run_code result.
    private func chartDataURL() -> String {
        let image = NSImage(size: NSSize(width: 480, height: 260))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 480, height: 260).fill()
        for (index, value) in [120.0, 180, 90, 210].enumerated() {
            NSColor.systemBlue.setFill()
            NSRect(x: 60 + Double(index) * 100, y: 30, width: 60, height: value).fill()
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return "data:image/jpeg;base64," + rep.representation(using: .jpeg, properties: [:])!.base64EncodedString()
    }

    private func call(_ id: String, _ name: String, _ args: String) -> AskToolCall {
        AskToolCall(id: id, type: "function", function: .init(name: name, arguments: args))
    }

    @Test func renderAgentHarnessSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }

        // 1. A long agent run: plan, server web tools, device tools, code with a chart.
        let fixture = try AskTestFixture()
        let now = Date()
        let calls = [
            call("p", "update_plan", #"{"items":[{"step":"搜索发布信息","status":"completed"},{"step":"读取本地发布说明","status":"completed"},{"step":"统计并画图","status":"in_progress"},{"step":"写总结","status":"pending"}]}"#),
            call("s", "web_search", #"{"query":"Typeflux 4.2 发布说明"}"#),
            call("f", "web_fetch", #"{"url":"https://typeflux.app/changelog"}"#),
            call("k", "skill", #"{"name":"data-analysis"}"#),
            call("r", "files", #"{"action":"read","path":"~/Documents/release.md"}"#),
            call("c", "run_code", #"{"language":"python","code":"import matplotlib"}"#),
            call("m", "memory", #"{"action":"remember","text":"偏好简洁的周报"}"#),
            call("i", "computer", #"{"action":"inspect"}"#)
        ]
        var messages: [AskMessage] = [.init(id: "u1", role: "user", text: "整理本周的发布说明，统计各模块改动数量并画个图表", source: "Notes", createdAt: now)]
        let results = ["Plan updated.", "1. Typeflux 4.2 发布\n   https://typeflux.app/changelog\n   离线同步与登录修复", "URL: https://typeflux.app/changelog\nTitle: Changelog\n\n# 4.2\n- 离线同步", "# Skill: data-analysis\n1. Load the data in run_code…",
                       "File: /Users/me/Documents/release.md (42 lines)\n1\t# Release 4.2", "Exit code: 0\n--- stdout ---\n{'sync': 12, 'auth': 18, 'ui': 9, 'asr': 21}\nThe first new image is attached.",
                       "Saved note 3f2a91c0. It applies to new conversations.", "Accessibility elements of Notes (click coordinates as @(x, y)):\nWindow \"Notes\" @(0.500, 0.500)"]
        for (index, item) in calls.enumerated() {
            messages.append(.init(id: "a\(index)", role: "assistant", text: index == 0 ? "我先列个计划，然后搜索并读取资料。" : "", toolCalls: [item], createdAt: now))
            messages.append(.init(id: "t\(index)", role: "tool", text: results[index], image: item.function.name == "run_code" ? chartDataURL() : nil,
                                  toolCallId: item.id, createdAt: now))
        }
        messages.append(.init(id: "final", role: "assistant", text: "## 本周发布概览\n\n- ASR 改动最多（21 项），其次是登录（18 项）。\n- 离线同步完成主要功能。\n\n来源：https://typeflux.app/changelog", createdAt: now))
        var run = AskRun(id: "run", deviceId: "device", status: "completed", steps: 9, updatedAt: now, tools: [], pending: [])
        run.plan = [AskPlanItem(step: "搜索发布信息", status: "completed"), AskPlanItem(step: "读取本地发布说明", status: "completed"),
                    AskPlanItem(step: "统计并画图", status: "in_progress"), AskPlanItem(step: "写总结", status: "pending")]
        await fixture.api.seed(.init(id: "agent-run", title: "本周发布说明整理", revision: 3, updatedAt: now, messages: messages, run: run))
        await fixture.model.refreshHistory()
        await fixture.model.select("agent-run")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 1400), appearance: appearance,
                             file: root.appendingPathComponent("harness-run-\(appearance == .aqua ? "light" : "dark").png"))
        }

        // 2. Approval for a write (grantable) and for a destructive MCP call (allow once only).
        await fixture.api.setTool(call("w", "files", ##"{"action":"edit","path":"~/Documents/release.md","old_text":"# Release 4.2","new_text":"# Release 4.2 (final)"}"##))
        fixture.model.draft.text = "把标题改成正式版"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 1500), appearance: .aqua,
                         file: root.appendingPathComponent("harness-approval-write.png"))
        fixture.model.approve(conversationId: "agent-run", allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        await fixture.api.setTool(call("d", "mcp_delete_issue", #"{"id":"GUL-151"}"#))
        fixture.model.draft.text = "删除那个 issue"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 1500), appearance: .darkAqua,
                         file: root.appendingPathComponent("harness-approval-destructive.png"))
        fixture.model.approve(conversationId: "agent-run", allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        fixture.model.resetSession()

        // 2b. Follow-ups queued while the run waits: collapsed, expanded, editing, and a jump.
        let queued = try AskTestFixture()
        await queued.api.setTool(call("q", "browser", #"{"action":"read"}"#))
        queued.model.draft.text = "整理本周的发布说明"
        queued.model.submitDraft()
        try await queued.wait { !queued.model.pendingApprovals.isEmpty }
        await queued.api.setTool(nil)
        for text in ["顺便把结论翻译成英文", "再按模块给一个改动表格", "最后帮我写一段发布公告"] {
            queued.model.draft.text = text
            queued.model.submitDraft()
        }
        try await render(AskConversationView(model: queued.model), size: NSSize(width: 1100, height: 900), appearance: .aqua,
                         file: root.appendingPathComponent("queue-collapsed.png"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await render(AskQueueBar(model: queued.model, expanded: .constant(true)).frame(width: 720).padding(20)
                .background(StudioTheme.surface), size: NSSize(width: 760, height: 170), appearance: appearance,
                             file: root.appendingPathComponent("queue-expanded-\(appearance == .aqua ? "light" : "dark").png"))
        }
        queued.model.draft.text = "我刚才写到一半的另一个问题"
        queued.model.editQueued(queued.model.queuedMessages[0].id)
        queued.model.draft.text = "顺便把结论翻译成英文，并保留原有的格式：\n1. 标题和列表层级不变\n2. 专有名词不翻译"
        try await render(AskConversationView(model: queued.model), size: NSSize(width: 1100, height: 900), appearance: .aqua,
                         file: root.appendingPathComponent("queue-editing.png"))
        queued.model.saveQueuedEdit()
        queued.model.steerQueued(queued.model.queuedMessages[0].id)
        try await queued.wait { !queued.model.steeredMessages.isEmpty }
        try await render(AskConversationView(model: queued.model), size: NSSize(width: 1100, height: 900), appearance: .darkAqua,
                         file: root.appendingPathComponent("queue-jumped-dark.png"))
        queued.model.approve(conversationId: try #require(queued.model.selectedId), allowed: false)
        try await queued.wait { queued.model.busyIds.isEmpty && queued.model.queuedMessages.isEmpty }
        queued.model.resetSession()

        // 3. Ask tools settings with folders, skills and notes.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ask-harness-visual-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "ask-harness-visual-\(UUID().uuidString)")!)
        settings.askFileAccessFolders = ["/Users/me/Documents", "/Users/me/Projects/typeflux"]
        let notes = AskMemoryNoteStore(fileURL: temp.appendingPathComponent("notes.json"))
        try notes.add("偏好简洁的周报", owner: "o")
        try notes.add("常用 Python 做数据分析", owner: "o")
        for tab in [AgentConfigurationTab.general, .tools, .skills, .memory] {
            let settingsView = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: temp.appendingPathComponent("skills")),
                                                    notes: notes, owner: { "o" }, isSignedIn: { true }, tab: tab)
                .padding(24).frame(width: 760, alignment: .top).frame(maxHeight: .infinity, alignment: .top).background(StudioTheme.surface)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try await render(settingsView, size: NSSize(width: 760, height: 900), appearance: appearance,
                                 file: root.appendingPathComponent("harness-settings-\(tab.rawValue)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }

        // 4. Signed out: the launcher in local mode with the user's own model.
        let suite = "ask-harness-local-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AskModelProfile(name: "我的 Ollama", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:14b")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let local = AskConversationModel(api: AskRoutedAPI(cloud: AskAPIClient(), local: AskLocalEngine(directory: temp.appendingPathComponent("local"))),
                                         cache: try AskConversationCache(url: temp.appendingPathComponent("cache.sqlite")),
                                         tools: AskTestTools(), capture: AskTestCapture(), deviceId: "device", modelLibrary: library,
                                         session: { ("local", "") })
        local.launcherDraft.text = "不登录也能用吗？帮我查一下今天的天气"
        local.launcherDraft.modelRef = profile.reference
        try await render(AskLauncherView(model: local, onDismiss: {}), size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .aqua,
                         file: root.appendingPathComponent("harness-local-launcher.png"))
        local.launcherDraft.modelRef = nil
        try await render(AskLauncherView(model: local, onDismiss: {}), size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .darkAqua,
                         file: root.appendingPathComponent("harness-local-launcher-fallback.png"))
    }
}
