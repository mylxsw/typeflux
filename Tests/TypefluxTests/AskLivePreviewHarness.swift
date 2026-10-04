import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in on-screen preview for design fidelity checks. System Liquid Glass is
/// composited by the window server and cannot be cached offscreen, so this
/// opens the production workspace window with the design board's content and
/// keeps it on screen for `TYPEFLUX_ASK_LIVE_PREVIEW` seconds to be captured.
/// `TYPEFLUX_ASK_LIVE_SCENE` picks chat (default), empty, palette or approval;
/// `TYPEFLUX_ASK_LIVE_APPEARANCE` picks dark (default) or light.
/// `TYPEFLUX_ASK_LIVE_ACCOUNT=local` shows a signed-out Mac that runs Ask only on
/// the user's own (Ollama) models instead of the signed-in Cloud account.
/// It never touches a real account, microphone, screen or desktop tool.
@Suite("Ask live preview", .serialized)
@MainActor
struct AskLivePreviewHarness {
    @Test func showDesignStateOnScreen() async throws {
        guard let value = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_LIVE_PREVIEW"],
              let seconds = Double(value) else { return }
        let environment = ProcessInfo.processInfo.environment
        let scene = environment["TYPEFLUX_ASK_LIVE_SCENE"] ?? "chat"
        let appearance: NSAppearance.Name = environment["TYPEFLUX_ASK_LIVE_APPEARANCE"] == "light" ? .aqua : .darkAqua
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let localOnly = environment["TYPEFLUX_ASK_LIVE_ACCOUNT"] == "local"
        let auth = AuthState.shared
        let previousProfile = auth.userProfile, previousLoggedIn = auth.isLoggedIn
        auth.userProfile = localOnly ? nil : UserProfile(id: "preview", email: "demir@example.com", name: "Demir Von",
                                                         status: 1, provider: "email", createdAt: "", updatedAt: "")
        auth.isLoggedIn = !localOnly
        defer { auth.userProfile = previousProfile; auth.isLoggedIn = previousLoggedIn }

        let librarySuite = "ask-live-library-" + UUID().uuidString
        let libraryDefaults = try #require(UserDefaults(suiteName: librarySuite))
        defer { libraryDefaults.removePersistentDomain(forName: librarySuite) }
        let library = AskModelLibrary(defaults: libraryDefaults, automaticallyLoadsCatalog: false)
        try library.addModels(Self.cloudModels(), providerID: "typefluxCloud")
        library.defaultReference = "cloud:minimax-m3"
        if localOnly {
            try library.addModels(Self.localModels(), providerID: "ollama")
            library.ollamaAvailable = true
            library.defaultReference = try #require(library.firstLocalReference(hasImage: false))
        }
        let modelReference = library.defaultReference
        // The approval flow runs a stubbed tool call; the default library keeps it model-agnostic.
        let fixture = try scene == "approval" || scene == "motion"
            ? AskTestFixture(localOnly: localOnly)
            : AskTestFixture(localOnly: localOnly, modelLibrary: library)
        for conversation in Self.history() {
            await fixture.api.seed(localOnly ? Self.localized(conversation, modelReference: modelReference) : conversation)
        }
        await fixture.model.refreshHistory()
        switch scene {
        case "empty":
            fixture.model.newConversation()
            fixture.model.draft.screenshot = Self.screenshotDataURL()
            fixture.model.draft.includeScreenshot = true
        case "approval":
            await fixture.model.select("c3")
            let call = AskToolCall(id: "browser-send", type: "function",
                                   function: .init(name: "browser", arguments: #"{"action":"click","target":"发送评论"}"#))
            await fixture.api.setTool(call)
            fixture.model.draft.text = "帮我在 Chrome 里把刚才的结论回复到 GUL-155 这条 issue 下面"
            fixture.model.submitDraft()
            try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        default:
            // "chat-top" opens the conversation at its first message.
            await fixture.model.select("c1")
            fixture.model.draft.screenshot = Self.screenshotDataURL()
            fixture.model.draft.includeScreenshot = true
        }

        let suite = "ask-live-preview-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AskConversationWindowController(settings: SettingsStore(defaults: defaults), model: fixture.model)
        controller.showConversation()
        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-conversations"
        })
        window.appearance = NSAppearance(named: appearance)
        window.setFrame(NSRect(x: 120, y: 120, width: 1180, height: 760), display: true)
        if scene == "chat-top" || scene.hasSuffix("-menu") {
            // Scroll the transcript to its very top, as on the design board's first screen.
            try await Task.sleep(for: .milliseconds(500))
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            if let content = window.contentView,
               let scroll = scrollViews(content).max(by: { $0.frame.width < $1.frame.width }) {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if scene == "palette" {
            try await Task.sleep(for: .milliseconds(400))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "k", charactersIgnoringModifiers: "k",
                                                      isARepeat: false, keyCode: 40))
            window.performKeyEquivalent(with: event)
        }
        if scene == "launcher" {
            fixture.model.launcherDraft = AskDraft(text: "", includeScreenshot: false)
            controller.showLauncher()
            try await fixture.wait { NSApp.windows.contains { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-launcher" && $0.isVisible } }
            try await Task.sleep(for: .milliseconds(600))
        }
        if scene == "model-menu" || scene == "reason-menu", let content = window.contentView {
            // Open the production menu card over the composer's model or reasoning button.
            try await Task.sleep(for: .milliseconds(500))
            let anchor = NSView(frame: NSRect(x: scene == "model-menu" ? 356 : 474, y: 45, width: 100, height: 34))
            content.addSubview(anchor)
            if scene == "model-menu" {
                AskGlassMenuPresenter.shared.show(
                    AskModelChoices(library: library, reference: .constant(modelReference), loggedIn: !localOnly,
                                    composerStyle: true, onManage: {}, offersCloudSignIn: localOnly),
                    owner: UUID(), anchor: anchor, onClose: {})
            } else {
                AskGlassMenuPresenter.shared.show(
                    AskModelEffortCard(library: library, reference: .constant(modelReference),
                                       effort: .constant(.providerDefault), loggedIn: !localOnly),
                    owner: UUID(), anchor: anchor, onClose: {})
            }
        }
        let marker = environment["TYPEFLUX_ASK_LIVE_MARKER"].map(URL.init(fileURLWithPath:))
        let captured = scene == "launcher"
            ? NSApp.windows.first { $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.ask-launcher" } ?? window
            : window
        // The capture tool lists only normal-level windows; the panel floats.
        if captured !== window { captured.level = .normal; captured.orderFront(nil) }
        if let marker { try Data(String(captured.windowNumber).utf8).write(to: marker) }
        if scene == "motion" {
            try await playMotionScript(fixture: fixture, library: library, window: window)
        }
        try await Task.sleep(for: .seconds(seconds))
        if let marker { try? FileManager.default.removeItem(at: marker) }
        window.orderOut(nil)
        fixture.model.resetSession()
    }

    /// A scripted walk through the window's motion for a screen recording:
    /// the selection slides, a sent message and its answer rise in, the model
    /// menu and the ⌘K palette pop in.
    private func playMotionScript(fixture: AskTestFixture, library: AskModelLibrary, window: NSWindow) async throws {
        try await Task.sleep(for: .seconds(3))
        await fixture.model.select("c3")
        try await Task.sleep(for: .milliseconds(1200))
        await fixture.model.select("c1")
        try await Task.sleep(for: .milliseconds(1200))
        await fixture.model.select("c4")
        try await Task.sleep(for: .milliseconds(900))
        fixture.model.draft.text = "帮我总结一下这个网页的重点"
        try await Task.sleep(for: .milliseconds(600))
        fixture.model.submitDraft()
        try await Task.sleep(for: .milliseconds(2200))
        if let content = window.contentView {
            let anchor = NSView(frame: NSRect(x: 356, y: 45, width: 100, height: 34))
            content.addSubview(anchor)
            AskGlassMenuPresenter.shared.show(
                AskModelChoices(library: library, reference: .constant("cloud:minimax-m3"), loggedIn: true,
                                composerStyle: true, onManage: {}),
                owner: UUID(), anchor: anchor, onClose: {})
            try await Task.sleep(for: .milliseconds(1600))
            AskGlassMenuPresenter.shared.hide()
            anchor.removeFromSuperview()
        }
        try await Task.sleep(for: .milliseconds(600))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "k", charactersIgnoringModifiers: "k",
                                                  isARepeat: false, keyCode: 40))
        window.performKeyEquivalent(with: event)
    }

    /// The design board's cloud catalog.
    static func cloudModels() -> [RegisteredModel] {
        func model(_ id: String, _ name: String, vision: Bool, multiplier: String, context: Int, output: Int) -> RegisteredModel {
            RegisteredModel(id: id, name: name, reference: "cloud:" + id, vision: vision, scenarios: ["ask"],
                            pricing: .init(multiplier: multiplier), contextWindowTokens: context,
                            maxOutputTokens: output, reasoning: true)
        }
        return [
            model("minimax-m3", "MiniMax M3", vision: true, multiplier: "1", context: 1_000_000, output: 128_000),
            model("claude-sonnet", "Claude Sonnet 5.5", vision: true, multiplier: "3", context: 1_000_000, output: 64000),
            model("gpt", "GPT-5.1", vision: true, multiplier: "2", context: 400_000, output: 128_000),
            model("gemini", "Gemini 3 Pro", vision: true, multiplier: "2", context: 1_000_000, output: 64000),
            model("deepseek", "DeepSeek V3.2", vision: false, multiplier: "0.5", context: 128_000, output: 32000)
        ]
    }

    /// Models a signed-out user pulled into Ollama.
    static func localModels() -> [RegisteredModel] {
        [
            RegisteredModel(id: "qwen3:8b", name: "qwen3:8b"),
            RegisteredModel(id: "llama3.2-vision:11b", name: "llama3.2-vision:11b", vision: true),
            RegisteredModel(id: "gemma3:4b", name: "gemma3:4b")
        ]
    }

    /// A conversation as a local run stores it: on the user's model, without Cloud credits.
    static func localized(_ conversation: AskConversation, modelReference: String) -> AskConversation {
        var local = conversation
        if local.modelRef != nil { local.modelRef = modelReference }
        local.usage = nil
        if let context = local.contextUsage {
            local.contextUsage = .init(modelRef: modelReference, inputTokens: context.inputTokens,
                                       outputReserve: context.outputReserve, capacity: 32768, summarized: false)
        }
        return local
    }

    /// The design board's sidebar: today, yesterday and an older conversation.
    static func history(now: Date = Date()) -> [AskConversation] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today) ?? now
        }
        let call = AskToolCall(id: "screen", type: "function",
                               function: .init(name: "computer", arguments: #"{"action":"screenshot"}"#))
        let main = AskConversation(id: "c1", title: "讲讲这一屏在做什么", revision: 3, updatedAt: at(0, 19, 5), messages: [
            .init(id: "q1", role: "user", text: "讲讲这一屏在做什么", image: screenshotDataURL(), createdAt: at(0, 19, 5)),
            .init(id: "a1", role: "assistant", text: "", toolCalls: [call], createdAt: at(0, 19, 5),
                  reasoning: "用户想知道当前屏幕在做什么。先截图查看屏幕内容，再按区域组织说明。", reasoningMilliseconds: 4200),
            .init(id: "t1", role: "tool", text: "截图已获取", toolCallId: "screen", isError: false, createdAt: at(0, 19, 5)),
            .init(id: "a2", role: "assistant", text: answer, createdAt: at(0, 19, 5), runId: "run")
        ], run: .init(id: "run", deviceId: "device", status: "completed", steps: 2, updatedAt: at(0, 19, 5),
                      tools: [], pending: []),
        modelRef: "cloud:minimax-m3",
        usage: .init(version: 1, since: at(0, 19, 5), historicalGap: false,
                     total: .init(inputTokens: 9842, outputTokens: 1105, totalTokens: 10947, microcredits: 840_000, calls: 2),
                     runs: ["run": .init(inputTokens: 9842, outputTokens: 1105, totalTokens: 10947, microcredits: 840_000, calls: 2)]),
        contextUsage: .init(modelRef: "cloud:minimax-m3", inputTokens: 9842, outputReserve: 4096, capacity: 1_000_000,
                            summarized: false),
        memory: AskMemory(global: "偏好简洁的中文回答。",
                          app: .init(id: "com.google.Chrome", name: "Chrome", excerpts: ["GUL-155 侧边的 AI 助手"])))
        func simple(_ id: String, _ title: String, _ date: Date) -> AskConversation {
            AskConversation(id: id, title: title, revision: 1, updatedAt: date, messages: [
                .init(id: id + "-q", role: "user", text: title, createdAt: date),
                .init(id: id + "-a", role: "assistant", text: "好的。", createdAt: date)
            ])
        }
        return [
            main,
            simple("c2", "讲讲这一屏在做什么", at(0, 19, 4)),
            simple("c3", "早上好呀。", at(0, 10, 45)),
            simple("c4", "Hello, can you hear me?", at(0, 1, 9)),
            simple("c5", "个人用户做游戏怎么去获取流量", at(-1, 20, 27)),
            simple("c6", "帮我优化一下这个帖子的文案", at(-1, 18, 34)),
            simple("c7", "解释 Swift 并发里的 actor 重入", at(-4, 9, 0))
        ]
    }

    static let answer = """
    这屏主要在做两件事：

    #### 1. 顶部 Chrome 浏览器（被压扁到只剩标签栏）

    - 打开了 Multica 的 GuluAI 收件箱：`multica.ai/gulu/inbox?issue=01a0fbcb-7cf8-7183-af22-58ce14155c81`
    - 顶部能看到一排 issue 条目，其中一个是「CreativeStudio › GUI-155 侧边的 AI 助手：空的输出应该是流式的」
    - 右侧栏被一个「快捷键说明面板」挡住了，所以内容看不清

    #### 2. 主体是一个新建的终端会话面板（Typeflux 的 Terminal）

    它弹出了「New terminal session（新建终端会话）」的帮助提示，里面列出了几组快捷键：

    | 快捷键 | 功能 |
    | --- | --- |
    | ⌘ ` | start a new agent conversation（新建 agent 对话） |
    | ⌥⌘ ` | start a new cloud agent conversation（新建云端 agent 对话） |
    | ⇧ ↑/↓ | cycle past commands and conversations（翻看历史命令 / 对话） |
    | ⌘ ⇧ R | open code review（打开代码审查） |
    """

    /// A small synthetic "screen" for the screenshot chip and message thumbnail.
    static func screenshotDataURL() -> String {
        let size = NSSize(width: 240, height: 150)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.16, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.29, green: 0.12, blue: 0.42, alpha: 1),
                                NSColor(srgbRed: 0.72, green: 0.27, blue: 0.12, alpha: 1)])?.draw(in: rect, angle: -35)
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 20), xRadius: 6, yRadius: 6).fill()
            NSColor(white: 1, alpha: 0.35).setFill()
            for row in 0 ..< 4 { NSRect(x: 40, y: 100 - row * 14, width: 120 - row * 15, height: 5).fill() }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
