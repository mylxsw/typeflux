import AppKit
import SwiftUI
import SQLite3
import Testing
@testable import Typeflux

actor AskTestAPI: AskAPI {
    var usageRecords: [AskUsageInvocation] = []
    func setUsageRecords(_ value: [AskUsageInvocation]) { usageRecords = value }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        AskUsagePage(items: usageRecords.filter { runId == nil || $0.runId == runId }, nextCursor: nil)
    }

    var values: [String: AskConversation] = [:]
    var sends: [AskSendRequest] = []
    var retryModels: [String?] = []
    var results: [AskToolResultRequest] = []
    var inferenceResults: [AskInferenceResult] = []
    var nextTool: AskToolCall?
    var failSend = false
    var failList = false
    var failModels = false
    var cloudModels: [AskCloudModel] = [.init(id: "default", name: "Typeflux Cloud")]
    func setCloudModels(_ values: [AskCloudModel]) { cloudModels = values }
    func setFailModels(_ value: Bool) { failModels = value }
    func models(token: String) async throws -> [AskCloudModel] {
        if failModels { throw AskLocalError.message("Offline") }
        return cloudModels
    }
    var listed: [AskConversationSummary]?
    var held: Set<String> = []
    var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    var failGets: Set<String> = []
    func hold(_ id: String) { held.insert(id) }
    func release(_ id: String) {
        held.remove(id)
        waiting.removeValue(forKey: id)?.forEach { $0.resume() }
    }
    func setListed(_ items: [AskConversationSummary]?) { listed = items }
    func failGet(_ id: String) { failGets.insert(id) }

    func setTool(_ call: AskToolCall?) { nextTool = call }
    /// Calls the model makes after each tool result, in order.
    var followUpTools: [AskToolCall] = []
    func queueFollowUpTools(_ calls: [AskToolCall]) { followUpTools = calls }
    func setFailSend(_ flag: Bool) { failSend = flag }
    func setFailList(_ flag: Bool) { failList = flag }
    func seed(_ value: AskConversation) { values[value.id] = value }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] {
        if failList { throw AskLocalError.message("Network unavailable") }
        if let listed { return Array(listed.dropFirst(offset).prefix(50)) }
        return values.values.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(offset).map { .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }
    func conversation(id: String, token: String) async throws -> AskConversation {
        if failGets.contains(id) { throw AskLocalError.message("Offline") }
        guard let value = values[id] else { throw AskLocalError.message("Not found") }
        if held.contains(id) { await withCheckedContinuation { waiting[id, default: []].append($0) } }
        return value
    }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        if failSend { throw AskLocalError.message("Network unavailable") }
        sends.append(request)
        var value = values[conversationId] ?? AskConversation(id: conversationId, title: request.text, revision: 0, updatedAt: Date(), messages: [])
        if value.messages.contains(where: { $0.id == request.id }) { return value }
        value.messages.append(.init(id: request.id, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date(), references: request.references))
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: nextTool == nil ? "This is the answer." : "I can inspect the current page.", toolCalls: nextTool.map { [$0] }, createdAt: Date()))
        value.run = .init(id: UUID().uuidString, deviceId: request.deviceId, status: nextTool == nil ? "completed" : "waiting_tool", steps: 1, updatedAt: Date(), tools: request.tools, pending: nextTool.map { [$0] } ?? [])
        value.modelRef = request.modelRef
        if value.messages.count == 2 { value.memory = request.memory }
        // Mirrors the server: the latest question decides, and only pinned memory can be off.
        value.memoryOff = value.memory != nil && request.memoryOff == true ? true : nil
        value.revision += 1; values[conversationId] = value
        return value
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        results.append(request)
        var value = try await conversation(id: conversationId, token: token)
        value.messages.append(.init(id: UUID().uuidString, role: "tool", text: request.content, toolCallId: request.toolCallId, isError: request.isError, createdAt: Date()))
        if !followUpTools.isEmpty {
            let next = followUpTools.removeFirst()
            value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: "", toolCalls: [next], createdAt: Date()))
            value.run?.pending = [next]; value.revision += 1; values[conversationId] = value
            return value
        }
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: request.isError ? "I will continue without that tool." : "Here is the summary.", createdAt: Date()))
        value.run?.status = "completed"; value.run?.pending = []; value.revision += 1; values[conversationId] = value
        return value
    }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        inferenceResults.append(request)
        var value = try await conversation(id: conversationId, token: token)
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: request.content, toolCalls: request.toolCalls, createdAt: Date()))
        value.run?.status = request.failed ? "failed" : "completed"
        value.run?.inference = nil
        value.revision += 1
        values[conversationId] = value
        return value
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        var value = try await conversation(id: conversationId, token: token)
        value.run?.status = "cancelled"; value.run?.pending = []; value.revision += 1; values[conversationId] = value
        return value
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        var value = try await conversation(id: conversationId, token: token)
        retryModels.append(modelRef)
        value.modelRef = modelRef ?? value.modelRef
        value.run?.modelRef = value.modelRef
        value.run?.status = "completed"; value.revision += 1; values[conversationId] = value
        return value
    }
    var regenerations: [AskRegenerateRequest] = []
    var failRegenerate = false
    func setFailRegenerate(_ flag: Bool) { failRegenerate = flag }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        if failRegenerate { throw AskLocalError.message("Network unavailable") }
        regenerations.append(request)
        var value = try await conversation(id: conversationId, token: token)
        // Mirror the server: rewind the whole turn that produced the target
        // answer, then answer the same question again.
        guard let index = value.messages.firstIndex(where: { $0.id == request.messageId }) else {
            throw AskLocalError.message("Not found")
        }
        var cut = index
        while cut > 0, value.messages[cut - 1].role != "user" { cut -= 1 }
        value.messages = Array(value.messages.prefix(cut))
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: "This is another answer.", createdAt: Date()))
        value.modelRef = request.modelRef ?? value.modelRef
        value.run = .init(id: UUID().uuidString, deviceId: request.deviceId, status: "completed", steps: 1,
                          updatedAt: Date(), tools: request.tools ?? [], pending: [])
        value.run?.modelRef = value.modelRef
        value.revision += 1; values[conversationId] = value
        return value
    }
    var steers: [AskSteerRequest] = []
    var deliverSteers = false
    var failSteer = false
    func setDeliverSteers(_ flag: Bool) { deliverSteers = flag }
    func setFailSteer(_ flag: Bool) { failSteer = flag }
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        if failSteer { throw AskLocalError.message("Conflict") }
        steers.append(request)
        var value = try await conversation(id: conversationId, token: token)
        if deliverSteers {
            value.messages.append(.init(id: request.id, role: "user", text: request.text, createdAt: Date(), runId: request.runId, steered: true))
            value.revision += 1; values[conversationId] = value
        }
        return value
    }
    func delete(conversationId: String, token: String) async throws { values[conversationId] = nil }
    var purgeTokens: [String] = []
    var failPurge = false
    func setFailPurge(_ flag: Bool) { failPurge = flag }
    func purgeMemory(token: String) async throws {
        if failPurge { throw AskLocalError.message("Offline") }
        purgeTokens.append(token)
        for (id, value) in values where value.memory != nil {
            values[id]?.memory = nil
            values[id]?.revision += 1
        }
    }
}

