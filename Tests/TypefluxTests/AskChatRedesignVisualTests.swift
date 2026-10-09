import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import Vision

/// Recovery decisions taken from the card and the inspector.
@Suite("Chat recovery decisions", .serialized, .exclusiveUIState)
@MainActor
struct AskRecoveryDecisionTests {
    private func uncertain(_ fixture: AskTestFixture) async throws -> AskConversation {
        var value = AskRecoveryFixture.conversation()
        value.messages[0].runId = value.run?.id
        value.run?.steps = 7
        _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        return value
    }

    @Test func checkAndContinueEndsTheRunAndAsksToCheckFirst() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = try await uncertain(fixture)
        #expect(fixture.model.recoveryPresentation.unknown)
        #expect(fixture.model.runPhase == .needsDecision(step: 7))
        fixture.model.draft.text = "keep what I typed"
        fixture.model.inspectingRecovery = true
        await fixture.model.checkAndContinueRecovery()
        try await fixture.wait {
            !fixture.model.busyIds.contains(value.id) && fixture.model.selected?.run?.id != value.run?.id
        }
        let sends = await fixture.api.sends
        #expect(sends.map(\.text) == [L("ask.recovery.checkPrompt")])
        #expect(fixture.model.draft.text == "keep what I typed")
        #expect(!fixture.model.inspectingRecovery)
        #expect(!fixture.model.recoveryPresentation.isVisible)
        #expect(fixture.model.runPhase == .completed(steps: 1))
    }

    @Test func checkAndContinueIsRefusedOnAnotherDevice() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.run?.deviceId = "elsewhere"
        _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(fixture.model.recoveryPresentation.otherDevice)
        await fixture.model.checkAndContinueRecovery()
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.selected?.run?.status == "waiting_tool")
    }

    @Test func performRoutesEveryChoice() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = try await uncertain(fixture)
        fixture.model.inspectingRecovery = true
        fixture.model.performRecovery(.selfCheck)
        #expect(!fixture.model.inspectingRecovery)
        #expect(fixture.model.selected?.run?.status == "waiting_tool")

        fixture.model.performRecovery(.stop)
        try await fixture.wait { fixture.model.selected?.run?.status == "cancelled" }
        #expect(fixture.model.runPhase == .needsDecision(step: 7))
        #expect(await fixture.api.sends.isEmpty)

        // Neither of these may dispatch anything while the outcome is unknown.
        fixture.model.inspectingRecovery = true
        fixture.model.performRecovery(.continueRun)
        fixture.model.performRecovery(.refresh)
        // Let the refresh start before waiting for it to finish.
        try await Task.sleep(for: .milliseconds(30))
        try await fixture.wait { !fixture.model.recoveryWorking }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.selected?.id == value.id)

        fixture.model.performRecovery(.checkAndContinue)
        try await fixture.wait { fixture.model.selected?.run?.status == "completed" }
        #expect(await fixture.api.sends.map(\.text) == [L("ask.recovery.checkPrompt")])
    }

    @Test func followUpNeedsAConversation() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.sendFollowUp("Finish the draft")
        try await Task.sleep(for: .milliseconds(20))
        #expect(await fixture.api.sends.isEmpty)
    }
}

/// Renders the redesigned chat scenes in both appearances. With
/// `TYPEFLUX_CHAT_SCREENSHOTS=<dir>` the PNGs are written for review.
@Suite("Chat redesign rendering", .serialized, .exclusiveUIState)
@MainActor
struct AskChatRedesignVisualTests {
    private static let title = "帮我创建一个能够查询当前城市天气的 workflow"
    /// Whole-window renders are slow and timing-sensitive; like the other chat
    /// screenshot suites they run only when screenshots are requested.
    private static let windows = ProcessInfo.processInfo.environment["TYPEFLUX_CHAT_SCREENSHOTS"] != nil

    private func chinese(_ key: String, _ arguments: CVarArg...) -> String {
        let path = Bundle.module.path(forResource: "zh-Hans", ofType: "lproj")!
        let format = Bundle(path: path)!.localizedString(forKey: key, value: nil, table: nil)
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }

    /// Ignores spacing, separator dots and two glyphs Vision confuses in small CJK text.
    private func readable(_ text: String) -> String {
        text.replacingOccurrences(of: "井", with: "并").replacingOccurrences(of: "语", with: "话")
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !"·•・‧∙．.…-".unicodeScalars.contains($0) }
            .map(String.init).joined()
    }

    private func authoring(_ chat: AskTestFixture, _ fixture: AskWorkflowFixture) -> AskWorkflowAuthoringStore {
        let authoring = AskWorkflowAuthoringStore(workflows: fixture.store,
            root: fixture.home.appendingPathComponent("Authoring"),
            staging: .init(root: fixture.home.appendingPathComponent("previews")), owner: { "owner" })
        chat.model.workflowAuthoring = authoring
        authoring.onChange = { [weak model = chat.model] in model?.objectWillChange.send() }
        return authoring
    }

    private func weatherManifest(complete: Bool) -> String {
        var object: [String: Any] = [
            "schema": 1, "id": "local.weather", "name": "Weather", "description": "查询当前所在城市的实时天气",
            "keywords": complete ? [["keyword": "weather"], ["keyword": "tq"]] : [],
            "output": "items"
        ]
        object["command"] = complete
            ? ["runtime": "zsh", "inline": "print -r -- '{\"items\":[{\"title\":\"杭州 · 晴 22°C\",\"subtitle\":\"体感 21° · 湿度 40% · 东北风 2 级\"},{\"title\":\"明天 · 多云 16°–24°C\",\"subtitle\":\"降水概率 10%\"}]}'"]
            : ["runtime": "python3", "script": "main.py"]
        return AskWorkflowDraft.format(object)!
    }

    private func conversation(unknown: Bool) -> AskConversation {
        let start = AskToolCall(id: "start", function: .init(name: "workflow_start", arguments: #"{"name":"Weather"}"#))
        let write = AskToolCall(id: "call", function: .init(name: "workflow_propose", arguments: "{}"))
        var value = AskConversation(id: "weather", title: Self.title, revision: 3, updatedAt: Date(), messages: [
            .init(id: "question", role: "user", text: Self.title + "。", createdAt: Date(), runId: "run"),
            .init(id: "step", role: "assistant", text: "", toolCalls: unknown ? [start, write] : [start],
                  createdAt: Date(), runId: "run"),
            .init(id: "start-result", role: "tool", text: "{}", toolCallId: "start", createdAt: Date(), runId: "run")
        ])
        if !unknown {
            value.messages.append(.init(id: "answer", role: "assistant",
                text: "已生成 Weather 工作流：在启动器里输入 weather 或 tq 即可查询当前城市的实时天气。可以先在右侧试运行，确认结果后再保存到启动器。",
                createdAt: Date(), runId: "run"))
        }
        value.run = .init(id: "run", deviceId: "device", status: unknown ? "waiting_tool" : "completed",
                          steps: unknown ? 7 : 9, updatedAt: Date(), tools: [], pending: unknown ? [write] : [])
        value.usage = .init(version: 1, since: Date(), historicalGap: false,
                            total: .init(microcredits: 1_328_970_000, calls: 9), runs: [:])
        return value
    }

    private func audit(_ value: AskConversation) -> AskExecutionAudit {
        .init(identity: .init(owner: "owner", conversation: value, run: value.run!, callId: "call", kind: "tool"),
              toolVersion: "v1", argumentsHash: AskToolPolicy.digest("input"))
    }

    @discardableResult
    private func render(_ view: some View, name: String, dark: Bool, size: NSSize,
                        settle: Duration = .zero, invalidate: () -> Void = {}) async throws -> String {
        _ = NSApplication.shared
        func content() -> some View {
            view.environment(\.askGlassMaterialOverride, .opaque)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(AskTheme.surface)
        }
        // Own the global language only in synchronous stretches, never across an
        // await, so suites running alongside keep their own language.
        let previous = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        var restored = false
        defer { if !restored { AppLocalization.shared.setLanguage(previous) } }
        let hosting = NSHostingView(rootView: content())
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        if settle > .zero {
            AppLocalization.shared.setLanguage(previous)
            try await Task.sleep(for: settle)
            AppLocalization.shared.setLanguage(.simplifiedChinese)
        }
        hosting.rootView = content()
        invalidate()
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        AppLocalization.shared.setLanguage(previous)
        restored = true
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CHAT_SCREENSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent(name + ".png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    @Test func uncertainRunWithIncompleteDraft() async throws {
        let chat = try AskTestFixture(), fixture = try AskWorkflowFixture()
        defer { chat.model.resetSession(); try? FileManager.default.removeItem(at: chat.root) }
        let authoring = authoring(chat, fixture)
        let value = conversation(unknown: true)
        _ = try await chat.cache.claimExecution(audit(value), owner: "owner")
        await chat.api.seed(value)
        await chat.model.refreshHistory()
        await chat.model.select(value.id)
        let session = try authoring.start(value.id, name: "Weather", workflowID: nil)
        _ = session.submit(.init(summary: "Draft", manifestText: weatherManifest(complete: false), files: [:], deletes: []))
        #expect(session.checklist.missing == 2)
        #expect(chat.model.runPhase == .needsDecision(step: 7))

        for dark in [true, false] where Self.windows {
            let text = try await render(AskConversationView(model: chat.model), name: "chat-unknown-\(dark ? "dark" : "light")",
                                        dark: dark, size: .init(width: 1480, height: 860), settle: .milliseconds(500),
                                        invalidate: { chat.model.objectWillChange.send(); session.objectWillChange.send() })
            let flat = readable(text)
            // The panel and header; the card's buttons are checked on the card alone below.
            for expected in [chinese("ask.run.needsDecision"), chinese("ask.workflow.chat.check.title"),
                             chinese("ask.workflow.chat.complete"), chinese("ask.usage.conversationSpent"),
                             chinese("ask.workflow.chat.hint.complete", 2)] {
                #expect(flat.contains(readable(expected)), "Missing \(expected) in \(dark ? "dark" : "light")")
            }
            #expect(!flat.contains(readable(chinese("ask.recovery.retransmit"))))
        }

        let presentation = chat.model.recoveryPresentation
        let recovery = try await render(AskRecoveryCard(presentation: presentation).padding(20),
                                        name: "recovery-card-light", dark: false, size: .init(width: 760, height: 170))
        for expected in [chinese(presentation.titleKey), chinese("ask.recovery.checkAndContinue"),
                         chinese("ask.recovery.end"), chinese("ask.recovery.details")] {
            #expect(readable(recovery).contains(readable(expected)), "Missing \(expected) on the recovery card")
        }
        #expect(!readable(recovery).contains(readable(chinese("ask.recovery.retransmit"))))

        let card = try await render(AskWorkflowAuthoringCard(session: session, selected: false, open: {}).padding(20),
                                    name: "card-incomplete-light", dark: false, size: .init(width: 760, height: 110))
        #expect(readable(card).contains(readable(chinese("ask.workflow.chat.view"))))
        #expect(readable(card).contains(readable(chinese("ask.workflow.chat.status.missing", 2))))

        chat.model.inspectingRecovery = true
        for dark in [true, false] {
            let text = try await render(AskRecoveryInspector(model: chat.model).frame(width: 480),
                                        name: "inspector-unknown-\(dark ? "dark" : "light")",
                                        dark: dark, size: .init(width: 560, height: 700))
            let flat = readable(text)
            for expected in [chinese("ask.recovery.inspect"), chinese("ask.recovery.option.check"),
                             chinese("ask.recovery.option.self"), chinese("ask.recovery.option.stop"),
                             chinese("ask.recovery.recommended"), chinese("ask.recovery.close"),
                             chinese("ask.recovery.checkAndContinue"), chinese("ask.recovery.timeline.done", 6)] {
                #expect(flat.contains(readable(expected)), "Missing \(expected)")
            }
        }
        chat.model.inspectingRecovery = false
    }

    @Test func completedRunWithReadyDraft() async throws {
        let chat = try AskTestFixture(), fixture = try AskWorkflowFixture()
        defer { chat.model.resetSession(); try? FileManager.default.removeItem(at: chat.root) }
        let authoring = authoring(chat, fixture)
        let value = conversation(unknown: false)
        await chat.api.seed(value)
        await chat.model.refreshHistory()
        await chat.model.select(value.id)
        let session = try authoring.start(value.id, name: "Weather", workflowID: nil)
        _ = session.submit(.init(summary: "Ready", manifestText: weatherManifest(complete: true), files: [:], deletes: []))
        #expect(session.checklist.isComplete)
        session.query = "杭州"
        session.tester.searchPath = { "/bin:/usr/bin" }
        _ = await session.testLatestProposal([.init(query: session.query)])
        #expect(session.currentPreview?.result.succeeded == true)
        #expect(chat.model.runPhase == .completed(steps: 9))

        for dark in [true, false] where Self.windows {
            let text = try await render(AskConversationView(model: chat.model), name: "chat-ready-\(dark ? "dark" : "light")",
                                        dark: dark, size: .init(width: 1480, height: 860), settle: .milliseconds(500),
                                        invalidate: { chat.model.objectWillChange.send(); session.objectWillChange.send() })
            let flat = readable(text)
            for expected in [chinese("ask.workflow.chat.resultOK"), chinese("ask.workflow.chat.hint.tested"),
                             chinese("ask.workflow.chat.save"), chinese("ask.workflow.chat.tab.code")] {
                #expect(flat.contains(readable(expected)), "Missing \(expected) in \(dark ? "dark" : "light")")
            }
            #expect(!flat.contains(readable(chinese("ask.workflow.chat.check.title"))))
        }

        let panel = AskWorkflowAuthoringPanel(session: session, close: {}, discard: {})
        for dark in [true, false] {
            try await render(panel, name: "panel-ready-\(dark ? "dark" : "light")", dark: dark,
                             size: .init(width: 420, height: 820))
        }
        let code = try await render(AskWorkflowAuthoringPanel(session: session, close: {}, initialTab: .code),
                                    name: "panel-code-light", dark: false, size: .init(width: 420, height: 820))
        for expected in [chinese("ask.workflow.chat.files"), chinese("ask.workflow.chat.openEditor"), "workflow.json"] {
            #expect(readable(code).contains(readable(expected)), "Missing \(expected) in the code tab")
        }

        // A failing run says so, and the hint suggests fixing it before saving.
        var failing = try #require(session.draft.manifest)
        failing.command.inline = "print -u2 'no network'; exit 3"
        session.edit(text: String(decoding: try AskWorkflowStore.encode(failing), as: UTF8.self), path: "workflow.json")
        #expect(session.problems.isEmpty, "\(session.problems)")
        // Closed panels cancel the session's run from onDisappear; let those land first.
        try await Task.sleep(for: .milliseconds(300))
        let results = await session.testLatestProposal([.init(query: "杭州")])
        #expect(results?.first?.succeeded == false, "\(String(describing: session.message))")
        #expect(session.currentPreview?.result.succeeded == false)
        let failed = try await render(AskWorkflowAuthoringPanel(session: session, close: {}),
                                      name: "panel-failed-light", dark: false, size: .init(width: 420, height: 820))
        for expected in [chinese("ask.workflow.chat.resultFailed"), chinese("ask.workflow.chat.hint.testFailed")] {
            #expect(readable(failed).contains(readable(expected)), "Missing \(expected) after a failed run")
        }

        // While a run is under way the result area and the footer both say so.
        failing.command.inline = "sleep 3"
        session.edit(text: String(decoding: try AskWorkflowStore.encode(failing), as: UTF8.self), path: "workflow.json")
        try await Task.sleep(for: .milliseconds(300))
        let running = Task { await session.testLatestProposal([.init(query: "杭州")]) }
        try await chat.wait { session.isRunning }
        let busy = try await render(AskWorkflowAuthoringPanel(session: session, close: {}),
                                    name: "panel-running-light", dark: false, size: .init(width: 420, height: 820))
        for expected in [chinese("ask.workflow.chat.running"), chinese("ask.workflow.chat.hint.running")] {
            #expect(readable(busy).contains(readable(expected)), "Missing \(expected) while running")
        }
        session.cancel()
        _ = await running.value

        let ready = try await render(AskWorkflowAuthoringCard(session: session, selected: true, open: {}).padding(20),
                                     name: "card-ready-light", dark: false, size: .init(width: 760, height: 110))
        for expected in [chinese("ask.workflow.chat.status.unsaved"), chinese("ask.workflow.chat.openedBeside")] {
            #expect(readable(ready).contains(readable(expected)), "Missing \(expected) on the ready card")
        }
        try session.save()
        let saved = try await render(AskWorkflowAuthoringCard(session: session, selected: false, open: {}).padding(20),
                                     name: "card-saved-light", dark: false, size: .init(width: 760, height: 110))
        #expect(readable(saved).contains(readable(chinese("ask.workflow.chat.saved"))))
    }
}
