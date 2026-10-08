import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask harness UI")
@MainActor
struct AskHarnessUITests {
    private let now = Date()

    private func call(_ id: String, _ name: String, _ args: [String: Any] = [:]) -> AskToolCall {
        let data = try! JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
        return AskToolCall(id: id, function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func step(_ id: String, _ calls: [AskToolCall], text: String = "", runId: String? = nil) -> AskMessage {
        AskMessage(id: id, role: "assistant", text: text, toolCalls: calls, createdAt: now, runId: runId)
    }

    private func result(_ callId: String, image: String? = nil, error: Bool = false) -> AskMessage {
        AskMessage(id: "t-" + callId, role: "tool", text: "ok", image: image, toolCallId: callId, isError: error, createdAt: now)
    }

    private func fits<V: View>(_ view: V, width: CGFloat = 640) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private let image = "data:image/png;base64," + (NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .representation(using: .png, properties: [:])!.base64EncodedString())

    // MARK: - Grouping

    @Test func consecutiveToolStepsBecomeOneBlockWithOutputsUnderTheAnswer() {
        let plan = call("p", "update_plan", ["items": [["step": "Search", "status": "completed"]]])
        let fetch = call("f", "web_fetch", ["url": "https://typeflux.app/changelog"])
        let again = call("f2", "web_fetch", ["url": "https://typeflux.app/changelog"])
        let code = call("c", "run_code", ["language": "python", "code": "1"])
        let shot = call("s", "computer", ["action": "screenshot"])
        let messages = [
            AskMessage(id: "u", role: "user", text: "Q", createdAt: now),
            step("a1", [plan], text: "Planning"), step("a2", [fetch, again]), step("a3", [code, shot]),
            AskMessage(id: "answer", role: "assistant", text: "Done", createdAt: now)
        ]
        let results = [result("p"), result("f"), result("f2"), result("c", image: image), result("s", image: image)]
        let items = AskActivity.items(messages, results: results)
        #expect(items.map(\.id) == ["u", "a1", "answer"])
        guard case let .activity(group) = items[1].kind else { Issue.record("expected a block"); return }
        #expect(group.messageIds == ["a1", "a2", "a3"])
        #expect(group.steps.map(\.id) == ["f", "f2", "c", "s"])
        #expect(items[1].outputs.isEmpty)
        // Pages are deduplicated and screen captures are not results.
        #expect(items[2].outputs.sources == [URL(string: "https://typeflux.app/changelog")!])
        #expect(items[2].outputs.artifacts.map(\.id) == ["c"])
    }

    @Test func aBlockWithoutAnAnswerKeepsItsOutputsAndUserTurnsSplitBlocks() {
        let code = call("c", "run_code")
        let failed = call("x", "run_code")
        let messages = [step("a1", [code, failed]), AskMessage(id: "u2", role: "user", text: "next", createdAt: now), step("a2", [call("k", "skill")])]
        let items = AskActivity.items(messages, results: [result("c", image: image), result("x", image: image, error: true)])
        #expect(items.map(\.id) == ["a1", "u2", "a2"])
        #expect(items[0].outputs.artifacts.map(\.id) == ["c"])
        #expect(items[1].outputs.isEmpty)
    }

    @Test func outputsIgnoreNonWebURLs() {
        let group = AskActivityGroup(id: "a", messages: [step("a", [call("f", "web_fetch", ["url": "file:///etc/passwd"]),
                                                                    call("g", "web_fetch", ["url": 3])])])
        #expect(AskActivity.outputs(group, results: []).sources.isEmpty)
    }

    @Test func blockStatusFollowsApprovalLiveStreamingAndResults() {
        let group = AskActivityGroup(id: "a", messages: [step("a", [call("c", "run_code"), call("d", "files", ["action": "read"])])])
        let done = [result("c"), result("d")]
        #expect(AskActivity.status(group, results: done, streamingId: nil, approvalToolId: "d") == .attention)
        #expect(AskActivity.status(group, results: done, streamingId: nil, approvalToolId: nil, live: true) == .running)
        #expect(AskActivity.status(group, results: done, streamingId: "a", approvalToolId: nil) == .running)
        #expect(AskActivity.status(group, results: [result("c")], streamingId: nil, approvalToolId: nil) == .running)
        #expect(AskActivity.status(group, results: [result("c"), result("d", error: true)], streamingId: nil, approvalToolId: nil) == .failed)
        #expect(AskActivity.status(group, results: done, streamingId: nil, approvalToolId: "other") == .done)
    }

    @Test func titlesSayWhatTheBlockDid() {
        let plan = [AskPlanItem(step: "A", status: "completed"), AskPlanItem(step: "B", status: "pending")]
        let group = AskActivityGroup(id: "a", messages: [step("a", [call("p", "update_plan"), call("s", "web_search"),
                                                                    call("r", "research"), call("f", "files"), call("m", "mcp_x")])])
        let results = [result("s"), result("r"), result("f", error: true), result("m")]
        let summary = AskActivity.categorySummary(group.calls)
        // The step under way names the line while working.
        #expect(AskActivity.title(group, status: .running, plan: nil, results: results) == AskTheme.toolTitle(group.steps[3]))
        #expect(AskActivity.title(group, status: .attention, plan: nil, results: results) == L("ask.activity.attention"))
        #expect(AskActivity.title(group, status: .failed, plan: plan, results: results)
            == L("ask.activity.plan", 1, 2) + " · " + summary)
        #expect(AskActivity.title(group, status: .done, plan: [], results: [result("s")]) == summary)
        // "Other" never shows; such tools are named instead.
        #expect(summary == [L("ask.activity.kind.search") + " 2", L("ask.activity.kind.files") + " 1", "MCP"].joined(separator: " · "))
        #expect(!summary.contains(L("ask.activity.kind.other")))
        #expect(AskActivity.failures(group, results: results) == 1)
        #expect(AskActivity.failures(group, results: []) == 0)
        #expect(AskActivity.stepNote(group, status: .done) == L("ask.activity.steps", 4))
        #expect(AskActivity.stepNote(group, status: .running) == L("ask.activity.step", 4))
        #expect(AskActivity.stepNote(group, status: .attention) == nil)
        #expect(AskActivity.symbol(group) == AskPresentation.toolSymbol(group.steps[0]))
    }

    @Test func aSingleStepIsNamedByItsTool() {
        let list = call("m", "memory", ["action": "list"])
        let group = AskActivityGroup(id: "a", messages: [step("a", [list])])
        let title = AskActivity.title(group, status: .done, plan: nil, results: [result("m")])
        #expect(title == AskTheme.toolTitle(list))
        #expect(title.hasPrefix(L("ask.tool.memory")))
        #expect(AskActivity.stepNote(group, status: .done) == nil)
        #expect(AskActivity.stepNote(group, status: .running) == L("ask.activity.step", 1))
        #expect(AskActivity.symbol(group) == "brain")
        // A plan keeps its count in front, with the step summarized after it.
        let planned = AskActivity.title(group, status: .done, plan: [AskPlanItem(step: "A", status: "completed")], results: [])
        #expect(planned == L("ask.activity.plan", 1, 1) + " · " + L("ask.tool.memory"))
        // Repeated unnamed tools carry a count; the category ones keep their order.
        let two = AskActivityGroup(id: "b", messages: [step("b", [call("x", "memory"), call("y", "memory", ["action": "remember"]),
                                                                  call("z", "web_fetch", ["url": "https://a.b"])])])
        #expect(AskActivity.categorySummary(two.calls) == L("ask.activity.kind.web") + " 1 · " + L("ask.tool.memory") + " 2")
    }

    @Test func aBlockStillPlanningHasAFallbackTitleAndGlyph() {
        let planning = AskActivityGroup(id: "a", messages: [step("a", [call("p", "update_plan")])])
        #expect(AskActivity.title(planning, status: .running, plan: nil, results: []) == L("ask.activity.working"))
        #expect(AskActivity.title(planning, status: .done, plan: nil, results: []) == L("ask.tool.update_plan"))
        #expect(AskActivity.stepNote(planning, status: .running) == nil)
        #expect(AskActivity.symbol(planning) == "list.bullet.clipboard")
        #expect(AskToolStepRow.showsStatus(.failed) && AskToolStepRow.showsStatus(.attention) && AskToolStepRow.showsStatus(.running))
        #expect(!AskToolStepRow.showsStatus(.done))
    }

    @Test func activityCategoriesFollowTheirTools() {
        #expect(AskActivity.Category.of("browser") == .web)
        #expect(AskActivity.Category.of("computer") == .computer)
        #expect(AskActivity.Category.of("run_code") == .code)
    }

    @Test func blockPlanPrefersTheLiveRunPlanForTheLatestBlock() {
        let recorded = call("p", "update_plan", ["items": [["step": "Old", "status": "completed"]]])
        let group = AskActivityGroup(id: "a", messages: [step("a", [recorded], runId: "run")])
        var run = AskRun(id: "run", deviceId: "d", status: "completed", steps: 2, updatedAt: now, tools: [], pending: [])
        run.plan = [AskPlanItem(step: "New", status: "in_progress")]
        #expect(AskActivity.plan(for: group, run: run, isLatest: true)?.first?.step == "New")
        #expect(AskActivity.plan(for: group, run: run, isLatest: false)?.first?.step == "Old")
        var other = run
        other.id = "other"
        #expect(AskActivity.plan(for: group, run: other, isLatest: true)?.first?.step == "Old")
        let plain = AskActivityGroup(id: "b", messages: [step("b", [call("s", "web_search")])])
        #expect(AskActivity.plan(for: plain, run: nil, isLatest: true) == nil)
        let broken = AskActivityGroup(id: "c", messages: [step("c", [call("p", "update_plan", ["items": []])])])
        #expect(AskActivity.plan(for: broken, run: nil, isLatest: false) == nil)
    }

    @Test func runSummaryCoversEveryState() {
        func summary(_ run: AskRun?, pendingApproval: Bool = false) -> String? {
            AskRunPhase.resolve(run: run, busy: false, pendingApproval: pendingApproval,
                                recovery: .init(run: run, entries: [], deviceId: "d", local: false))?.summary
        }
        var run = AskRun(id: "r", deviceId: "d", status: "running", steps: 0, updatedAt: now, tools: [], pending: [])
        #expect(summary(nil) == nil)
        #expect(summary(run, pendingApproval: true) == L("ask.run.attention"))
        #expect(summary(run) == L("ask.run.running", 1))
        run.status = "completed"; run.steps = 9
        #expect(summary(run) == L("ask.run.completed", 9))
        run.status = "failed"
        #expect(summary(run) == L("ask.run.failed"))
        run.status = "cancelled"
        #expect(summary(run) == L("ask.run.cancelled"))
        // A state this build does not know blocks execution: it waits for the user.
        run.status = "unknown"
        #expect(summary(run) == L("ask.run.needsDecision"))
    }

    // MARK: - Titles and status

    @Test func toolTitlesNeverShowRawNames() {
        #expect(AskTheme.toolTitle(call("p", "update_plan")) == L("ask.tool.update_plan"))
        #expect(AskTheme.toolTitle(call("r", "research", ["question": "Why"])) == L("ask.tool.research") + " · Why")
        #expect(AskTheme.toolTitle(call("r", "research")) == L("ask.tool.research"))
        #expect(AskTheme.toolTitle(call("f", "files", ["action": "search", "query": "release"])) == L("ask.files.action.search") + " · release")
        #expect(AskTheme.toolTitle(call("f", "files", ["action": "list", "path": ""])) == L("ask.files.action.list"))
        #expect(AskTheme.toolTitle(call("f", "files", ["action": "zip"])) == L("ask.tool.files"))
        #expect(AskTheme.toolTitle(call("m", "mcp_delete_issue")) == "MCP · delete_issue")
        #expect(AskTheme.toolTitle(call("m", "mcp_delete_issue"), mcpServer: "Linear") == "Linear · delete_issue")
        #expect(AskTheme.toolTitle(call("b", "browser", ["action": "read"])) == L("ask.tool.browser") + " · " + L("ask.action.read"))
        #expect(AskTheme.toolTitle(call("x", "custom")) == "custom")
        #expect(AskPresentation.toolSymbol(call("m", "mcp_delete_issue")) == "point.3.connected.trianglepath.dotted")
    }

    @Test func imageStatusDependsOnTheTool() {
        let withImage = result("c", image: image)
        #expect(AskPresentation.toolStatusText(result: withImage, call: call("c", "run_code")) == L("ask.image.generated"))
        #expect(AskPresentation.toolStatusText(result: withImage, call: call("c", "computer")) == L("ask.image.captured"))
        #expect(AskPresentation.toolStatusText(result: withImage) == L("ask.image.captured"))
        #expect(AskPresentation.toolStatusText(result: result("c"), call: call("c", "run_code")) == L("ask.tool.done"))
    }

    // MARK: - Approvals

    @Test func approvalPreviewsShowWhatWillChange() {
        #expect(AskApprovalPresentation.preview(call("w", "files", ["action": "edit", "path": "/a", "old_text": "# A", "new_text": "# B"]))
            == .diff(removed: "# A", added: "# B"))
        #expect(AskApprovalPresentation.preview(call("w", "files", ["action": "write", "content": "hello"])) == .content("hello"))
        #expect(AskApprovalPresentation.preview(call("w", "files", ["action": "write"])) == .none)
        #expect(AskApprovalPresentation.preview(call("c", "run_code", ["code": "print(1)"])) == .content("print(1)"))
        #expect(AskApprovalPresentation.preview(call("t", "computer", ["action": "type", "text": "hi"])) == .content("hi"))
        #expect(AskApprovalPresentation.preview(call("t", "browser", ["action": "fill", "text": "x"])) == .content("x"))
        #expect(AskApprovalPresentation.preview(call("m", "memory", ["action": "remember", "text": "likes tea"])) == .content("likes tea"))
        #expect(AskApprovalPresentation.preview(call("d", "mcp_delete", ["id": "1"])) == .content("{\"id\":\"1\"}"))
        #expect(AskApprovalPresentation.detail(call("w", "files", ["path": "~/a/b.md"])) == "~/a/b.md")
        #expect(AskApprovalPresentation.detail(call("w", "run_code", ["path": "x"])) == nil)
        #expect(AskApprovalPresentation.clip(String(repeating: "a", count: 10), limit: 4) == "aaaa\n…")
        #expect(AskApprovalPresentation.clip("abc") == "abc")
        #expect(AskApprovalPresentation.riskLabel(.read) == L("ask.approval.risk.read"))
        #expect(AskApprovalPresentation.riskLabel(.none) == L("ask.approval.risk.read"))
        #expect(AskApprovalPresentation.riskLabel(.write) == L("ask.approval.risk.write"))
        #expect(AskApprovalPresentation.riskLabel(.destructive) == L("ask.approval.risk.destructive"))
        #expect(AskApprovalPresentation.riskState(.destructive) == .failed)
        #expect(AskApprovalPresentation.riskState(.write) == .attention)
        #expect(AskApprovalPresentation.riskState(.read) == .running)
    }