@MainActor
final class AskTestTools: AskToolExecuting {
    var executions = 0
    var fail = false
    var reportsError = false
    var bound: [String] = []
    func bindConversation(_ id: String) { bound.append(id) }
    var definitionRequests: [String?] = []
    func risk(of call: AskToolCall) -> AskToolRisk {
        call.function.name.hasPrefix("danger") ? .destructive : AskLocalTools.builtinRisk(call)
    }
    func definitions(conversationId: String?) async -> [AskToolDefinition] {
        definitionRequests.append(conversationId)
        return AskLocalTools.builtins
    }
    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        executions += 1
        if fail { throw AskLocalError.message("Tool unavailable") }
        return .init(content: "Observed source", isError: reportsError)
    }
}

@MainActor
final class AskTestCapture: AskContextCapturing {
    var calls = 0
    var selectionRequests: [Bool] = []
    var warning: String?
    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        calls += 1
        selectionRequests.append(includeSelection)
        return .init(selection: includeSelection ? "Selected words" : nil, source: "Safari", screenshot: includeScreenshot ? "data:image/jpeg;base64,YQ==" : nil, warning: warning)
    }
}

@MainActor
struct AskTestFixture {
    let root: URL
    let cache: AskConversationCache
    let api = AskTestAPI()
    let tools = AskTestTools()
    let capture = AskTestCapture()
    let model: AskConversationModel
    init(authenticated: Bool = true, modelLibrary: AskModelLibrary? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-tests-" + UUID().uuidString)
        cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        model = AskConversationModel(api: api, cache: cache, tools: tools, capture: capture,
                                     deviceId: "device", modelLibrary: modelLibrary ?? AskModelLibrary(defaults: UserDefaults(suiteName: "ask-library-test-" + UUID().uuidString)!, automaticallyLoadsCatalog: false), session: { authenticated ? ("owner", "token") : nil })
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for conversation state")
    }
}

