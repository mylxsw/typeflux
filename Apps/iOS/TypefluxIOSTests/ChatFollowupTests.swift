// swiftlint:disable file_length
import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Temporary conversations, renaming, titles and routed models")
struct ChatFollowupTests {
    func make(api: TitleAPI = TitleAPI(), provider: ScriptedProvider = ScriptedProvider(),
              withProvider: Bool = false, local: ChatLocalStore? = nil) throws -> (ChatStore, TitleAPI, ScriptedProvider) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("test|Test Provider", forKey: "ai-consent.test-user")
        let library = ChatModelLibrary.ephemeral()
        if withProvider {
            try library.save(ChatOfflineTests.deepSeek, key: "sk-test")
        }
        let store = ChatStore(service: api, credentials: MemoryCredentials(), deviceID: "ios-test",
                              consentDefaults: defaults, reconnectDelay: .milliseconds(1), library: library,
                              providerService: provider, cache: try ChatLocalStore.inMemory(),
                              localStore: try local ?? ChatLocalStore.inMemory())
        store.titleRefreshDelay = .milliseconds(1)
        return (store, api, provider)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the test operation")
    }

    private func finishTitles(_ store: ChatStore) async {
        for task in store.titleTasks.values {
            await task.value
        }
    }

    // MARK: Temporary conversations

    @Test func `a temporary cloud conversation is never listed and is deleted when left`() async throws {
        let (store, api, _) = try make()
        await store.login(email: "person@example.com", password: "pw")
        #expect(store.canStartTemporary)
        store.toggleTemporary()
        #expect(store.isTemporary)
        store.draft = "Just once"
        await store.send()
        let id = try #require(store.selectedID)
        #expect(await api.lastSend?.temporary == true)
        #expect(store.temporaryIDs.contains(id))
        #expect(store.isTemporary)
        #expect(!store.conversations.contains { $0.id == id })
        #expect(!store.canStartTemporary)
        let owner = try #require(store.cacheOwner)
        #expect(try await store.cache?.conversation(id: id, owner: owner) == nil)

        // A follow-up stays in the same temporary conversation without the flag mattering.
        store.draft = "Again"
        await store.send()
        #expect(await api.lastSend?.temporary == nil)

        store.newConversation()
        #expect(!store.startsTemporary)
        #expect(!store.temporaryIDs.contains(id))
        try await eventually { await api.deleted.contains(id) }
    }

    @Test func `keeping a temporary conversation lists it`() async throws {
        let (store, api, _) = try make()
        await store.login(email: "person@example.com", password: "pw")
        store.toggleTemporary()
        store.draft = "Worth keeping"
        await store.send()
        let id = try #require(store.selectedID)
        await store.keepTemporary()
        #expect(await api.kept == [id])
        #expect(!store.isTemporary)
        #expect(store.conversations.first?.id == id)
        store.newConversation()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await api.deleted.isEmpty)
    }

    @Test func `keeping fails clearly while Typeflux is unreachable`() async throws {
        let (store, api, _) = try make()
        await store.login(email: "person@example.com", password: "pw")
        store.toggleTemporary()
        store.draft = "Q"
        await store.send()
        await api.setOutage(true)
        await store.keepTemporary()
        #expect(store.isTemporary)
        #expect(store.errorMessage == ChatStore.unavailableActionMessage)
        await api.setRefuseKeep(true)
        await api.setOutage(false)
        await store.keepTemporary()
        #expect(store.isTemporary)
        #expect(store.errorMessage != ChatStore.unavailableActionMessage)
    }

    @Test func `a temporary private conversation is never written to the device`() async throws {
        let local = try ChatLocalStore.inMemory()
        let (store, _, _) = try make(withProvider: true, local: local)
        await store.restore()
        #expect(store.canStartTemporary)
        store.toggleTemporary()
        store.draft = "Private and temporary"
        await store.send()
        let id = try #require(store.selectedID)
        #expect(store.conversation?.messages.count == 2)
        #expect(store.conversationStorage == .local)
        #expect(store.localConversations.isEmpty)
        #expect(try await local.summaries(owner: ChatStore.localOwner).isEmpty)
        store.newConversation()
        #expect(!store.isLocalConversation(id))
    }

    @Test func `keeping a temporary private conversation saves it`() async throws {
        let local = try ChatLocalStore.inMemory()
        let (store, _, _) = try make(withProvider: true, local: local)
        await store.restore()
        store.toggleTemporary()
        store.draft = "Keep me"
        await store.send()
        let id = try #require(store.selectedID)
        await store.keepTemporary()
        #expect(!store.isTemporary)
        #expect(store.localConversations.map(\.id) == [id])
        #expect(try await local.conversation(id: id, owner: ChatStore.localOwner)?.messages.count == 2)
    }

    @Test func `temporary is offered only before the first message and with somewhere to send`() async throws {
        let (store, _, _) = try make()
        await store.restore()
        #expect(!store.canStartTemporary)
        store.toggleTemporary()
        #expect(!store.startsTemporary)
    }

    // MARK: Renaming

    @Test func `renaming a cloud conversation updates the list and the open conversation`() async throws {
        let (store, api, _) = try make()
        await store.login(email: "person@example.com", password: "pw")
        await store.select("one")
        #expect(await store.rename("one", to: "  Trip plans  "))
        #expect(await api.renamed == ["Trip plans"])
        #expect(store.conversations.first { $0.id == "one" }?.title == "Trip plans")
        #expect(store.conversation?.title == "Trip plans")
        #expect(store.conversation?.titleSource == "manual")
        // Renaming another conversation leaves the open one alone.
        store.newConversation()
        #expect(await store.rename("one", to: "Again"))
        #expect(store.conversations.first { $0.id == "one" }?.title == "Again")
    }

    @Test func `invalid titles and busy conversations are explained`() async throws {
        let (store, api, _) = try make()
        await store.login(email: "person@example.com", password: "pw")
        #expect(await !store.rename("one", to: " "))
        #expect(store.errorMessage == "Use a single line of up to 60 characters.")
        #expect(await !store.rename("one", to: String(repeating: "x", count: 61)))
        #expect(await !store.rename("one", to: "two\nlines"))
        await api.setOutage(true)
        #expect(await !store.rename("one", to: "Offline"))
        #expect(store.errorMessage == ChatStore.unavailableActionMessage)
        await api.setOutage(false)
        await api.setRenameConflict(true)
        #expect(await !store.rename("one", to: "Conflict"))
        #expect(store.errorMessage != nil)
        #expect(await api.renamed.isEmpty)
    }

    @Test func `renaming a private conversation keeps it on the device`() async throws {
        let local = try ChatLocalStore.inMemory()
        let (store, _, _) = try make(withProvider: true, local: local)
        await store.restore()
        store.draft = "Name me"
        await store.send()
        let id = try #require(store.selectedID)
        #expect(await store.rename(id, to: "My notes"))
        #expect(store.conversation?.title == "My notes")
        #expect(store.localConversations.first?.title == "My notes")
        store.newConversation()
        #expect(await store.rename(id, to: "From the list"))
        let saved = try await local.conversation(id: id, owner: ChatStore.localOwner)
        #expect(saved?.title == "From the list")
        #expect(saved?.titleSource == "manual")
        #expect(await !store.rename("missing", to: "Nothing"))
    }

    // MARK: Generated titles

    @Test func `a private conversation is named by its model after the second answer`() async throws {
        let provider = ScriptedProvider()
        let (store, _, _) = try make(provider: provider, withProvider: true)
        await store.restore()
        store.draft = "First question"
        await store.send()
        await finishTitles(store)
        #expect(store.conversation?.titleSource == nil)
        await provider.enqueue([[.text("Second answer")], [.text("\u{201C}Trip planning\u{201D}")]])
        store.draft = "Second question"
        await store.send()
        try await eventually { store.conversation?.titleSource == "auto" }
        #expect(store.conversation?.title == "Trip planning")
        #expect(store.localConversations.first?.title == "Trip planning")
        let request = try #require(await provider.requests.last)
        #expect(request.system == ChatConversationTitle.prompt)
        #expect(request.maxOutputTokens == 128)
        #expect(request.messages.first?.text.contains("User: First question") == true)
    }

    @Test func `a manual rename is never replaced by a generated title`() async throws {
        let provider = ScriptedProvider()
        let (store, _, _) = try make(provider: provider, withProvider: true)
        await store.restore()
        store.draft = "One"
        await store.send()
        let id = try #require(store.selectedID)
        #expect(await store.rename(id, to: "Mine"))
        store.draft = "Two"
        await store.send()
        await finishTitles(store)
        #expect(store.conversation?.title == "Mine")
    }

    @Test func `an unusable generated title keeps the provisional one`() async throws {
        let provider = ScriptedProvider()
        let (store, _, _) = try make(provider: provider, withProvider: true)
        await store.restore()
        store.draft = "One"
        await store.send()
        await provider.enqueue([[.text("Answer")], [.fail(.rateLimited)]])
        store.draft = "Two"
        await store.send()
        let title = store.conversation?.title
        // The naming request fails; the provisional title stays.
        await finishTitles(store)
        #expect(store.conversation?.titleSource == nil)
        #expect(store.conversation?.title == title)
    }

    @Test func `a cloud conversation asks the server for a title once`() async throws {
        let (store, api, _) = try make()
        await api.setTwoPairs()
        await store.login(email: "person@example.com", password: "pw")
        await store.select("one")
        try await eventually { store.conversations.first { $0.id == "one" }?.title == "Generated" }
        #expect(await api.generated == 1)
        await store.select("one")
        await finishTitles(store)
        #expect(await api.generated == 1)
    }

    // MARK: Launch and consent

    @Test func `launch shows the device copy without waiting for the server`() async throws {
        let cache = try ChatLocalStore.inMemory()
        let owner = "account:person@example.com"
        try await cache.syncCloudPage([ChatConversationSummary(id: "one", title: "Cached")], owner: owner,
                                      firstPage: true, complete: true)
        let api = TitleAPI()
        await api.setOutage(true)
        let credentials = MemoryCredentials()
        credentials.value = SavedAccount(email: "person@example.com",
                                         session: ChatSession(accessToken: "t", expiresAt: 0, refreshToken: nil))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ChatStore(service: api, credentials: credentials, deviceID: "ios-test", consentDefaults: defaults,
                              cache: cache, localStore: try ChatLocalStore.inMemory())
        #expect(await store.restoreSession())
        #expect(store.isAuthenticated)
        #expect(store.conversations.map(\.title) == ["Cached"])
        // No request has been made yet, so nothing has failed.
        #expect(store.connectivity == .online)
        #expect(await api.requests == 0)
        await store.refreshAfterRestore()
        #expect(store.connectivity == .serviceUnavailable)
        #expect(store.conversations.map(\.title) == ["Cached"])
        // A second restore is a no-op once signed in.
        #expect(await !store.restoreSession())
    }

    @Test func `an unconfigured disclosure is reported and private models stay usable`() async throws {
        let (store, api, _) = try make(withProvider: true)
        await api.setPrivacyUnconfigured(true)
        await store.login(email: "person@example.com", password: "pw")
        #expect(store.disclosureUnconfigured)
        #expect(store.disclosure == nil)
        store.draft = "Cloud question"
        await store.send()
        #expect(store.showsConsent)
        #expect(await api.lastSend == nil)
        store.continueInPrivateConversation()
        #expect(store.sendsLocally)
        #expect(store.draft == "Cloud question")
        await api.setPrivacyUnconfigured(false)
        _ = await store.loadDisclosure()
        #expect(!store.disclosureUnconfigured)
        #expect(store.disclosure != nil)
    }

    // MARK: Routed model

    @Test func `answers name the model Auto was routed to`() async throws {
        let (store, api, _) = try make()
        await api.setServedModel(ref: "cloud:default", name: "DeepSeek V4")
        await store.login(email: "person@example.com", password: "pw")
        await store.select("one")
        let answer = try #require(store.conversation?.messages.last)
        #expect(store.modelLabel(for: answer) == String(format: NSLocalizedString("Auto → %@", comment: ""),
                                                        "DeepSeek V4"))
        await api.setServedModel(ref: "cloud:balanced", name: "Balanced")
        await store.select("one")
        let chosen = try #require(store.conversation?.messages.last)
        #expect(store.modelLabel(for: chosen) == "Balanced")
        let older = ChatMessage(id: "old", role: "assistant", text: "Earlier", modelName: "Kimi K2")
        #expect(store.modelLabel(for: older) == "Kimi K2")
    }
}

