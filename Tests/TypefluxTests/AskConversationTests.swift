import AppKit
import SwiftUI
import Testing
@testable import Typeflux

actor AskTestAPI: AskAPI {
    var values: [String: AskConversation] = [:]
    var sends: [AskSendRequest] = []
    var results: [AskToolResultRequest] = []
    var nextTool: AskToolCall?
    var failSend = false
    var failList = false

    func setTool(_ call: AskToolCall?) { nextTool = call }
    func setFailSend(_ flag: Bool) { failSend = flag }
    func setFailList(_ flag: Bool) { failList = flag }
    func seed(_ value: AskConversation) { values[value.id] = value }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] {
        if failList { throw AskLocalError.message("Network unavailable") }
        return values.values.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(offset).map { .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }
    func conversation(id: String, token: String) async throws -> AskConversation {
        guard let value = values[id] else { throw AskLocalError.message("Not found") }
        return value
    }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        if failSend { throw AskLocalError.message("Network unavailable") }
        sends.append(request)
        var value = values[conversationId] ?? AskConversation(id: conversationId, title: request.text, revision: 0, updatedAt: Date(), messages: [])
        if value.messages.contains(where: { $0.id == request.id }) { return value }
        value.messages.append(.init(id: request.id, role: "user", text: request.text, selection: request.selection, source: request.source, image: request.image, createdAt: Date()))
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: nextTool == nil ? "This is the answer." : "I can inspect the current page.", toolCalls: nextTool.map { [$0] }, createdAt: Date()))
        value.run = .init(id: UUID().uuidString, deviceId: request.deviceId, status: nextTool == nil ? "completed" : "waiting_tool", steps: 1, updatedAt: Date(), tools: request.tools, pending: nextTool.map { [$0] } ?? [])
        value.revision += 1; values[conversationId] = value
        return value
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        results.append(request)
        var value = try await conversation(id: conversationId, token: token)
        value.messages.append(.init(id: UUID().uuidString, role: "tool", text: request.content, toolCallId: request.toolCallId, isError: request.isError, createdAt: Date()))
        value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: request.isError ? "I will continue without that tool." : "Here is the summary.", createdAt: Date()))
        value.run?.status = "completed"; value.run?.pending = []; value.revision += 1; values[conversationId] = value
        return value
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        var value = try await conversation(id: conversationId, token: token)
        value.run?.status = "cancelled"; value.run?.pending = []; value.revision += 1; values[conversationId] = value
        return value
    }
    func retry(conversationId: String, runId: String, deviceId: String, token: String) async throws -> AskConversation {
        var value = try await conversation(id: conversationId, token: token)
        value.run?.status = "completed"; value.revision += 1; values[conversationId] = value
        return value
    }
    func delete(conversationId: String, token: String) async throws { values[conversationId] = nil }
}

@MainActor
final class AskTestTools: AskToolExecuting {
    var executions = 0
    var fail = false
    var bound: [String] = []
    func bindConversation(_ id: String) { bound.append(id) }
    func definitions() async -> [AskToolDefinition] { AskLocalTools.builtins }
    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        executions += 1
        if fail { throw AskLocalError.message("Tool unavailable") }
        return .init(content: "Observed source")
    }
}

@MainActor
final class AskTestCapture: AskContextCapturing {
    var calls = 0
    var warning: String?
    func capture(includeScreenshot: Bool) async -> AskCapturedContext {
        calls += 1
        return .init(selection: "Selected words", source: "Safari", screenshot: includeScreenshot ? "data:image/jpeg;base64,YQ==" : nil, warning: warning)
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
    init(authenticated: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-tests-" + UUID().uuidString)
        cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        model = AskConversationModel(api: api, cache: cache, tools: tools, capture: capture,
                                     deviceId: "device", session: { authenticated ? ("owner", "token") : nil })
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