@Suite("Ask conversations")
@MainActor
struct AskConversationTests {
    @Test func pullRefreshKeepsSelectionDraftAndReadingPositionOnFailure() async throws {
        let f = try AskTestFixture()
        await f.api.seed(.init(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: []))
        await f.model.refreshHistory()
        await f.model.select("a")
        f.model.draft.text = "unfinished"
        f.model.transcriptPositions["a"] = "message-8"
        await f.api.setFailList(true)
        await f.model.pullToRefreshHistory()
        #expect(f.model.historyRefreshError != nil)
        #expect(f.model.error == nil)
        #expect(f.model.selectedId == "a")
        #expect(f.model.conversations.count == 1)
        #expect(f.model.draft.text == "unfinished")
        #expect(f.model.transcriptPositions["a"] == "message-8")
        #expect(!f.model.isRefreshingHistory)
        await f.api.setFailList(false)
        await f.model.pullToRefreshHistory()
        #expect(f.model.historyRefreshError == nil)
        #expect(f.model.selectedId == "a")
        f.model.resetSession()
    }

    @Test func screenshotDefaultsAndRemovedAttachmentsAreRespected() {
        var draft = AskDraft(text: "  question  ", screenshot: "image", selection: "selection")
        #expect(draft.includeScreenshot)
        #expect(!AskDraft.followUp.includeScreenshot)
        #expect(draft.request(deviceId: "device", tools: []).image == "image")
        draft.includeScreenshot = false; draft.selection = nil
        let request = draft.request(deviceId: "device", tools: [])
        #expect(request.text == "question"); #expect(request.image == nil); #expect(request.selection == nil)
        #expect(!AskDraft(text: " \n ").canSend)
    }

