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
        #expect(launcher.styleMask == .borderless)
        #expect(launcher.frame.width == AskMetrics.launcherWidth)
        #expect(launcher.frame.height <= 120)
        let bottom = launcher.frame.minY
        let visibleFrame = try #require(launcher.screen?.visibleFrame)
        #expect(abs(bottom + 6 - visibleFrame.minY - OverlayController.recordingVisibleBottomInset) < 1)
        #expect(abs(launcher.frame.midX - visibleFrame.midX) < 1)
        fixture.model.launcherDraft.text = String(repeating: "Line of text\n", count: 30)
        try await fixture.wait { launcher.frame.height >= 200 }
        #expect(launcher.frame.height <= 230)
        #expect(abs(launcher.frame.minY - bottom) < 1)
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
                         size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .darkAqua, file: root.appendingPathComponent("launcher.png"))

        try await render(AskLauncherView(model: fixture.model, onDismiss: {}),
                         size: NSSize(width: AskMetrics.launcherWidth, height: 114), appearance: .aqua, file: root.appendingPathComponent("launcher-light.png"), voice: fixture.model.voiceInput)
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
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL, voice: AskVoiceInput? = nil) async throws {
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
            #expect(png.count > 10000)
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