/// A Typeflux API with titles, temporary conversations and served models.
actor TitleAPI: ChatAPI {
    private(set) var lastSend: ChatSendRequest?
    private(set) var deleted: [String] = []
    private(set) var kept: [String] = []
    private(set) var renamed: [String] = []
    private(set) var generated = 0
    private var outage = false
    private var refuseKeep = false
    private var renameConflict = false
    private var twoPairs = false
    private var servedRef: String?
    private var servedName: String?
    private var temporary: Set<String> = []
    private var documents: [String: ChatConversation] = [:]

    func setOutage(_ value: Bool) { outage = value }
    func setRefuseKeep(_ value: Bool) { refuseKeep = value }
    func setRenameConflict(_ value: Bool) { renameConflict = value }
    func setTwoPairs() { twoPairs = true }
    func setServedModel(ref: String, name: String) { servedRef = ref; servedName = name }
    private var privacyUnconfigured = false
    func setPrivacyUnconfigured(_ value: Bool) { privacyUnconfigured = value }
    /// Requests that reached this service, whatever their outcome.
    private(set) var requests = 0

    private func check() throws {
        requests += 1
        if outage { throw URLError(.cannotConnectToHost) }
    }

    private func document(_ id: String) -> ChatConversation {
        if let value = documents[id] { return value }
        var messages = [ChatMessage(id: "q1", role: "user", text: "Question"),
                        ChatMessage(id: "a1", role: "assistant", text: "Answer", modelName: servedName)]
        if twoPairs {
            messages += [ChatMessage(id: "q2", role: "user", text: "More"),
                         ChatMessage(id: "a2", role: "assistant", text: "More answer", modelName: servedName)]
        }
        return ChatConversation(id: id, title: "A conversation", revision: 1,
                                updatedAt: Date(timeIntervalSince1970: 1_800_000_000), messages: messages,
                                run: ChatRun(id: "r", deviceId: "ios-test", status: "completed", modelRef: servedRef,
                                             modelName: servedName))
    }

    func login(email _: String, password _: String) async throws -> ChatSession {
        ChatSession(accessToken: "token", expiresAt: 0, refreshToken: "refresh")
    }

    func refresh(refreshToken _: String) async throws -> ChatSession {
        ChatSession(accessToken: "token", expiresAt: 0, refreshToken: "refresh")
    }

    func logout(refreshToken _: String) async throws {}

    func models(token _: String) async throws -> [ChatModel] {
        try check()
        return [ChatModel(id: "balanced", name: "Balanced", vision: true)]
    }

    func list(token _: String, offset _: Int) async throws -> [ChatConversationSummary] {
        try check()
        let stored = documents.values.filter { !temporary.contains($0.id) }
            .map { ChatConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        return [ChatConversationSummary(id: "one", title: document("one").title,
                                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000))] +
            stored.filter { $0.id != "one" }
    }

    func conversation(id: String, token _: String) async throws -> ChatConversation {
        try check()
        return document(id)
    }

    func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
        try check()
        lastSend = request
        var value = documents[conversationId] ?? ChatConversation(id: conversationId, title: "New", revision: 0)
        if documents[conversationId] == nil, request.temporary == true {
            temporary.insert(conversationId)
        }
        value.revision += 1
        value.messages.append(ChatMessage(id: request.id, role: "user", text: request.text))
        documents[conversationId] = value
        return value
    }

    func cancel(conversationId: String, runId _: String, token _: String) async throws -> ChatConversation {
        document(conversationId)
    }

    func observe(id _: String, token _: String,
                 onValue _: @concurrent @Sendable (ChatConversation) async throws -> Void) async throws {}

    func profile(token _: String) async throws -> ChatProfile {
        ChatProfile(id: "test-user", email: "person@example.com")
    }

    func aiDisclosure(token _: String) async throws -> ChatAIDisclosure {
        try check()
        if privacyUnconfigured {
            throw ChatAPIError.server(code: "PRIVACY_UNAVAILABLE", message: "AI provider details are not configured.")
        }
        return ChatAIDisclosure(version: "test", providers: ["Test Provider"])
    }

    func deleteConversation(id: String, token _: String) async throws {
        deleted.append(id)
        documents[id] = nil
    }

    func keep(conversationId: String, token _: String) async throws -> ChatConversation {
        try check()
        if refuseKeep { throw ChatAPIError.server(code: "NOT_FOUND", message: nil) }
        kept.append(conversationId)
        temporary.remove(conversationId)
        return documents[conversationId] ?? document(conversationId)
    }

    func updateTitle(conversationId: String, request: ChatTitleRequest,
                     token _: String) async throws -> ChatConversation {
        try check()
        var value = document(conversationId)
        switch request.action {
        case "rename":
            if renameConflict { throw ChatAPIError.server(code: "ASK_CONFLICT", message: nil) }
            renamed.append(request.title ?? "")
            value.title = request.title ?? ""
            value.titleSource = "manual"
        case "generate":
            generated += 1
            // The server names it in the background; the next read shows the title.
            value.title = "Generated"
            value.titleSource = "auto"
        default:
            break
        }
        value.revision += 1
        documents[conversationId] = value
        return request.action == "generate" ? document(conversationId) : value
    }
}