    @Test func draftCaptureSendAndFollowUpUseSameConversation() async throws {
        let f = try AskTestFixture()
        await f.model.prepareLauncher()
        #expect(f.capture.calls == 1); #expect(f.model.launcherDraft.selection == "Selected words")
        f.model.launcherDraft.text = "First question"
        await f.model.prepareLauncher()
        #expect(f.capture.calls == 1)
        var shown = 0; f.model.onShowConversation = { shown += 1 }
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        let id = try #require(f.model.selected?.id)
        #expect(shown == 1); #expect(f.model.selected?.messages.count == 2)
        #expect(f.model.launcherDraft.text.isEmpty); #expect(!f.model.draft.includeScreenshot)
        f.model.draft.text = "Follow up"
        f.model.submitDraft(); try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.selected?.id == id); #expect(f.model.selected?.messages.count == 4)
        let sends = await f.api.sends
        #expect(sends.count == 2); #expect(sends[0].image != nil); #expect(sends[1].image == nil)
        #expect(try await f.cache.load(id: id, owner: "owner")?.messages.count == 4)
        #expect(f.tools.bound == [id])
    }

    @Test func authenticationAndRecordingDoNotSendOrLoseDraft() async throws {
        let f = try AskTestFixture(authenticated: false)
        f.model.launcherDraft.text = "Keep this"
        f.model.submitLauncher()
        #expect(f.model.error != nil); #expect(f.model.launcherDraft.text == "Keep this")
        #expect(await f.api.sends.isEmpty)
        f.model.recordingIsActive = { true }
        #expect(!f.model.canSendLauncher)
        f.model.submitLauncher(); #expect(await f.api.sends.isEmpty)
    }

    @Test(arguments: [true, false])
    func toolRequiresApprovalAndKeepsResults(allow: Bool) async throws {
        let f = try AskTestFixture()
        let call = AskToolCall(id: "tool-1", type: "function", function: .init(name: "browser", arguments: "{\"action\":\"read\"}"))
        await f.api.setTool(call)
        f.model.launcherDraft.text = "Read page"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        let id = try #require(f.model.selected?.id)
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: id, allowed: allow)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == (allow ? 1 : 0))
        #expect(await f.api.results.first?.isError == !allow)
        #expect(f.model.selected?.run?.status == "completed")
        #expect(f.model.pendingApprovals.isEmpty)
    }

    @Test func stopWhileAwaitingApprovalNeverRunsTool() async throws {
        let f = try AskTestFixture()
        await f.api.setTool(.init(id: "tool", type: "function", function: .init(name: "computer", arguments: "{}")))
        f.model.launcherDraft.text = "Do something"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        f.model.stop()
        try await f.wait { f.model.selected?.run?.status == "cancelled" && f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: f.model.selected!.id, allowed: true)
        #expect(f.tools.executions == 0)
    }

    @Test func failedToolIsVisibleAndConversationCanContinue() async throws {
        let f = try AskTestFixture(); f.tools.fail = true
        await f.api.setTool(.init(id: "tool", type: "function", function: .init(name: "browser", arguments: "{}")))
        f.model.launcherDraft.text = "Read"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        f.model.approve(conversationId: f.model.selected!.id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.results.first?.content == "Tool unavailable")
        #expect(await f.api.results.first?.isError == true)
        #expect(f.model.controllingConversationId == nil)
    }

    @Test func conversationGrantsCoverSameToolUpToGrantedRisk() async throws {
        let f = try AskTestFixture()
        func browser(_ id: String, _ action: String) -> AskToolCall {
            .init(id: id, type: "function", function: .init(name: "browser", arguments: "{\"action\":\"\(action)\"}"))
        }
        await f.api.setTool(browser("read-1", "read"))
        await f.api.queueFollowUpTools([browser("read-2", "read"), browser("fill-1", "fill"), browser("fill-2", "fill"),
                                        .init(id: "danger-1", type: "function", function: .init(name: "danger_delete", arguments: "{}"))])
        f.model.launcherDraft.text = "Fill the form"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        let id = try #require(f.model.selected?.id)
        #expect(f.model.canAllowForConversation(id))
        f.model.approveForConversation(id)

        // The second read runs without asking; the first write asks again.
        try await f.wait { f.model.pendingApprovals[id]?.id == "fill-1" }
        #expect(f.tools.executions == 2)
        #expect(f.model.isGranted(browser("x", "read"), conversationId: id))
        #expect(!f.model.isGranted(browser("x", "fill"), conversationId: id))
        f.model.approveForConversation(id)

        // The write grant covers the next write; destructive calls always ask and cannot be granted.
        try await f.wait { f.model.pendingApprovals[id]?.id == "danger-1" }
        #expect(f.tools.executions == 4)
        #expect(!f.model.canAllowForConversation(id))
        f.model.approveForConversation(id)
        #expect(f.model.pendingApprovals[id]?.id == "danger-1")
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 4)
        #expect(await f.api.results.map(\.isError) == [false, false, false, false, true])

        // Grants are scoped to the conversation and dropped on sign-out.
        #expect(!f.model.isGranted(browser("x", "read"), conversationId: "other"))
        f.model.resetSession()
        #expect(!f.model.isGranted(browser("x", "read"), conversationId: id))
        f.model.approveForConversation("missing")
    }

    @Test func loadingASkillNeedsNoApproval() async throws {
        let f = try AskTestFixture()
        await f.api.setTool(.init(id: "skill-1", type: "function", function: .init(name: "skill", arguments: #"{"name":"email-reply"}"#)))
        f.model.launcherDraft.text = "Reply to this email"; f.model.submitLauncher()
        try await f.wait { f.tools.executions == 1 && f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(await f.api.results.first?.isError == false)
    }

    @Test func toolReportedErrorIsNotSentAsSuccess() async throws {
        let f = try AskTestFixture(); f.tools.reportsError = true
        await f.api.setTool(.init(id: "tool", type: "function", function: .init(name: "mcp_search", arguments: "{}")))
        f.model.launcherDraft.text = "Search"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        f.model.approve(conversationId: f.model.selected!.id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 1)
        #expect(await f.api.results.first?.content == "Observed source")
        #expect(await f.api.results.first?.isError == true)
        // Tool definitions are requested for the conversation being sent.
        #expect(f.tools.definitionRequests.contains(f.model.selected?.id))
    }

    @Test func networkRetryReusesMessageIdentifier() async throws {
        let f = try AskTestFixture(); await f.api.setFailSend(true)
        f.model.launcherDraft.text = "Question"; f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        let messageId = try #require(f.model.selected?.messages.first?.id)
        #expect(f.model.error != nil)
        await f.api.setFailSend(false); f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.sends.first?.id == messageId)
        #expect(f.model.selected?.messages.count == 2)
    }

    @Test func historySelectionDeleteAndDraftPersistence() async throws {
        let f = try AskTestFixture()
        f.model.launcherDraft.text = "Saved question"; f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        let id = try #require(f.model.selected?.id)
        f.model.draft.text = "Unsent follow up"; f.model.persistDrafts()
        try await Task.sleep(for: .milliseconds(350))
        f.model.newConversation()
        await f.model.refreshHistory()
        #expect(f.model.conversations.count == 1)
        await f.model.select(id)
        #expect(f.model.draft.text == "Unsent follow up")
        await f.model.delete(id)
        #expect(f.model.selected == nil); #expect(f.model.conversations.isEmpty)
        #expect(try await f.cache.load(id: id, owner: "owner") == nil)
    }

    @Test func recapturePreservesTextAndSelectionAndLogoutClearsState() async throws {
        let f = try AskTestFixture(); await f.model.prepareLauncher()
        f.model.launcherDraft.text = "Do not discard"
        await f.model.refreshScreenshot(launcher: true)
        #expect(f.model.launcherDraft.text == "Do not discard")
        #expect(f.model.launcherDraft.selection == "Selected words")
        f.capture.warning = "Permission missing"
        await f.model.refreshScreenshot(launcher: false)
        #expect(f.model.captureWarning == "Permission missing")
        f.model.resetSession()
        #expect(f.model.launcherDraft.text.isEmpty); #expect(f.model.conversations.isEmpty)
        #expect(f.model.pendingApprovals.isEmpty)
    }

    @Test func cacheIsAccountScopedAndRejectsOlderSnapshots() async throws {
        let f = try AskTestFixture()
        let c = AskConversation(id: "conversation", title: "Private", revision: 5, updatedAt: Date(), messages: [])
        try await f.cache.save(c, owner: "one")
        #expect(try await f.cache.load(id: c.id, owner: "two") == nil)
        var stale = c; stale.revision = 4; stale.title = "Old"
        try await f.cache.save(stale, owner: "one")
        #expect(try await f.cache.load(id: c.id, owner: "one")?.title == "Private")
        try await f.cache.saveDraft(.init(text: "Private draft"), key: "launcher", owner: "one")
        #expect(try await f.cache.draft(key: "launcher", owner: "two") == nil)
        #expect(try await f.cache.claimTool(id: "run/call", owner: "one"))
        #expect(try await !f.cache.claimTool(id: "run/call", owner: "one"))
        let result = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "call", content: "done", isError: false)
        try await f.cache.saveToolResult(result, owner: "one")
        #expect(try await f.cache.toolResult(id: "run/call", owner: "one") == result)
        #expect(try await f.cache.toolResult(id: "run/call", owner: "two") == nil)
    }

    @Test func deletedConversationRemovesItsToolJournalOnly() async throws {
        let f = try AskTestFixture()
        for id in ["one", "two"] {
            try await f.cache.associateTool(id: id + "/call", conversationId: id, owner: "owner")
            _ = try await f.cache.claimTool(id: id + "/call", owner: "owner")
            try await f.cache.saveToolResult(.init(runId: id, deviceId: "device", toolCallId: "call", content: "private", isError: false), owner: "owner")
        }
        try await f.cache.delete(id: "one", owner: "owner")
        #expect(try await f.cache.toolResult(id: "one/call", owner: "owner") == nil)
        #expect(try await f.cache.toolResult(id: "two/call", owner: "owner")?.content == "private")
    }

    @Test func expiredApprovalCannotExecuteTool() async throws {
        let f = try AskTestFixture()
        await f.api.setTool(.init(id: "read", type: "function", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        f.model.launcherDraft.text = "Read page"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        var value = try #require(f.model.selected)
        value.run?.status = "cancelled"; value.run?.pending = []; value.revision += 1
        await f.api.seed(value)
        f.model.approve(conversationId: value.id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.isEmpty)
        #expect(f.model.selected?.run?.status == "cancelled")
    }

    @Test(arguments: [true, false]) func resumedToolNeverRepeatsJournaledExecution(hasResult: Bool) async throws {
        let f = try AskTestFixture()
        let call = AskToolCall(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        let c = AskConversation(id: "resumed", title: "Task", revision: 3, updatedAt: Date(), messages: [
            .init(id: "user", role: "user", text: "Read page", createdAt: Date()),
            .init(id: "assistant", role: "assistant", text: "", toolCalls: [call], createdAt: Date())
        ], run: .init(id: "run", deviceId: "device", status: "waiting_tool", steps: 1, updatedAt: Date(), tools: [], pending: [call]))
        await f.api.seed(c)
        _ = try await f.cache.claimTool(id: "run/call", owner: "owner")
        if hasResult {
            try await f.cache.saveToolResult(.init(runId: "run", deviceId: "device", toolCallId: "call", content: "Already executed", isError: false), owner: "owner")
        }
        await f.model.select(c.id); f.model.resume()
        if !hasResult {
            try await f.wait { !f.model.pendingApprovals.isEmpty }
            f.model.approve(conversationId: c.id, allowed: true)
        }
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        let results = await f.api.results
        #expect(results.count == 1)
        #expect(results.first?.isError == !hasResult)
        if hasResult { #expect(results.first?.content == "Already executed") }
        else { #expect(results.first?.content.contains("unknown") == true) }
    }

    @Test func oversizedInputStaysEditableWithoutNetworkRequest() async throws {
        let f = try AskTestFixture()
        f.model.launcherDraft.text = String(repeating: "中", count: 11000)
        f.model.submitLauncher()
        #expect(f.model.error != nil)
        #expect(f.model.selected == nil)
        #expect(!f.model.launcherDraft.text.isEmpty)
        #expect(await f.api.sends.isEmpty)
    }

    @Test func wireDatesAndToolSchemaRoundTrip() throws {
        let request = AskSendRequest(id: "message", deviceId: "device", text: "question", tools: AskLocalTools.builtins)
        let encoded = try AskCoding.encoder().encode(request)
        #expect(String(decoding: encoded, as: UTF8.self).contains("device_id"))
        let decoded = try AskCoding.decoder().decode(AskSendRequest.self, from: encoded)
        #expect(decoded.tools.map(\.name) == ["computer", "browser"])
        let wire = Data(#"{"id":"m","role":"assistant","text":"answer","created_at":"2026-09-28T10:00:00.123456789Z"}"#.utf8)
        #expect(try AskCoding.decoder().decode(AskMessage.self, from: wire).text == "answer")
        #expect(throws: (any Error).self) { try AskCoding.decoder().decode(AskMessage.self, from: Data(#"{"id":"m","role":"user","text":"x","created_at":"wrong"}"#.utf8)) }
    }

    @Test func localToolArgumentsAndScriptLiteralsRemainData() throws {
        #expect(try AskLocalTools.arguments(#"{"action":"read"}"#)["action"] as? String == "read")
        #expect(throws: (any Error).self) { try AskLocalTools.arguments("[]") }
        #expect(throws: (any Error).self) { try AskLocalTools.arguments("{}") }
        let input = "\"; do shell script \"not code\"\n\\"
        let literal = AskLocalTools.javascriptLiteral(input)
        #expect(try JSONDecoder().decode(String.self, from: Data(literal.utf8)) == input)
        #expect(AskLocalTools.appleScriptLiteral(input).contains("\\\""))
        #expect(!AskLocalTools.appleScriptLiteral(input).contains("\n"))
        #expect(AskImage.decode("invalid") == nil)
        #expect(AskImage.decode("data:image/jpeg;base64,invalid") == nil)
    }
}

@Suite("Ask navigation regressions")
@MainActor
struct AskNavigationTests {
    private func conversation(_ id: String) -> AskConversation {
        .init(id: id, title: "Same title", revision: 1, updatedAt: Date(), messages: [
            .init(id: id + "-answer", role: "assistant", text: "Answer " + id, createdAt: Date())
        ])
    }

    @Test func uuidSpellingIsCanonicalInListSnapshotAndOldCache() async throws {
        let f = try AskTestFixture()
        let upper = "AABBCCDD-1122-3344-5566-778899AABBCC"
        let lower = upper.lowercased()
        let value = conversation(upper)
        #expect(value.id == lower)
        let bytes = try AskCoding.encoder().encode(value)
        let legacy = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: lower, with: upper)
        let decoded = try AskCoding.decoder().decode(AskConversation.self, from: Data(legacy.utf8))
        #expect(decoded.id == lower)
        // Simulate a cache written by the released uppercase-ID client.
        var db: OpaquePointer?
        #expect(sqlite3_open(f.root.appendingPathComponent("cache.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let hex = Data(legacy.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(sqlite3_exec(db, "INSERT INTO ask_cache VALUES('owner','\(upper)',X'\(hex)')", nil, nil, nil) == SQLITE_OK)
        let draftData = try AskCoding.encoder().encode(AskDraft(text: "Legacy draft"))
        let draftHex = draftData.map { String(format: "%02x", $0) }.joined()
        #expect(sqlite3_exec(db, "INSERT INTO ask_drafts VALUES('owner','\(upper)',X'\(draftHex)')", nil, nil, nil) == SQLITE_OK)
        #expect(try await f.cache.load(id: lower, owner: "owner")?.id == lower)
        #expect(try await f.cache.draft(key: lower, owner: "owner")?.text == "Legacy draft")
        await f.api.seed(decoded)
        await f.api.setListed([.init(id: lower, title: "Same title", updatedAt: Date()), .init(id: upper, title: "Same title", updatedAt: Date())])
        await f.model.refreshHistory()
        #expect(f.model.conversations.count == 1)
        await f.model.select(lower)
        #expect(f.model.selectedId == lower)
        #expect(f.model.selected?.id == lower)
        #expect(f.model.draft.text == "Legacy draft")
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.selected?.id == lower)
        #expect(f.model.conversations.count == 1)
        #expect(try await f.cache.list(owner: "owner").count == 1)
        await f.model.delete(lower)
        #expect(try await f.cache.load(id: upper, owner: "owner") == nil)
        #expect(try await f.cache.draft(key: upper, owner: "owner") == nil)
    }

    @Test func tenFollowUpsNeverCreateNewHistoryOrChangeIdentity() async throws {
        let f = try AskTestFixture()
        f.model.launcherDraft.text = "Question"; f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        let id = try #require(f.model.selectedId)
        for index in 1...10 {
            await f.model.refreshHistory()
            await f.model.select(id)
            f.model.draft.text = "Follow up \(index)"; f.model.submitDraft()
            try await f.wait { f.model.busyIds.isEmpty }
            #expect(f.model.selectedId == id)
            #expect(f.model.conversations.map(\.id) == [id])
        }
        #expect(f.model.selected?.messages.count == 22)
        #expect(await f.api.sends.count == 11)
        #expect(f.tools.bound == [id])
    }

    @Test func uncachedSelectionIsImmediateAndCannotSendAsNew() async throws {
        let f = try AskTestFixture()
        await f.api.seed(conversation("a")); await f.api.hold("a")
        let load = Task { await f.model.select("a") }
        try await f.wait { f.model.isLoadingSelection }
        #expect(f.model.selectedId == "a")
        #expect(f.model.selected == nil)
        f.model.draft.text = "Do not send"; f.model.submitDraft()
        #expect(!f.model.canSend)
        #expect(await f.api.sends.isEmpty)
        await f.api.release("a"); await load.value
        #expect(f.model.selected?.id == "a")
        #expect(!f.model.isLoadingSelection)
    }

    @Test func rapidSelectionLateResponsesDoNotStealFocusOrDrafts() async throws {
        let f = try AskTestFixture()
        for id in ["a", "b", "c"] { await f.api.seed(conversation(id)) }
        await f.model.select("a"); f.model.draft.text = "Draft A"
        await f.api.hold("b")
        let b = Task { await f.model.select("b") }
        try await f.wait { f.model.selectedId == "b" }
        await f.model.select("c"); f.model.draft.text = "Draft C"
        await f.api.release("b"); await b.value
        #expect(f.model.selectedId == "c")
        #expect(f.model.selected?.id == "c")
        #expect(f.model.draft.text == "Draft C")
        await f.model.select("a")
        #expect(f.model.draft.text == "Draft A")
        await f.model.select("c")
        #expect(f.model.draft.text == "Draft C")
    }

    @Test func failedCacheMissKeepsTargetAndBlocksAccidentalNewConversation() async throws {
        let f = try AskTestFixture()
        await f.api.failGet("offline")
        await f.model.select("offline")
        #expect(f.model.selectedId == "offline")
        #expect(f.model.error != nil)
        #expect(!f.model.isLoadingSelection)
        f.model.draft.text = "Question"; f.model.submitDraft()
        #expect(await f.api.sends.isEmpty)
        f.model.newConversation()
        #expect(f.model.selectedId == nil)
    }

    @Test func backgroundToolCompletionKeepsOtherConversationAndListPosition() async throws {
        let f = try AskTestFixture()
        await f.api.setTool(.init(id: "read", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        f.model.launcherDraft.text = "A"; f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        let a = try #require(f.model.selectedId)
        await f.api.seed(conversation("b")); await f.model.refreshHistory(); await f.model.select("b")
        let order = f.model.conversations.map(\.id)
        f.model.draft.text = "Draft B"
        f.model.approve(conversationId: a, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.selectedId == "b")
        #expect(f.model.selected?.id == "b")
        #expect(f.model.draft.text == "Draft B")
        #expect(f.model.conversations.map(\.id) == order)
        #expect(try await f.cache.load(id: a, owner: "owner")?.run?.status == "completed")
    }

    @Test func cachedSelectionKeepsContentWhileRefreshingAndRetryKeepsIdentity() async throws {
        let f = try AskTestFixture()
        for id in ["a", "b"] { await f.api.seed(conversation(id)) }
        await f.model.select("a"); await f.model.select("b")
        await f.api.hold("a")
        let load = Task { await f.model.select("a") }
        try await f.wait { f.model.selectedId == "a" }
        #expect(f.model.selected?.id == "a")
        #expect(f.model.isLoadingSelection)
        await f.api.release("a"); await load.value
        await f.api.failGet("a")
        await f.model.select("a", reload: true)
        #expect(f.model.selected?.id == "a")
        #expect(f.model.selectionLoadFailed)
        f.model.retrySelection()
        try await f.wait { !f.model.isLoadingSelection && f.model.selectionLoadFailed }
        #expect(f.model.selectedId == "a")
        #expect(await f.api.sends.isEmpty)
    }

    @Test func lateSnapshotCannotReplaceNewerCachedRevision() async throws {
        let f = try AskTestFixture()
        var value = conversation("a")
        await f.api.seed(value); await f.api.hold("a")
        let load = Task { await f.model.select("a") }
        for _ in 0..<1000 {
            if await f.api.waiting["a"]?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        value.revision = 10; value.title = "Latest answer"
        try await f.cache.save(value, owner: "owner")
        await f.api.release("a"); await load.value
        #expect(f.model.selected?.revision == 10)
        #expect(f.model.selected?.title == "Latest answer")
    }

    @Test func loadingDoesNotOverwriteAnExistingPersistedDraft() async throws {
        let f = try AskTestFixture()
        await f.api.seed(conversation("a")); await f.api.hold("a")
        try await f.cache.saveDraft(.init(text: "Saved draft", selection: "Context"), key: "a", owner: "owner")
        let load = Task { await f.model.select("a") }
        try await f.wait { f.model.isLoadingSelection }
        f.model.persistDrafts()
        try await Task.sleep(for: .milliseconds(350))
        #expect(try await f.cache.draft(key: "a", owner: "owner")?.text == "Saved draft")
        await f.api.release("a"); await load.value
        #expect(f.model.draft.text == "Saved draft")
        #expect(f.model.draft.selection == "Context")
    }

    @Test func sameTitlesRemainDistinctAndOverlappingPagesAreUnique() async throws {
        let f = try AskTestFixture()
        let rows = (0..<60).map { AskConversationSummary(id: "id-\($0)", title: "Same title", updatedAt: Date()) }
        await f.api.setListed(Array(rows.prefix(50)) + Array(rows[40..<60]))
        await f.model.refreshHistory()
        #expect(f.model.conversations.count == 50)
        #expect(f.model.historyHasMore)
        await f.model.refreshHistory(loadMore: true)
        #expect(f.model.conversations.count == 60)
        #expect(!f.model.historyHasMore)
    }
}