    @Test func approvalCardsRenderForEveryRisk() {
        let edit = call("w", "files", ["action": "edit", "path": "~/a.md", "old_text": "# A\nline", "new_text": "# B"])
        var denied = false, allowed = false, granted = false
        let card = AskApprovalCard(call: edit, risk: .write, canAllowForConversation: true,
                                   onDeny: { denied = true }, onAllowForConversation: { granted = true }, onAllow: { allowed = true })
        #expect(fits(card) > 80)
        card.onDeny(); card.onAllow(); card.onAllowForConversation()
        #expect(denied && allowed && granted)
        #expect(fits(AskApprovalCard(call: call("d", "mcp_delete_issue", ["id": "1"]), risk: .destructive, mcpServer: "Linear",
                                     onDeny: {}, onAllow: {})) > 60)
        #expect(fits(AskApprovalCard(call: call("c", "run_code", ["code": "1"]), risk: .read, onDeny: {}, onAllow: {})) > 60)
    }

    // MARK: - Views

    @Test func activityBlocksRenderInEveryState() {
        let calls = [call("p", "update_plan", ["items": [["step": "A", "status": "in_progress"]]]), call("c", "run_code"), call("s", "web_search")]
        var reasoning = step("a", calls, text: "Looking it up")
        reasoning.reasoning = "Thinking"
        let group = AskActivityGroup(id: "a", messages: [reasoning])
        let results = [result("p"), result("c", image: image), result("s", error: true)]
        let plan = [AskPlanItem(step: "A", status: "in_progress"), AskPlanItem(step: "B", status: "completed")]
        var outputs = AskRunOutputs()
        outputs.artifacts = [.init(id: "c", image: image, toolName: "run_code")]
        outputs.sources = (1 ... 8).map { URL(string: "https://example.com/\($0)")! }
        let collapsed = fits(AskActivityBlock(group: group, results: results, plan: plan, status: .done))
        // Working stays one folded line too; the line names the step under way.
        let running = fits(AskActivityBlock(group: group, results: results, plan: plan, status: .running, streamingId: "a"))
        #expect(running == collapsed)
        let plain = fits(AskActivityBlock(group: AskActivityGroup(id: "b", messages: [step("b", [calls[1]])]),
                                          results: results, plan: nil, status: .done))
        #expect(plain <= AskActivityBlock.lineHeight + 1)
        #expect(fits(AskActivityBlock(group: group, results: results, plan: plan, status: .done, startsExpanded: true)) > collapsed)
        #expect(fits(AskActivityBlock(group: group, results: results, plan: plan, status: .attention, startsExpanded: false))
            < fits(AskActivityBlock(group: group, results: results, plan: plan, status: .attention)))
        #expect(fits(AskActivityBlock(group: group, results: results, plan: nil, status: .attention, approvalToolId: "c")) > collapsed)
        #expect(fits(AskActivityBlock(group: group, results: results, plan: nil, status: .failed, outputs: outputs)) > collapsed)
        #expect(fits(AskToolStepRow(call: calls[1], result: results[1])) > 10)
        #expect(fits(AskToolStepRow(call: calls[2], result: nil, preparing: true)) > 10)
        #expect(fits(AskToolStepRow(call: calls[2], result: nil, pending: true)) > 10)
        #expect(fits(AskRunOutputsView(outputs: outputs)) > 40)
    }

    @Test func artifactsCopyAsImagesAndEncodeAsPNG() throws {
        let picture = try #require(AskImage.decode(image))
        let pasteboard = NSPasteboard(name: .init("ask-artifact-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        AskArtifactActions.copy(picture, pasteboard: pasteboard)
        #expect(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
        let png = try #require(AskArtifactActions.pngData(picture))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    // MARK: - Model

    @Test func modelReportsApprovalRiskAndLocalGaps() async throws {
        let cloud = try AskTestFixture()
        #expect(cloud.model.approvalRisk("missing") == nil)
        #expect(cloud.model.mcpServerName(of: call("m", "mcp_x")) == nil)
        await cloud.api.setTool(call("w", "danger_delete", [:]))
        await cloud.api.seed(.init(id: "c", title: "C", revision: 1, updatedAt: now, messages: []))
        await cloud.model.refreshHistory()
        await cloud.model.select("c")
        cloud.model.draft.text = "delete it"
        cloud.model.submitDraft()
        try await cloud.wait { !cloud.model.pendingApprovals.isEmpty }
        let id = try #require(cloud.model.pendingApprovals.keys.first)
        #expect(cloud.model.approvalRisk(id) == .destructive)
        #expect(!cloud.model.canAllowForConversation(id))
        cloud.model.approve(conversationId: id, allowed: false)
        try await cloud.wait { cloud.model.busyIds.isEmpty }

        let local = try AskTestFixture(authenticated: false)
        let search = AskSearchSettings(defaults: local.model.modelLibrary.settings.defaults)
        let previous = search.provider
        defer { search.provider = previous }
        search.provider = .none
        #expect(!AskLocalModeStatus.make(model: local.model, signedIn: false).searchConfigured)
        search.provider = .brave
        #expect(AskLocalModeStatus.make(model: local.model, signedIn: false).searchConfigured)
    }

    // MARK: - Settings and skills

    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "ask-harness-ui-\(UUID().uuidString)")!)
    }

    @Test func settingsTabsRenderAndPersistSkillChoices() throws {
        let settings = store()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-harness-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = AskMemoryNoteStore(fileURL: root.appendingPathComponent("notes.json"))
        _ = try notes.add("Prefers short answers", owner: "o")
        for tab in AgentSettingsPane.allCases where tab != .mcpServers {
            for localMode in [true, false] {
                settings.askNewConversationsStayLocal = localMode
                let view = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: root), notes: notes,
                                                owner: { "o" }, pane: tab)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let hosting = NSHostingView(rootView: view)
                window.contentView = hosting
                window.layoutIfNeeded()
                window.displayIfNeeded()
                // The code execution pane now contains only its header and switch.
                let minimumHeight: CGFloat = tab == .codeExecution ? 40 : 60
                #expect(hosting.fittingSize.height >= minimumHeight)
                window.close()
            }
        }
        let view = AskToolsSettingsView(settings: settings, skills: AskSkillLibrary(userDirectory: root), notes: notes, owner: { "o" })
        view.setSkill("email-reply", enabled: false)
        view.setSkill("meeting-notes", enabled: false)
        view.setSkill("meeting-notes", enabled: true)
        #expect(settings.askDisabledSkills == ["email-reply"])
    }

    @Test func builtinSkillsDescribeThemselvesInTheInterfaceLanguage() throws {
        let builtin = try #require(AskBuiltinSkills.all.first { $0.name == "data-analysis" })
        #expect(builtin.displayDescription == L("ask.skill.data-analysis.description"))
        var custom = builtin
        custom.directory = URL(fileURLWithPath: "/tmp/skill")
        #expect(custom.displayDescription == builtin.description)
        let unknown = AskSkill(name: "mine", description: "Mine", body: "x")
        #expect(unknown.displayDescription == "Mine")
    }

    @Test func disabledSkillsAreNotOfferedOrLoaded() async throws {
        let settings = store()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-harness-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "ask-harness-mcp-\(UUID().uuidString)")!))
        let tools = AskLocalTools(registry: registry, settings: settings, skills: AskSkillLibrary(userDirectory: root),
                                  notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("n.json")), owner: { "o" })
        settings.askDisabledSkills = ["email-reply"]
        #expect(!tools.enabledSkills.contains { $0.name == "email-reply" })
        let definitions = await tools.definitions(conversationId: nil)
        let skill = try #require(definitions.first { $0.name == "skill" })
        #expect(!skill.description.contains("email-reply"))
        await #expect(throws: (any Error).self) {
            _ = try await tools.execute(call("k", "skill", ["name": "email-reply"]), conversationId: "c")
        }
        let loaded = try await tools.execute(call("k", "skill", ["name": "data-analysis"]), conversationId: "c")
        #expect(loaded.content.contains("data-analysis"))
        #expect(tools.mcpServerName(of: call("k", "skill")) == nil)
    }
}
