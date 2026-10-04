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
        let policy = AskWindowActivationPolicy()
        let dock = DockVisibilityController(app: policy)
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model,
                                                        dockVisibility: dock)
        func window(_ suffix: String) -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-" + suffix }
        }
        controller.showLauncher()
        try await fixture.wait { window("launcher")?.isVisible == true }
        let launcher = try #require(window("launcher"))
        #expect(launcher.styleMask == [.borderless, .nonactivatingPanel])
        #expect(launcher.frame.width == AskMetrics.launcherWidth)
        // Empty, it lists the suggestions under the controls.
        #expect(launcher.frame.height <= AskMetrics.launcherHeight(editor: 32, banners: 0, suggestions: true) + 4)
        // Centred on the screen like Spotlight; it grows downward from a fixed top.
        let top = launcher.frame.maxY
        let visibleFrame = try #require(launcher.screen?.visibleFrame)
        #expect(abs(launcher.frame.midY - visibleFrame.midY) < 2)
        #expect(abs(launcher.frame.midX - visibleFrame.midX) < 1)
        fixture.model.launcherDraft.text = String(repeating: "Line of text\n", count: 30)
        try await fixture.wait { launcher.frame.height >= 200 }
        #expect(launcher.frame.height <= 230)
        #expect(abs(launcher.frame.maxY - top) < 1)
        controller.dismissLauncher(); controller.showLauncher()
        try await fixture.wait { launcher.isVisible }
        #expect(launcher.frame.height >= 200)
        fixture.model.launcherDraft.text = "Short"
        try await fixture.wait { launcher.frame.height <= 120 }
        try await fixture.wait { launcher.firstResponder is NSTextView }
        #expect(launcher.firstResponder is NSTextView)
        #expect(window("conversations")?.isVisible != true)
        #expect(policy.currentActivationPolicy == .accessory)
        controller.showLauncher()
        fixture.model.launcherDraft.text = "A real input, with a stubbed service"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(!launcher.isVisible)
        let chat = try #require(window("conversations"))
        #expect(chat.isVisible)
        #expect(chat.styleMask.contains(.resizable))
        #expect(policy.currentActivationPolicy == .regular)
        chat.miniaturize(nil)
        try await fixture.wait { chat.isMiniaturized }
        #expect(policy.currentActivationPolicy == .regular)
        controller.showConversation()
        try await fixture.wait { !chat.isMiniaturized }
        #expect(chat.isVisible)
        fixture.model.onControlChanged?(true)
        #expect(!chat.isVisible)
        fixture.model.onControlChanged?(false)
        #expect(chat.isVisible)
        #expect(!controller.windowShouldClose(chat))
        #expect(!chat.isVisible)
        #expect(policy.currentActivationPolicy == .accessory)
        controller.showConversation()
        #expect(chat.isVisible)
        controller.dismissLauncher()
        let otherWindow = NSObject()
        dock.setPresented(true, for: otherWindow)
        _ = controller.windowShouldClose(chat)
        #expect(policy.currentActivationPolicy == .regular)
        dock.setPresented(false, for: otherWindow)
        #expect(policy.currentActivationPolicy == .accessory)
        fixture.model.resetSession()
    }

    @Test func renderSourceContextSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let png = try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 320, height: 200), type: .png)
        let captured = AskDraft(text: "解释这段选中的内容", includeScreenshot: true,
                                screenshot: "data:image/png;base64," + png.base64EncodedString(),
                                selection: "来源信息属于这份草稿。\n重新截图不会更换选区来源。",
                                source: "Safari — Typeflux 产品方案：来源与截图范围说明",
                                sourceBundleID: "com.apple.Safari", capturedAt: Date(timeIntervalSince1970: 1_791_014_400))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            fixture.model.launcherDraft = captured
            for width in [AskMetrics.launcherWidth, CGFloat(430)] {
                try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                    .environment(\.askGlassMaterialOverride, .opaque),
                                 size: NSSize(width: width, height: width == 430 ? 232 : 190), appearance: appearance,
                                 file: root.appendingPathComponent("captured-content-\(Int(width))-\(name).png"), minimumPNGBytes: 4000)
            }
            fixture.model.launcherDraft = AskDraft(text: "这个报错是什么意思", includeScreenshot: false,
                                                   selection: "把远程桌面里的报错翻译一下", source: "Windows App — Dev Box")
            fixture.model.restoreLauncherContextMarker(true)
            try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                .environment(\.askGlassMaterialOverride, .opaque),
                             size: NSSize(width: AskMetrics.launcherWidth, height: 190), appearance: appearance,
                             file: root.appendingPathComponent("captured-draft-\(name).png"), minimumPNGBytes: 4000)
            fixture.model.launcherDraft = AskDraft(text: "讲讲这一屏在做什么", includeScreenshot: true,
                                                   source: "Safari", sourceBundleID: "com.apple.Safari")
            fixture.model.restoreLauncherContextMarker(false)
            fixture.model.captureWarning = L("ask.capture.permission")
            try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                .environment(\.askGlassMaterialOverride, .opaque),
                             size: NSSize(width: 430, height: 190), appearance: appearance,
                             file: root.appendingPathComponent("captured-permission-\(name).png"), minimumPNGBytes: 4000)
            fixture.model.launcherDraft = captured
            fixture.model.captureWarning = nil
            fixture.model.removeCapturedContent(.source, launcher: true)
            try await render(AskLauncherView(model: fixture.model, onDismiss: {})
                                .environment(\.askGlassMaterialOverride, .opaque),
                             size: NSSize(width: AskMetrics.launcherWidth, height: 150), appearance: appearance,
                             file: root.appendingPathComponent("captured-undo-\(name).png"), minimumPNGBytes: 4000)
            try await render(AskSourceContextDetails(draft: .constant(captured), restored: true, refresh: {})
                                .background(Color(nsColor: .windowBackgroundColor)),
                             size: NSSize(width: 360, height: 230), appearance: appearance,
                             file: root.appendingPathComponent("captured-source-details-\(name).png"), minimumPNGBytes: 4000)
            try await render(AskSelectedTextDetails(text: captured.selection ?? "", source: "Safari", onRemove: {})
                                .background(Color(nsColor: .windowBackgroundColor)),
                             size: NSSize(width: 380, height: 250), appearance: appearance,
                             file: root.appendingPathComponent("captured-selection-details-\(name).png"), minimumPNGBytes: 4000)
            try await render(AskAttachChoices(clipboardHasImage: false, sourceToRestore: "Safari", selectionLinesToRestore: 2) { _ in }
                                .background(Color(nsColor: .windowBackgroundColor)),
                             size: NSSize(width: 300, height: 290), appearance: appearance,
                             file: root.appendingPathComponent("captured-restore-\(name).png"), minimumPNGBytes: 4000)
        }
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
        fixture.model.captureWarning = L("ask.capture.permission")
        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .darkAqua,
                         file: root.appendingPathComponent("launcher.png"), minimumPNGBytes: 4000)

        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .aqua, file: root.appendingPathComponent("launcher-light.png"), voice: fixture.model.voiceInput)
        let launcherDraft = fixture.model.launcherDraft
        fixture.model.launcherDraft.selection = nil
        fixture.model.launcherDraft.source = String(repeating: "Finder ", count: 12)
        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: 430, height: 114), appearance: .aqua,
                         file: root.appendingPathComponent("launcher-context-overflow.png"))
        fixture.model.launcherDraft = launcherDraft
        try await render(HStack(spacing: 16) {
            AskVoiceButton.Appearance(hovered: true, reduceMotion: true)
            AskVoiceButton.Appearance(phase: .listening, pressed: true, reduceMotion: true)
            AskVoiceButton.Appearance(phase: .transcribing, enabled: false, reduceMotion: true)
        }.padding(16), size: NSSize(width: 160, height: 64), appearance: .aqua,
                         file: root.appendingPathComponent("voice-reduced-motion.png"), minimumPNGBytes: 100)
        fixture.model.launcherDraft.text = String(repeating: "Long input wraps naturally and stays editable. ", count: 24)
        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: AskMetrics.launcherWidth, height: 230), appearance: .aqua, file: root.appendingPathComponent("launcher-long.png"))
        let call = AskToolCall(id: "browser-read", type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        let now = Date()
        let conversation = AskConversation(id: "design-conversation", title: "页面内容总结", revision: 4, updatedAt: now, messages: [
            .init(id: "1", role: "user", text: "帮我总结这页内容，并查找相关资料", selection: "快捷键唤起输入框，确认发送后进入完整会话。", source: "Safari", createdAt: now),
            .init(id: "2", role: "assistant", text: "你更关注哪方面？", createdAt: now),
            .init(id: "3", role: "user", text: "产品交互和使用成本", createdAt: now),
            .init(id: "4", role: "assistant", text: "", toolCalls: [call], createdAt: now),
            .init(id: "5", role: "tool", text: "已读取当前页面的正文与链接。", toolCallId: "browser-read", isError: false, createdAt: now),
            .init(id: "6", role: "assistant", text: "## 交互要点\n\n- 先在屏幕底部输入，确认后再进入对话。\n- 键盘与现有语音输入共用同一个输入框。\n- 截图与选区可在发送前预览和移除。\n\n使用成本信息仍需进一步核对。你也可以继续追问具体的使用场景。", createdAt: now)
        ], run: .init(id: "run", deviceId: "device", status: "completed", steps: 2, updatedAt: now, tools: [], pending: []))
        await fixture.api.seed(conversation)
        await fixture.api.seed(.init(id: "older", title: "整理会议要点", revision: 1, updatedAt: now.addingTimeInterval(-86400), messages: []))
        await fixture.model.refreshHistory()
        await fixture.model.select(conversation.id)
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 740), appearance: .aqua, file: root.appendingPathComponent("conversation.png"), voice: fixture.model.voiceInput)
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 760, height: 560), appearance: .aqua, file: root.appendingPathComponent("conversation-small.png"))
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 740), appearance: .darkAqua, file: root.appendingPathComponent("conversation-dark.png"), voice: fixture.model.voiceInput)
        await fixture.api.setTool(call)
        fixture.model.draft.text = "读取当前页面"
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 740), appearance: .darkAqua, file: root.appendingPathComponent("tool-approval.png"))
        fixture.model.approve(conversationId: conversation.id, allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        fixture.model.resetSession()
    }

    @Test func readingPositionSurvivesHistorySwitch() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil else { return }
        let f = try AskTestFixture()
        for id in ["long-a", "long-b"] {
            await f.api.seed(.init(id: id, title: id, revision: 1, updatedAt: Date(), messages: (0..<50).map {
                .init(id: "\(id)-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Message \($0)", createdAt: Date())
            }))
        }
        await f.model.select("long-a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AskConversationView(model: f.model))
        window.contentView = hosting; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(hosting).first { $0.frame.width > 300 && $0.frame.height > 200 })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400)); scroll.reflectScrolledClipView(scroll.contentView)
        try await f.wait { f.model.transcriptPositions["long-a"] != nil && f.model.transcriptPositions["long-a"] != "bottom" }
        let anchor = f.model.transcriptPositions["long-a"]
        await f.model.select("long-b")
        try await Task.sleep(for: .milliseconds(150))
        await f.model.select("long-a")
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.model.transcriptPositions["long-a"] == anchor)
        #expect(scroll.contentView.bounds.origin.y > 100)
        #expect(scroll.contentView.bounds.origin.y < (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - 100)
        f.model.resetSession()
    }

    @Test func renderStreamingSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previous) }
        let fixture = try AskTestFixture()
        let now = Date()
        var run = AskRun(id: "run", deviceId: "device", status: "running", steps: 0, updatedAt: now, tools: [], pending: [])
        run.assistantId = "answer"
        run.reasoning = "先核对数据来源，再比较两种方案的实现成本和维护成本。"
        run.reasoningMilliseconds = 3200
        run.preview = "## 建议优先采用方案 A\n\n它的边界更清晰，也方便逐步上线。\n\n1. 保留现有登录与权限机制。\n2. 将实时响应作为独立模块接入。\n\n下面继续对比性能与维护成本："
        let call = AskToolCall(id: "tool", type: "function", function: .init(name: "browser", arguments: "{\"query\": \""))
        run.previewTools = [call]
        let value = AskConversation(id: "stream-preview", title: "比较两种产品方案", revision: 1, updatedAt: now,
                                    messages: [.init(id: "question", role: "user", text: "请帮我比较两种方案，给出建议并核对资料。", createdAt: now)], run: run)
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 740), appearance: appearance, file: root.appendingPathComponent("stream-answer-\(name).png"))
        }
        fixture.model.resetSession()
    }

    @Test func renderModelSelectionSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "ask-model-visual-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AskModelProfile(name: "我的 vLLM", baseURL: "https://example.invalid/v1", model: "qwen3-32b")
        try defaults.set(JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.cloud = [.init(id: "default", name: "Typeflux Cloud"), .init(id: "deep", name: "Cloud · 深度")]
        library.defaultReference = "cloud:deep"
        let fixture = try AskTestFixture(modelLibrary: library)
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.text = "帮我分析这份产品方案"
        fixture.model.launcherDraft.includeScreenshot = false
        fixture.model.launcherDraft.selection = nil
        fixture.model.launcherDraft.source = nil
        let settings = SettingsStore(defaults: defaults)
        settings.appLanguage = .simplifiedChinese
        settings.setLLMAPIKey("fixture-key", for: .openAI)
        for model in library.providers.first(where: { $0.id == "openAI" })?.models ?? [] {
            try library.removeModel(model.reference, providerID: "openAI")
        }
        try library.addModels([.init(id: "gpt-4o-mini", name: "gpt-4o-mini", vision: true),
                               .init(id: "gpt-4o", name: "gpt-4o", vision: true),
                               .init(id: "o4-mini", name: "o4-mini", vision: true)], providerID: "openAI")
        let viewModel = StudioViewModel(
            settingsStore: settings,
            historyStore: FileHistoryStore(baseDir: root.appendingPathComponent("history")),
            initialSection: .models,
            modelLibrary: library
        )
        try library.addModels(
            [.init(id: "deep", name: "Cloud · 深度", reference: "cloud:deep", vision: true)],
            providerID: "typefluxCloud"
        )
        library.defaultReference = profile.reference
        library
            .rewriteReference = try #require(library.providers.first { $0.id == "openAI" }?.models
                .first { $0.id == "gpt-4o-mini" }?.reference)
        for model in library.providers.first(where: { $0.isOllama })?.models ?? [] {
            try library.removeModel(model.reference, providerID: "ollama")
        }
        if ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_LARGE_CATALOG"] == "1" {
            try library.addModels((0..<300).map { .init(id: "fixture-model-\($0)", name: "Fixture \($0)") }, providerID: "openAI")
        }
        viewModel.setModelDomain(.llm)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(
                StudioView(viewModel: viewModel),
                size: NSSize(width: 1200, height: 880),
                appearance: appearance,
                file: root.appendingPathComponent("models-settings-\(name).png")
            )
            viewModel.selectedLanguageProviderID = "openAI"
            try await render(
                StudioView(viewModel: viewModel),
                size: NSSize(width: 1200, height: 880),
                appearance: appearance,
                file: root.appendingPathComponent("models-provider-\(name).png")
            )
            viewModel.selectedLanguageProviderID = nil
            try await render(
                AskModelChoices(library: library, reference: .constant(library.rewriteReference), loggedIn: true),
                size: NSSize(width: 360, height: 370), appearance: appearance,
                file: root.appendingPathComponent("models-menu-\(name).png")
            )
            let catalogIDs = ["gpt-4o-mini", "gpt-4o", "o4-mini", "gpt-4.1", "gpt-4.1-mini", "o3", "text-embedding-3-large"]
            try await render(
                ModelCatalogView(providerName: "OpenAI", models: catalogIDs.map { .init(id: $0, name: $0) },
                                 existingIDs: Set(catalogIDs.prefix(3)), selected: .constant(Set(catalogIDs.prefix(3))),
                                 onCancel: {}, onAdd: {}),
                size: NSSize(width: 580, height: 470), appearance: appearance,
                file: root.appendingPathComponent("models-catalog-\(name).png")
            )
            viewModel.setModelDomain(.stt)
            try await render(StudioView(viewModel: viewModel), size: NSSize(width: 1200, height: 880),
                             appearance: appearance, file: root.appendingPathComponent("models-speech-\(name).png"))
            viewModel.setModelDomain(.llm)
        }
        try await render(
            AskLauncherView(model: fixture.model, onDismiss: {}),
            size: NSSize(width: AskMetrics.launcherWidth, height: 114),
            appearance: .aqua,
            file: root.appendingPathComponent("model-launcher.png")
        )
        let now = Date()
        let value = AskConversation(id: "model-preview", title: "产品方案分析", revision: 2, updatedAt: now, messages: [
            .init(id: "u1", role: "user", text: "这份产品方案有哪些可以改进的地方？", createdAt: now),
            .init(
                id: "a1",
                role: "assistant",
                text: "可以先从三个方面评估：\n\n- 用户是否能快速找到主要入口。\n- 默认选择是否适合最常见的任务。\n- 高级能力是否能在需要时方便地切换。\n\n你可以把具体方案发给我，我们逐项看。",
                createdAt: now
            )
        ], modelRef: profile.reference)
        await fixture.api.seed(value)
        await fixture.model.refreshHistory()
        await fixture.model.select(value.id)
        try await render(
            AskConversationView(model: fixture.model),
            size: NSSize(width: 1100, height: 740),
            appearance: .aqua,
            file: root.appendingPathComponent("model-conversation.png")
        )
        fixture.model.resetSession()
    }

    @Test func renderReasoningComposer() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_REASONING_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "ask-reasoning-visual-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([.init(id: "deep", name: "深度思考", reference: "cloud:deep", vision: true,
                                    scenarios: ["ask"], pricing: .init(multiplier: "1"), reasoning: true)], providerID: "typefluxCloud")
        library.defaultReference = "cloud:deep"
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft = AskDraft(text: "帮我分析这份产品方案", includeScreenshot: false)
        fixture.model.reasoningEffort = .high
        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: 600, height: 160), appearance: .aqua,
                         file: root.appendingPathComponent("ask-reasoning-client.png"))
        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: 600, height: 160), appearance: .darkAqua,
                         file: root.appendingPathComponent("ask-reasoning-client-dark.png"))
        try await render(AskModelEffortCard(library: library, reference: .constant("cloud:deep"),
                                            effort: .constant(.high), loggedIn: true),
                         size: NSSize(width: AskModelEffortCard.width, height: 200), appearance: .darkAqua,
                         file: root.appendingPathComponent("ask-reasoning-choices.png"), minimumPNGBytes: 2000)
        try await render(AskModelChoices(library: library, reference: .constant("cloud:deep"), loggedIn: true),
                         size: NSSize(width: 360, height: 200), appearance: .darkAqua,
                         file: root.appendingPathComponent("ask-model-choices.png"))
    }

    @Test func renderManagedCloudModels() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CLOUD_CAPTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let suite = "cloud-managed-visual-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let api = AskTestAPI()
        await api.setCloudModels([
            .init(id: "default", name: "日常助手", vision: true, scenarios: ["ask"], contextWindowTokens: 204800,
                  maxOutputTokens: 16384, pricing: .init(multiplier: "1"), modelVersion: 1),
            .init(id: "daily", name: "日常助手", vision: true, scenarios: ["ask"], contextWindowTokens: 204800,
                  maxOutputTokens: 16384, pricing: .init(multiplier: "1"), modelVersion: 1),
            .init(id: "deep", name: "深度思考", vision: true, scenarios: ["ask"], contextWindowTokens: 204800,
                  maxOutputTokens: 16384, pricing: .init(multiplier: "2"), modelVersion: 1),
        ])
        await library.refresh(api: api, token: "fixture")
        library.defaultReference = "cloud:daily"
        try await render(ProviderModelsView(library: library, providerID: "typefluxCloud") {}.padding(24)
                         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                         .background(StudioTheme.background),
                         size: NSSize(width: 850, height: 500), appearance: .darkAqua,
                         file: root.appendingPathComponent("cloud-managed-models.png"))
        let viewModel = StudioViewModel(settingsStore: SettingsStore(defaults: defaults),
                                        historyStore: FileHistoryStore(baseDir: root.appendingPathComponent("list-history")),
                                        initialSection: .models, modelLibrary: library)
        viewModel.setModelDomain(.llm)
        try await render(ModelSettingsPage(viewModel: viewModel, library: library) { EmptyView() }
                         .padding(24).background(StudioTheme.background),
                         size: NSSize(width: 1000, height: 900), appearance: .darkAqua,
                         file: root.appendingPathComponent("provider-model-counts.png"))
    }

    @Test func renderImageCapabilitySurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try await AskImageCapabilityTests().fixture()
        defer { fixture.model.resetSession() }
        fixture.model.selectModel("cloud:text", launcher: true)
        fixture.model.launcherScreenshotNotice = nil
        fixture.model.launcherDraft.text = "帮我整理这段文字"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                             size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: appearance,
                             file: root.appendingPathComponent("image-disabled-\(name).png"))
        }
        var value = AskImageCapabilityTests().conversation()
        value.title = "讲讲这一屏在做什么"
        let call = AskToolCall(id: "capture", type: "function", function: .init(name: "computer", arguments: #"{"action":"screenshot"}"#))
        value.messages.insert(.init(id: "question", role: "user", text: value.title, createdAt: value.updatedAt), at: 0)
        value.messages.insert(.init(id: "assistant", role: "assistant", text: "我先看一下当前屏幕的内容。", toolCalls: [call], createdAt: value.updatedAt), at: 1)
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        let target = try #require(fixture.model.imageRecoveryTarget)
        try await render(AskConversationView(model: fixture.model), size: NSSize(width: 900, height: 620),
                         appearance: .darkAqua, file: root.appendingPathComponent("image-recovery.png"))
        fixture.model.selectModel("cloud:vision", launcher: false)
        try await render(AskImageRecoveryCard(model: fixture.model, target: target),
                         size: NSSize(width: 650, height: 140), appearance: .aqua,
                         file: root.appendingPathComponent("image-ready.png"), minimumPNGBytes: 4000)
        await fixture.api.hold(value.id)
        fixture.model.resumeImage(target, reference: "cloud:vision")
        do {
            try await render(AskImageRecoveryCard(model: fixture.model, target: target),
                             size: NSSize(width: 650, height: 140), appearance: .aqua,
                             file: root.appendingPathComponent("image-resuming.png"), minimumPNGBytes: 4000)
        } catch {
            await fixture.api.release(value.id)
            throw error
        }
        await fixture.api.release(value.id)
        try await fixture.wait { fixture.model.busyIds.isEmpty }

    }

    /// GUL-193: the storage icon and card, the private header chip, and the merged history.
    @Test func renderConversationStorageSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let defaults = try #require(UserDefaults(suiteName: "ask-storage-shots-" + UUID().uuidString))
        let profile = AskModelProfile(name: "我的 Ollama", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        let expiry = Int(Date().timeIntervalSince1970) + 3600
        let auth = AuthState(loadStoredToken: { ("token", expiry) }, loadStoredRefreshToken: { nil },
                             loadStoredUserProfile: { nil })
        let now = Date()
        func turn(_ id: String, _ question: String, _ answer: String) -> [AskMessage] {
            [.init(id: id + "q", role: "user", text: question, createdAt: now),
             .init(id: id + "a", role: "assistant", text: answer, createdAt: now)]
        }
        await fixture.api.seed(AskConversation(id: "cloud", title: "讲讲这一屏在做什么", revision: 1, updatedAt: now,
                                               messages: turn("c", "讲讲这一屏在做什么", "这一屏是 Grok 网页版。")))
        await fixture.localAPI.seed(AskConversation(id: "private", title: "帮我整理体检报告要点", revision: 1,
                                                    updatedAt: now.addingTimeInterval(-60),
                                                    messages: turn("p", "帮我整理体检报告要点", "已按指标分组整理。"),
                                                    modelRef: profile.reference))
        await fixture.model.refreshHistory()
        await fixture.model.select("private")
        let size = NSSize(width: 1000, height: 640)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AskConversationView(model: fixture.model, auth: auth), size: size,
                             appearance: appearance, file: root.appendingPathComponent("storage-private-\(name).png"))
        }
        await fixture.model.select("cloud")
        try await render(AskConversationView(model: fixture.model, auth: auth), size: size,
                         appearance: .darkAqua, file: root.appendingPathComponent("storage-cloud-dark.png"))
        let source = "我的 Ollama"
        let cards: [(String, AskLocalModeStatus)] = [
            ("choose", .init(source: source, searchConfigured: false, offersSignIn: false, changeable: true)),
            ("locked-local", .init(source: source, searchConfigured: true, offersSignIn: false)),
            ("locked-cloud", .init(source: source, searchConfigured: true, offersSignIn: false, local: false)),
            ("signed-out", .init(source: source, searchConfigured: false, offersSignIn: true))
        ]
        for (name, status) in cards {
            try await render(AskLocalModeCard(status: status, onOpenSearchSettings: {}, onSignIn: {})
                                .background(AskTheme.surface),
                             size: NSSize(width: AskLocalModeCard.width, height: 380), appearance: .darkAqua,
                             file: root.appendingPathComponent("storage-card-\(name).png"), minimumPNGBytes: 3000)
        }
    }

    /// Holds the workspace on screen, configured like the real window, so a window
    /// capture shows the glass the offscreen snapshots cannot draw. Each scene's name
    /// is written to `TYPEFLUX_ASK_HOLD_MARKER` while it is shown.
    /// Holds the composer with the model and reasoning card open on screen, scene by
    /// scene, so a window capture shows the real glass and the liquid fill moving.
    @Test func holdEffortPickerWindow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seconds = environment["TYPEFLUX_ASK_EFFORT_HOLD"].flatMap(Double.init),
              let marker = environment["TYPEFLUX_ASK_HOLD_MARKER"] else { return }
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let defaults = try #require(UserDefaults(suiteName: "ask-effort-hold-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            .init(id: "sonnet", name: "Claude Sonnet 5.5", reference: "cloud:sonnet", scenarios: ["ask"], reasoning: true,
                  reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
            .init(id: "m3", name: "MiniMax M3", reference: "cloud:m3", scenarios: ["ask"], reasoning: true),
            .init(id: "mini", name: "GPT-5.5 mini", reference: "cloud:mini", scenarios: ["ask"], reasoning: false)
        ], providerID: "typefluxCloud")
        let fixture = try AskTestFixture(modelLibrary: library)
        defer { fixture.model.resetSession() }
        final class Scene: ObservableObject {
            @Published var reference = "cloud:sonnet"
            @Published var effort = AskReasoningEffort.high
            @Published var page = AskModelEffortCard.Page.effort
        }
        let scene = Scene()
        struct Stage: View {
            @ObservedObject var model: AskConversationModel
            @ObservedObject var scene: Scene
            var body: some View {
                ZStack(alignment: .bottomLeading) {
                    AskConversationView(model: model)
                    AskGlassCardSurface(corner: AskGlassCardSurface<EmptyView>.menuCorner) {
                        AskModelEffortCard(library: model.modelLibrary, reference: $scene.reference,
                                           effort: $scene.effort, loggedIn: true, page: scene.page)
                            // The card keeps its own state once open, as in the menu; a new
                            // scene opens a new card.
                            .id("\(scene.page)-\(scene.reference)-\(scene.effort.rawValue)")
                    }
                    .padding(.leading, 380).padding(.bottom, 84)
                }
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "ask-effort-hold")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: environment["TYPEFLUX_ASK_HOLD_LIGHT"] == nil ? .darkAqua : .aqua)
        window.contentView = TransparentAskHostingView(rootView: Stage(model: fixture.model, scene: scene))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func show(_ name: String, reference: String, effort: AskReasoningEffort,
                  page: AskModelEffortCard.Page = .effort) async throws {
            scene.reference = reference; scene.effort = effort; scene.page = page
            fixture.model.selectModel(reference, launcher: false)
            fixture.model.reasoningEffort = effort
            try name.write(toFile: marker, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(seconds))
        }
        try await show("high", reference: "cloud:sonnet", effort: .high)
        try await show("max", reference: "cloud:sonnet", effort: .max)
        try await show("low", reference: "cloud:sonnet", effort: .low)
        try await show("auto", reference: "cloud:sonnet", effort: .providerDefault)
        try await show("three-high", reference: "cloud:m3", effort: .high)
        try await show("unsupported", reference: "cloud:mini", effort: .high)
        try await show("models", reference: "cloud:sonnet", effort: .high, page: .models)
        try "done".write(toFile: marker, atomically: true, encoding: .utf8)
    }

    @Test func holdConversationStorageWindow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seconds = environment["TYPEFLUX_ASK_HOLD"].flatMap(Double.init),
              let marker = environment["TYPEFLUX_ASK_HOLD_MARKER"] else { return }
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let defaults = try #require(UserDefaults(suiteName: "ask-storage-hold-" + UUID().uuidString))
        let profile = AskModelProfile(name: "我的 Ollama", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let fixture = try AskTestFixture(modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false))
        defer { fixture.model.resetSession() }
        let now = Date()
        func turn(_ id: String, _ question: String, _ answer: String) -> [AskMessage] {
            [.init(id: id + "q", role: "user", text: question, createdAt: now),
             .init(id: id + "a", role: "assistant", text: answer, createdAt: now)]
        }
        var cloud = AskConversation(id: "cloud", title: "讲讲这一屏在做什么", revision: 1, updatedAt: now,
                                    messages: turn("c", "讲讲这一屏在做什么", "这一屏是 Grok 网页版，你在和 Grok 讨论哈佛幸福课。"))
        cloud.usage = AskConversationUsage(version: 1, since: now, historicalGap: false,
                                           total: AskUsageTotals(microcredits: 160_790_000, calls: 3), runs: [:])
        await fixture.api.seed(cloud)
        await fixture.localAPI.seed(AskConversation(id: "private", title: "帮我整理体检报告要点", revision: 1,
                                                    updatedAt: now.addingTimeInterval(-60),
                                                    messages: turn("p", "帮我整理体检报告要点", "已按指标分组整理，异常项 3 个。"),
                                                    modelRef: profile.reference))
        await fixture.model.refreshHistory()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "ask-storage-hold")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: environment["TYPEFLUX_ASK_HOLD_LIGHT"] == nil ? .darkAqua : .aqua)
        // A signed-in account, so the footer shows what a Cloud user sees.
        let auth = AuthState(
            loadStoredToken: { ("valid-token", Int(Date().timeIntervalSince1970) + 3600) },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: {
                UserProfile(id: "u", email: "demir@example.com", name: "Demir Von", status: 1, provider: "google",
                            createdAt: "2026-03-01T00:00:00Z", updatedAt: "2026-03-01T00:00:00Z")
            },
            saveStoredToken: { _, _ in }, saveStoredUserProfile: { _ in }, clearStoredSession: {},
            fetchProfile: { _ in throw AuthError.invalidResponse },
            fetchSubscription: { _ in
                BillingSubscriptionSnapshot(planCode: "pro", status: "active", currentPeriodStart: nil,
                                            currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true,
                                            billingEnabled: true)
            },
            fetchCurrentPeriodUsageStats: { _ in throw AuthError.invalidResponse },
            fetchCurrentPeriodUsageBreakdown: { _, _ in throw AuthError.invalidResponse }
        )
        window.contentView = TransparentAskHostingView(rootView: AskConversationView(model: fixture.model, auth: auth))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func show(_ scene: String) async throws {
            try scene.write(toFile: marker, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .seconds(seconds))
        }
        await fixture.model.select("private")
        try await show("private")
        await fixture.model.select("cloud")
        try await show("cloud")
        fixture.model.newConversation(storesLocally: true)
        try await show("new-private")
        fixture.model.newConversation(storesLocally: false)
        try await show("new-cloud")
        try "done".write(toFile: marker, atomically: true, encoding: .utf8)
    }

    @Test func renderUsageSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_USAGE_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let now = Date(), runID = UUID().uuidString
        var reply = AskMessage(id: "answer", role: "assistant", text: "建议先锁定发布范围，再走通真实使用流程，最后准备验收检查表。", createdAt: now)
        reply.runId = runID
        var value = AskConversation(id: UUID().uuidString, title: "梳理产品发布计划", revision: 1, updatedAt: now,
            messages: [.init(id: "question", role: "user", text: "帮我梳理这周最值得先做的三件事。", createdAt: now), reply],
            run: .init(id: runID, deviceId: "device", status: "completed", steps: 3, updatedAt: now, tools: [], pending: []))
        let totals = AskUsageTotals(inputTokens: 17400, outputTokens: 842, totalTokens: 18242, microcredits: 360000, calls: 3)
        value.usage = .init(version: 1, since: now, historicalGap: false, total: totals, runs: [runID: totals])
        value.contextUsage = .init(modelRef: "cloud:default", inputTokens: 31200, outputReserve: 4096, capacity: 128000, summarized: true)
        await fixture.api.setUsageRecords([.init(id: "call", runId: runID, modelRef: "cloud:default", purpose: "answer", createdAt: now,
            tokens: .init(promptTokens: 9200, completionTokens: 552, totalTokens: 9752), source: "provider", microcredits: 240000, status: "confirmed", version: 1)])
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AskConversationView(model: fixture.model), size: NSSize(width: 1100, height: 740),
                appearance: appearance, file: root.appendingPathComponent("usage-chat-\(name).png"))
            try await render(AskConversationView(model: fixture.model, showsUsage: true), size: NSSize(width: 1100, height: 740), appearance: appearance, file: root.appendingPathComponent("usage-panel-\(name).png"))
        }
    }

    /// The workspace's floating chrome. System glass is composited by the window
    /// server and cannot be cached offscreen, so the layout is captured with the
    /// opaque Reduce Transparency material, which shares every frame with the glass.
    @Test func renderWorkspaceGlassLayout() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = try AskTestFixture()
        let now = Date()
        let call = AskToolCall(id: "screen", type: "function", function: .init(name: "computer", arguments: #"{"action":"screenshot"}"#))
        let conversation = AskConversation(id: "glass", title: "优化帖子：口语化表达", revision: 3, updatedAt: now, messages: [
            .init(id: "q1", role: "user", text: "帮我优化一下这个帖子的内容，加入比较口语化的表达。", createdAt: now),
            .init(id: "a1", role: "assistant", text: "我帮你把口语化的核心观点整合进去。先截个图看一下需要编辑的文本范围。", isError: true, createdAt: now),
            .init(id: "a2", role: "assistant", text: "", toolCalls: [call], createdAt: now),
            .init(id: "t1", role: "tool", text: "截图已获取", toolCallId: "screen", isError: false, createdAt: now),
            .init(id: "a3", role: "assistant", text: String(repeating: "看了一圈，我觉得这个工具特别适合我的场景。本地和远程的 agent 都能统一管理。\n\n", count: 6), createdAt: now)
        ], run: .init(id: "run", deviceId: "device", status: "completed", steps: 2, updatedAt: now, tools: [], pending: []))
        await fixture.api.seed(conversation)
        await fixture.model.refreshHistory()
        await fixture.model.select(conversation.id)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await render(AskConversationView(model: fixture.model).environment(\.askGlassMaterialOverride, .opaque),
                             size: NSSize(width: 1100, height: 740), appearance: appearance,
                             file: root.appendingPathComponent("workspace-layout-\(name).png"),
                             voice: name == "dark" ? fixture.model.voiceInput : nil)
        }
        fixture.model.newConversation()
        try await render(AskConversationView(model: fixture.model).environment(\.askGlassMaterialOverride, .opaque),
                         size: NSSize(width: 1100, height: 740), appearance: .darkAqua,
                         file: root.appendingPathComponent("workspace-empty-dark.png"))
        fixture.model.resetSession()
    }

    /// The ⌘K palette over the workspace, with the keyboard highlight on the
    /// first matching conversation, in both appearances.
    @Test func renderSearchPalette() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let now = Date()
        let history = [
            AskConversationSummary(id: "p1", title: "讲讲这一屏在做什么", updatedAt: now),
            AskConversationSummary(id: "p2", title: "早上好呀。", updatedAt: now.addingTimeInterval(-3600)),
            AskConversationSummary(id: "p3", title: "解释 Swift 并发里的 actor 重入", updatedAt: now.addingTimeInterval(-86400 * 4))
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let palette = AskSearchPaletteView(conversations: history, available: AskPaletteAction.allCases,
                                               onAction: { _ in }, onOpen: { _ in }, onClose: {})
                .environment(\.askGlassMaterialOverride, .opaque)
                .frame(width: 900, height: 560)
                .background(AskTheme.surface)
            try await render(palette, size: NSSize(width: 900, height: 560), appearance: appearance,
                             file: root.appendingPathComponent("search-palette-\(name).png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL, voice: AskVoiceInput? = nil, minimumPNGBytes: Int = 10000) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        func snapshot(_ url: URL) throws {
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url)
            #expect(png.count > minimumPNGBytes)
        }
        try snapshot(file)
        if file.lastPathComponent.hasPrefix("models-settings-") ||
            (ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_LARGE_CATALOG"] == "1" && file.lastPathComponent.hasPrefix("models-provider-")) {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                let own = (view as? NSScrollView).map { [$0] } ?? []
                return own + view.subviews.flatMap(scrollViews)
            }
            let scrollers = scrollViews(hosting).filter { $0.bounds.width > 500 }
            #expect(scrollers.count == 1, "Model settings must have one vertical scroll owner")
            let scroll = try #require(scrollers.first)
            let height = scroll.documentView?.bounds.height ?? 0
            let start = scroll.contentView.bounds.minY
            scroll.verticalScrollElasticity = .none
            for _ in 0..<12 {
                let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                    wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
                scroll.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
                try await Task.sleep(for: .milliseconds(16))
                #expect(abs((scroll.documentView?.bounds.height ?? 0) - height) < 1,
                        "Wheel scrolling must not resize the provider document")
            }
            #expect(scroll.contentView.bounds.minY > start, "Mouse wheel must move the model list")
            if let profile = ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_PROFILE"],
               file.lastPathComponent == (ProcessInfo.processInfo.environment["TYPEFLUX_SCROLL_SURFACE"] ?? "models-settings-dark.png") {
                try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                    .write(to: URL(fileURLWithPath: profile + ".pid"))
                var elapsed: [Double] = []
                var details = ["index,wheel_ms,layout_ms,display_ms,total_ms"]
                for index in 0..<600 {
                    let began = ProcessInfo.processInfo.systemUptime
                    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                        wheelCount: 1, wheel1: (index / 60).isMultiple(of: 2) ? -3 : 3, wheel2: 0, wheel3: 0))
                    scroll.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
                    let wheelEnd = ProcessInfo.processInfo.systemUptime
                    hosting.layoutSubtreeIfNeeded()
                    let layoutEnd = ProcessInfo.processInfo.systemUptime
                    hosting.displayIfNeeded()
                    let displayEnd = ProcessInfo.processInfo.systemUptime
                    elapsed.append((displayEnd - began) * 1000)
                    details.append("\(index),\((wheelEnd - began) * 1000),\((layoutEnd - wheelEnd) * 1000),\((displayEnd - layoutEnd) * 1000),\((displayEnd - began) * 1000)")
                    try await Task.sleep(for: .milliseconds(16))
                }
                try Data(details.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: profile + ".csv"))
                elapsed.sort()
                let report = "wheel+layout+display ms: median=\(elapsed[300]) p95=\(elapsed[570]) max=\(elapsed.last!)"
                try Data(report.utf8).write(to: URL(fileURLWithPath: profile + ".txt"))
            }

        }
        if file.lastPathComponent == "conversation.png" {
            func probes(_ view: NSView) -> [AskHistoryPullRefresh.Probe] {
                (view as? AskHistoryPullRefresh.Probe).map { [$0] } ?? view.subviews.flatMap(probes)
            }
            let probe = try #require(probes(hosting).first)
            // Drive the indicator directly: native overscroll cannot be synthesised here.
            probe.onDistance(40)
            try await Task.sleep(for: .milliseconds(80))
            try snapshot(file.deletingLastPathComponent().appendingPathComponent("history-pull.png"))
            probe.onDistance(0)
            try await Task.sleep(for: .milliseconds(80))
        }
        if let voice {
            func editors(_ view: NSView) -> [AskComposerTextView.Editor] {
                (view as? AskComposerTextView.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
            }
            let editor = try #require(editors(hosting).first)
            window.makeFirstResponder(editor)
            let recorder = AskTestVoiceRecorder(); recorder.holdTranscript = true
            recorder.transcript = "请进一步说明使用成本。"
            voice.recorder = recorder
            #expect(voice.begin(in: editor))
            try await Task.sleep(for: .milliseconds(120))
            let base = file.deletingPathExtension().path
            try snapshot(URL(fileURLWithPath: base + "-listening.png"))
            voice.stop()
            try await Task.sleep(for: .milliseconds(120))
            #expect(recorder.stops == 1)
            try snapshot(URL(fileURLWithPath: base + "-transcribing.png"))
            recorder.releaseTranscript()
            for _ in 0..<100 where voice.isOccupied { try await Task.sleep(for: .milliseconds(2)) }
            #expect(!voice.isOccupied)
            try await Task.sleep(for: .milliseconds(60))
            try snapshot(URL(fileURLWithPath: base + "-filled.png"))
        }
    }
}

private final class AskWindowActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
    }
}
