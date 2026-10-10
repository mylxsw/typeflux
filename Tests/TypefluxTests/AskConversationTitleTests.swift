import Foundation
import Testing
@testable import Typeflux

private actor TitleTestAPI: AskAPI {
    var values: [String: AskConversation] = [:]
    var requests: [AskTitleRequest] = []
    func seed(_ value: AskConversation) { values[value.id] = value }
    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation {
        requests.append(request)
        var value = try await conversation(id: id, token: token)
        if request.action == "generate" {
            _ = try AskConversationTitle.apply(.init(action: "claim", id: request.id), to: &value, now: Date())
            _ = try AskConversationTitle.apply(.init(action: "complete", id: request.id, title: "Generated title"), to: &value, now: Date())
        } else {
            _ = try AskConversationTitle.apply(request, to: &value, now: Date())
        }
        value.revision += 1
        values[id] = value
        return value
    }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { [] }
    func conversation(id: String, token: String) async throws -> AskConversation {
        guard let value = values[id] else { throw URLError(.resourceUnavailable) }
        return value
    }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }
    func delete(conversationId: String, token: String) async throws { values[conversationId] = nil }
}

@Suite("Conversation titles", .exclusiveUIState)
@MainActor
struct AskConversationTitleTests {
    private func conversation() -> AskConversation {
        let date = Date(timeIntervalSince1970: 1_790_870_400)
        return AskConversation(id: UUID().uuidString.lowercased(), title: "Initial question", revision: 2, updatedAt: date,
            messages: [.init(id: "u1", role: "user", text: "Design chat titles", createdAt: date),
                       .init(id: "a1", role: "assistant", text: "Use a title model", createdAt: date),
                       .init(id: "u2", role: "user", text: "Only after two answers", createdAt: date),
                       .init(id: "a2", role: "assistant", text: "Generate once", createdAt: date)])
    }

    @Test func countsFinalAnswersAndExcludesPrivateContext() throws {
        var value = conversation()
        value.messages[0].selection = "PRIVATE SELECTION"
        value.memory = .init(global: "PRIVATE MEMORY")
        value.messages.insert(.init(id: "tool-step", role: "assistant", text: "Checking",
            toolCalls: [.init(id: "tool", type: "function", function: .init(name: "read", arguments: "{}"))], createdAt: value.updatedAt), at: 1)
        value.messages.insert(.init(id: "partial", role: "assistant", text: "Failed preview", isError: true, createdAt: value.updatedAt), at: 2)
        value.messages.insert(.init(id: "tool-result", role: "tool", text: "PRIVATE TOOL", createdAt: value.updatedAt), at: 3)
        let transcript = try #require(AskConversationTitle.transcript(value))
        #expect(!transcript.contains("PRIVATE"))
        #expect(!transcript.contains("Checking"))
        #expect(!transcript.contains("Failed"))
        value.messages.removeLast(2)
        #expect(AskConversationTitle.transcript(value) == nil)
    }

    @Test func generatesOnlyOnceAndManualRenameWins() throws {
        var value = conversation()
        let original = value
        let task = UUID().uuidString
        let now = Date()
        #expect(try AskConversationTitle.apply(.init(action: "claim", id: task), to: &value, now: now))
        #expect(try !AskConversationTitle.apply(.init(action: "claim", id: UUID().uuidString), to: &value, now: now))
        #expect(try AskConversationTitle.apply(.init(action: "complete", id: task, title: "Chat title design"), to: &value, now: now))
        #expect(value.titleSource == "auto")
        #expect(value.messages == original.messages)
        #expect(value.updatedAt == original.updatedAt)
        #expect(try !AskConversationTitle.apply(.init(action: "claim", id: UUID().uuidString), to: &value, now: now))
        #expect(try AskConversationTitle.apply(.init(action: "rename", title: "My title"), to: &value, now: now))
        #expect(try !AskConversationTitle.apply(.init(action: "complete", id: task, title: "Late title"), to: &value, now: now))
        #expect(value.title == "My title")
        #expect(value.titleSource == "manual")
    }

    @Test func expiryStaleResultsAndBoundedRetries() throws {
        var value = conversation()
        var now = Date()
        for attempt in 1...3 {
            let task = UUID().uuidString
            #expect(try AskConversationTitle.apply(.init(action: "claim", id: task), to: &value, now: now))
            #expect(value.titleGeneration?.attempts == attempt)
            #expect(try !AskConversationTitle.apply(.init(action: "complete", id: UUID().uuidString, title: "Stale"), to: &value, now: now))
            now = now.addingTimeInterval(61)
            #expect(try !AskConversationTitle.apply(.init(action: "complete", id: task, title: "Expired"), to: &value, now: now))
        }
        #expect(try !AskConversationTitle.apply(.init(action: "claim", id: UUID().uuidString), to: &value, now: now))
        #expect(value.title == "Initial question")
    }

    @Test func invalidOutputsDisabledPolicyAndActiveRuns() throws {
        for text in ["", "line\nbreak", "line\rbreak", String(repeating: "x", count: 61)] {
            #expect(throws: (any Error).self) { try AskConversationTitle.clean(text) }
        }
        #expect(try AskConversationTitle.clean("  “Title”  ") == "Title")
        var value = conversation()
        value.titlePolicy = .init(enabled: false, modelRef: "")
        #expect(try !AskConversationTitle.apply(.init(action: "claim", id: UUID().uuidString), to: &value, now: Date()))
        value.titlePolicy = nil
        value.run = .init(id: "active", deviceId: "device", status: "running", steps: 0, updatedAt: Date(), tools: [], pending: [])
        #expect(throws: (any Error).self) { try AskConversationTitle.apply(.init(action: "rename", title: "Manual"), to: &value, now: Date()) }
        #expect(try !AskConversationTitle.apply(.init(action: "claim", id: UUID().uuidString), to: &value, now: Date()))
        #expect(throws: (any Error).self) { try AskConversationTitle.apply(.init(action: "unknown"), to: &value, now: Date()) }
    }

    @Test func preferencesPersistAndLegacySnapshotsStillDecode() throws {
        let suite = "title-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.askAutomaticTitles)
        #expect(settings.askTitleModelReference.isEmpty)
        settings.askAutomaticTitles = false
        settings.askTitleModelReference = "custom:chosen"
        let restored = SettingsStore(defaults: defaults)
        #expect(!restored.askAutomaticTitles)
        #expect(restored.askTitleModelReference == "custom:chosen")
        let old = conversation()
        let decoded = try AskCoding.decoder().decode(AskConversation.self, from: AskCoding.encoder().encode(old))
        #expect(decoded.titleSource == nil)
        #expect(decoded.titleGeneration == nil)
        #expect(decoded == old)
    }

    @Test func localEnginePersistsTitleWithoutReorderingConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("title-local-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory, webTools: .init(resolve: { _ in [] }))
        let id = UUID().uuidString.lowercased()
        var value: AskConversation?
        for question in ["Design chat titles", "Only after two answers"] {
            let sent = try await engine.send(conversationId: id,
                request: .init(id: UUID().uuidString, deviceId: "device", text: question, tools: [], modelRef: "custom:chosen"), token: "")
            let run = try #require(sent.run)
            let inference = try #require(run.inference)
            value = try await engine.inferenceResult(conversationId: id,
                request: .init(runId: run.id, deviceId: "device", inferenceId: inference.id, content: "Generate once"), token: "")
        }
        let original = try #require(value)
        let task = UUID().uuidString
        _ = try await engine.updateTitle(id: id, request: .init(action: "claim", id: task), token: "")
        let final = try await engine.updateTitle(id: id, request: .init(action: "complete", id: task, title: "Chat title design"), token: "")
        #expect(final.updatedAt == original.updatedAt)
        #expect(final.run == original.run)
        #expect(final.messages == original.messages)
        let restored = try await AskLocalEngine(directory: directory).conversation(id: id, token: "")
        #expect(restored.title == "Chat title design")
        #expect(restored.titleSource == "auto")
        let repeated = try await engine.updateTitle(id: id, request: .init(action: "claim", id: UUID().uuidString), token: "")
        #expect(repeated.revision == final.revision)
    }

    @Test func conversationModelNamesAfterTwoAnswersAndRefreshesSidebarAndCache() async throws {
        for scenario in ["two answers", "one answer", "disabled", "manual", "local Cloud selection"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("title-model-" + UUID().uuidString)
            let suite = "title-model-settings-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
            let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
            if scenario == "disabled" { library.settings.askAutomaticTitles = false }
            if scenario == "local Cloud selection" { library.settings.askTitleModelReference = "cloud:chosen" }
            let api = TitleTestAPI()
            let cache = try AskConversationCache(url: directory.appendingPathComponent("cache.sqlite"))
            let token = scenario == "local Cloud selection" ? "" : "token"
            let model = AskConversationModel(api: api, cache: cache, tools: AskTestTools(), capture: AskTestCapture(),
                                            deviceId: "device", modelLibrary: library, defaults: defaults,
                                            session: { ("owner", token) })
            _ = model.credentials()
            defer { model.resetSession() }
            var value = conversation()
            value.run = .init(id: "settled", deviceId: "device", status: "completed", steps: 1, updatedAt: Date(), tools: [], pending: [])
            if scenario == "one answer" { value.messages.removeLast(2) }
            if scenario == "manual" { value.titleSource = "manual" }
            await api.seed(value)
            let route = try #require(model.credentials(for: value.id))
            try await model.accept(value, route: route)
            for task in Array(model.titleTasks.values) { await task.value }
            let requests = await api.requests
            if scenario == "two answers" {
                #expect(requests.count == 1)
                #expect(requests.first?.action == "generate")
                #expect(requests.first?.modelRef == "cloud:default")
                #expect(model.conversations.first?.title == "Generated title")
                let cached = try await cache.load(id: value.id, owner: route.owner)
                #expect(cached?.titleSource == "auto")
                #expect(cached?.title == "Generated title")
                let final = try await api.conversation(id: value.id, token: token)
                model.scheduleTitle(final, route: route)
                #expect(model.titleTasks.isEmpty)
            } else {
                #expect(requests.isEmpty)
                #expect(model.conversations.first?.title == value.title)
            }
        }
    }
}
