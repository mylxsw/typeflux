// swiftlint:disable file_length
import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Offline use, private conversations and model choice")
struct ChatOfflineTests {
    // MARK: Fixtures

    struct Fixture {
        let store: ChatStore
        let api: OutageAPI
        let credentials: MemoryCredentials
        let provider: ScriptedProvider
        let library: ChatModelLibrary
        let cache: ChatLocalStore
        let local: ChatLocalStore
    }

    func make(api: OutageAPI = OutageAPI(), credentials: MemoryCredentials = MemoryCredentials(),
              provider: ScriptedProvider = ScriptedProvider(), library: ChatModelLibrary? = nil,
              cache: ChatLocalStore? = nil, local: ChatLocalStore? = nil, withProvider: Bool = false) throws -> Fixture {
        let library = library ?? ChatModelLibrary.ephemeral()
        if withProvider {
            try library.save(Self.deepSeek, key: "sk-test")
        }
        let cache = try cache ?? ChatLocalStore.inMemory()
        let local = try local ?? ChatLocalStore.inMemory()
        let store = ChatStore(service: api, credentials: credentials, deviceID: "ios-test",
                              reconnectDelay: .milliseconds(1), library: library, providerService: provider,
                              cache: cache, localStore: local)
        return Fixture(store: store, api: api, credentials: credentials, provider: provider, library: library,
                       cache: cache, local: local)
    }

    static let deepSeek = ChatProvider(id: "p1", kind: .deepSeek, models: [
        ChatProviderModel(id: "deepseek-chat"),
        ChatProviderModel(id: "deepseek-vl", vision: true),
        ChatProviderModel(id: "off", enabled: false),
    ])
    static let localChat = "local:p1/deepseek-chat"

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the test operation")
    }

    private func account() -> SavedAccount {
        SavedAccount(email: "Person@Example.com", session: ChatSession(accessToken: "token", expiresAt: 0,
                                                                       refreshToken: "refresh"))
    }

    // MARK: Offline cloud copy

    @Test func `restore shows the device copy and a notice when Typeflux is down`() async throws {
        let online = try make()
        await online.store.login(email: "person@example.com", password: "pw")
        await online.store.select("one")
        #expect(online.store.connectivity == .online)
        #expect(online.store.cloudSyncedAt != nil)
        let owner = try #require(online.store.cacheOwner)
        try await eventually {
            let conversation = try? await online.cache.conversation(id: "one", owner: owner)
            let profile = try? await online.cache.value(ChatProfile.self, key: ChatStore.profileCacheKey, owner: owner)
            return conversation != nil && profile != nil
        }

        let credentials = MemoryCredentials()
        credentials.value = account()
        let api = OutageAPI()
        await api.setOutage(.cannotConnectToHost)
        let offline = try make(api: api, credentials: credentials, cache: online.cache, local: online.local)
        await offline.store.restore()
        #expect(offline.store.isAuthenticated)
        #expect(offline.store.connectivity == .serviceUnavailable)
        #expect(offline.store.errorMessage == nil)
        #expect(offline.store.conversations.map(\.id) == ["one"])
        #expect(offline.store.models.map(\.id) == ["balanced", "text-only"])
        #expect(offline.store.profile?.id == "test-user")
        #expect(offline.store.connectivityNotice != nil)
        #expect(offline.store.modelRef == "cloud:balanced")

        await offline.store.select("one")
        #expect(offline.store.conversation?.messages.first?.text == "Cached question")
        #expect(offline.store.errorMessage == nil)
        #expect(offline.store.composerValidation == nil)
    }

    @Test func `a cloud message that cannot be sent keeps its draft and is never retried`() async throws {
        let fixture = try make(withProvider: true)
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.api.setOutage(.notConnectedToInternet)
        fixture.store.draft = "Still here"
        await fixture.store.send()
        #expect(fixture.store.draft == "Still here")
        #expect(fixture.store.errorMessage == ChatStore.offlineMessage)
        #expect(fixture.store.connectivity == .offline)
        #expect(fixture.store.offersLocalFallback)
        // One attempt, never repeated on its own.
        #expect(await fixture.api.sendAttempts == 1)

        fixture.store.continueInPrivateConversation()
        #expect(fixture.store.draft == "Still here")
        #expect(fixture.store.modelRef == Self.localChat)
        #expect(fixture.store.sendsLocally)
        #expect(!fixture.store.offersLocalFallback)
        await fixture.api.setOutage(nil)
        await fixture.store.send()
        #expect(await fixture.api.sendAttempts == 1)
        #expect(fixture.store.localConversations.count == 1)
    }

    @Test func `server outages are banners while refusals stay errors`() async throws {
        let fixture = try make()
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.api.setFailure(ChatAPIError.server(code: "HTTP_503", message: nil))
        await fixture.store.refreshHome()
        #expect(fixture.store.connectivity == .serviceUnavailable)
        #expect(fixture.store.errorMessage == nil)
        await fixture.api.setFailure(ChatAPIError.server(code: "RATE_LIMITED", message: nil))
        await fixture.store.refreshHome()
        #expect(fixture.store.errorMessage != nil)
        fixture.store.draft = "Q"
        await fixture.api.setFailure(nil)
        await fixture.api.setOutage(.timedOut)
        await fixture.store.send()
        #expect(fixture.store.errorMessage == ChatStore.unavailableMessage)
        // Without a provider of their own, there is nowhere else to continue.
        #expect(!fixture.store.offersLocalFallback)
        #expect(await fixture.api.sendAttempts == 1)

        // Only the message request itself fails.
        await fixture.api.setOutage(nil)
        await fixture.api.setSendOutage(.networkConnectionLost)
        await fixture.store.send()
        #expect(await fixture.api.sendAttempts == 2)
        #expect(fixture.store.errorMessage == ChatStore.offlineMessage)
        #expect(fixture.store.draft == "Q")
        await fixture.api.setSendOutage(nil)
        await fixture.store.send()
        #expect(await fixture.api.sendAttempts == 3)
        #expect(fixture.store.draft.isEmpty)
        #expect(fixture.store.errorMessage == nil)
    }

    @Test func `regaining the network refreshes and clears the outage`() async throws {
        let fixture = try make()
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.store.select("one")
        await fixture.store.networkChanged(available: false)
        #expect(fixture.store.connectivity == .offline)
        await fixture.store.networkChanged(available: true)
        #expect(fixture.store.connectivity == .online)
        #expect(fixture.store.connectivityNotice == nil)
        await fixture.api.setOutage(.cannotFindHost)
        await fixture.store.retryConnection()
        #expect(fixture.store.connectivity == .serviceUnavailable)
        #expect(fixture.store.conversation?.id == "one")
    }

    @Test func `signing out removes the account copy but keeps private conversations`() async throws {
        let fixture = try make(withProvider: true)
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.store.select("one")
        let owner = try #require(fixture.store.cacheOwner)
        fixture.store.newConversation()
        fixture.store.modelRef = Self.localChat
        fixture.store.draft = "Private question"
        await fixture.store.send()
        try await eventually { await fixture.store.cachedContentSize() > 0 }
        await fixture.store.signOut()
        #expect(try await fixture.cache.summaries(owner: owner).isEmpty)
        #expect(fixture.store.localConversations.count == 1)
        #expect(fixture.store.connectivity == .online)
    }

    @Test func `clearing the copy leaves the account signed in`() async throws {
        let fixture = try make()
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.store.select("one")
        let owner = try #require(fixture.store.cacheOwner)
        try await eventually { await fixture.store.cachedContentSize() > 0 }
        await fixture.store.clearCloudCopies()
        #expect(await fixture.store.cachedContentSize() == 0)
        #expect(try await fixture.cache.summaries(owner: owner).isEmpty)
        #expect(fixture.store.isAuthenticated)
        #expect(fixture.store.cloudSyncedAt == nil)
    }

    @Test func `drafts survive switching conversations and relaunching`() async throws {
        let fixture = try make()
        await fixture.store.login(email: "person@example.com", password: "pw")
        fixture.store.draft = "Unsent idea"
        await fixture.store.select("one")
        #expect(fixture.store.draft.isEmpty)
        fixture.store.newConversation()
        try await eventually { fixture.store.draft == "Unsent idea" }

        await fixture.store.setForeground(false)
        let credentials = MemoryCredentials()
        credentials.value = SavedAccount(email: "person@example.com",
                                         session: ChatSession(accessToken: "token", expiresAt: 0, refreshToken: nil))
        let relaunched = try make(credentials: credentials, cache: fixture.cache, local: fixture.local)
        await relaunched.store.restore()
        #expect(relaunched.store.draft == "Unsent idea")
    }

    // MARK: Private conversations

    @Test func `a provider answers privately without an account`() async throws {
        let fixture = try make(withProvider: true)
        await fixture.store.restore()
        #expect(!fixture.store.isAuthenticated)
        #expect(fixture.store.modelRef == Self.localChat)
        #expect(fixture.store.canChooseModel)
        fixture.store.draft = "Hi there"
        #expect(fixture.store.canAttemptSend)
        #expect(fixture.store.canSend)
        await fixture.store.send()
        #expect(!fixture.store.showsLogin)
        let conversation = try #require(fixture.store.conversation)
        #expect(conversation.messages.map(\.role) == ["user", "assistant"])
        #expect(conversation.messages.last?.text == "Hello")
        #expect(conversation.messages.last?.reasoning == "Thinking")
        #expect(conversation.run?.status == "completed")
        #expect(fixture.store.conversationStorage == .local)
        #expect(fixture.store.localConversations.map(\.id) == [conversation.id])
        #expect(fixture.store.draft.isEmpty)
        #expect(fixture.store.modelLabel(for: conversation.messages[1]) == "DeepSeek · deepseek-chat")
        #expect(fixture.store.modelLabel(for: conversation.messages[0]) == nil)
        let request = try #require(await fixture.provider.requests.first)
        #expect(request.apiKey == "sk-test")
        #expect(request.model == "deepseek-chat")
        #expect(request.messages.map(\.text) == ["Hi there"])

        let relaunched = try make(library: fixture.library, local: fixture.local)
        await relaunched.store.restore()
        #expect(relaunched.store.localConversations.map(\.id) == [conversation.id])
        await relaunched.store.select(conversation.id)
        #expect(relaunched.store.conversation?.messages.count == 2)
        #expect(relaunched.store.modelRef == Self.localChat)
        #expect(relaunched.store.sendsLocally)
    }

    @Test func `a provider failure can be tried again`() async throws {
        let provider = ScriptedProvider()
        await provider.setScript([.fail(ChatProviderError.invalidKey)])
        let fixture = try make(provider: provider, withProvider: true)
        await fixture.store.restore()
        fixture.store.draft = "Question"
        await fixture.store.send()
        let failed = try #require(fixture.store.conversation)
        #expect(failed.run?.status == "failed")
        #expect(failed.run?.error == ChatStore.providerMessage(for: ChatProviderError.invalidKey))
        let retry = try #require(fixture.store.regenerableMessageID)
        #expect(retry == failed.messages.last?.id)

        await provider.setScript([.text("Fixed")])
        await fixture.store.regenerate(messageID: retry)
        #expect(fixture.store.conversation?.messages.map(\.text) == ["Question", "Fixed"])
        // Regenerating the answer replaces it.
        await provider.setScript([.text("Again")])
        let answer = try #require(fixture.store.regenerableMessageID)
        await fixture.store.regenerate(messageID: answer)
        #expect(fixture.store.conversation?.messages.map(\.text) == ["Question", "Again"])
        #expect(await provider.requests.last?.messages.map(\.text) == ["Question"])
    }

    @Test func `stopping a private answer keeps what was written`() async throws {
        let provider = ScriptedProvider()
        await provider.setScript([.text("Partial"), .hang])
        let fixture = try make(provider: provider, withProvider: true)
        await fixture.store.restore()
        fixture.store.draft = "Long question"
        let sending = Task { await fixture.store.send() }
        try await eventually { fixture.store.conversation?.run?.preview == "Partial" }
        #expect(fixture.store.isRunning)
        await fixture.store.cancelRun()
        await sending.value
        #expect(fixture.store.conversation?.run?.status == "cancelled")
        #expect(fixture.store.conversation?.messages.last?.text == "Partial")
        #expect(!fixture.store.isRunning)
    }

    @Test func `deleting a private conversation while it answers removes it for good`() async throws {
        let provider = ScriptedProvider()
        await provider.setScript([.text("Partial"), .hang])
        let fixture = try make(provider: provider, withProvider: true)
        await fixture.store.restore()
        fixture.store.draft = "Question"
        let sending = Task { await fixture.store.send() }
        try await eventually { fixture.store.conversation?.run?.preview == "Partial" }
        let id = try #require(fixture.store.selectedID)
        await fixture.store.deleteConversation(id)
        await sending.value
        #expect(fixture.store.localConversations.isEmpty)
        #expect(try await fixture.local.conversation(id: id, owner: ChatStore.localOwner) == nil)
        #expect(fixture.store.selectedID != id)
    }

    @Test func `missing keys and unavailable providers are explained`() async throws {
        let library = ChatModelLibrary.ephemeral()
        try library.save(Self.deepSeek, key: nil)
        let fixture = try make(library: library)
        await fixture.store.restore()
        fixture.store.draft = "Q"
        await fixture.store.send()
        #expect(fixture.store.errorMessage == ChatStore.missingKeyMessage)
        #expect(fixture.store.conversation == nil)
        fixture.store.modelRef = "local:p1/removed"
        #expect(fixture.store.composerValidation == "Choose an available model.")
        #expect(!fixture.store.canSend)
    }

    @Test func `storage decides which models a conversation can continue with`() async throws {
        let fixture = try make(withProvider: true)
        await fixture.store.login(email: "person@example.com", password: "pw")
        await fixture.store.select("one")
        #expect(fixture.store.conversationStorage == .cloud)
        let local = try #require(fixture.library.models.first)
        #expect(!fixture.store.allowsModel(local))
        #expect(!fixture.store.selectModel(local))
        fixture.store.modelRef = local.reference
        #expect(fixture.store.storageIssue != nil)
        #expect(fixture.store.composerValidation == fixture.store.storageIssue)

        fixture.store.newConversation()
        #expect(fixture.store.conversationStorage == nil)
        #expect(fixture.store.selectModel(local))
        fixture.store.draft = "Private"
        await fixture.store.send()
        #expect(fixture.store.conversationStorage == .local)
        let cloud = try #require(fixture.store.models.first)
        #expect(!fixture.store.selectModel(cloud))
        #expect(fixture.store.history(.all).count == 2)
        #expect(fixture.store.history(.local).count == 1)
        #expect(fixture.store.history(.cloud).map(\.id) == ["one"])
        #expect(fixture.store.hasBothStorages)

        let id = try #require(fixture.store.selectedID)
        await fixture.store.deleteConversation(id)
        #expect(fixture.store.localConversations.isEmpty)
        #expect(try await fixture.local.conversation(id: id, owner: ChatStore.localOwner) == nil)
        #expect(fixture.store.conversation == nil)
    }

    @Test func `an answer interrupted by the app ending is marked as failed`() async throws {
        let local = try ChatLocalStore.inMemory()
        let started = ChatLocalConversation.begin(nil, id: "c1", text: "Q", image: nil, modelRef: Self.localChat,
                                                  deviceID: "d")
        try await local.save(started, storage: .local, owner: ChatStore.localOwner)
        let fixture = try make(local: local, withProvider: true)
        await fixture.store.restore()
        await fixture.store.select("c1")
        #expect(fixture.store.conversation?.run?.status == "failed")
        #expect(fixture.store.conversation?.run?.error == ChatStore.interruptedMessage)
        #expect(fixture.store.regenerableMessageID != nil)
    }

    @Test func `private answers keep a photo only for models that accept one`() async throws {
        let fixture = try make(withProvider: true)
        await fixture.store.restore()
        fixture.store.imageDataURL = "data:image/png;base64,AA"
        fixture.store.draft = "What is this?"
        #expect(fixture.store.composerValidation != nil)
        let vision = try #require(fixture.library.models.first { $0.vision == true })
        #expect(fixture.store.selectModel(vision))
        await fixture.store.send()
        #expect(await fixture.provider.requests.last?.messages.first?.image == "data:image/png;base64,AA")
    }

    // MARK: Model choice

    @Test func `the default model starts new conversations and is not replaced`() async throws {
        let fixture = try make(withProvider: true)
        fixture.library.defaultModelRef = "cloud:text-only"
        await fixture.store.restore()
        // Before sign-in the default is unavailable, so the user's own model is used.
        #expect(fixture.store.modelRef == Self.localChat)
        await fixture.store.login(email: "person@example.com", password: "pw")
        #expect(fixture.store.modelRef == "cloud:text-only")
        fixture.store.newConversation()
        #expect(fixture.store.modelRef == "cloud:text-only")
        let balanced = try #require(fixture.store.models.first)
        #expect(fixture.store.selectModel(balanced))
        await fixture.store.refreshHome()
        #expect(fixture.store.modelRef == "cloud:balanced")

        fixture.store.setDefaultModel(Self.localChat)
        #expect(fixture.library.defaultModelRef == Self.localChat)
        #expect(fixture.store.modelRef == Self.localChat)
        fixture.store.setDefaultModel(nil)
        fixture.store.newConversation()
        #expect(fixture.store.modelRef == "cloud:balanced")
    }

    @Test func `reopening a cloud conversation restores its model`() async throws {
        let fixture = try make()
        await fixture.api.setRunModel("cloud:text-only")
        await fixture.store.login(email: "person@example.com", password: "pw")
        #expect(fixture.store.modelRef == "cloud:balanced")
        await fixture.store.select("one")
        #expect(fixture.store.modelRef == "cloud:text-only")
        let message = try #require(fixture.store.conversation?.messages.last)
        #expect(fixture.store.modelLabel(for: message) == "Text")
    }

    @Test func `the library keeps providers, keys and the default`() throws {
        let suite = "test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryProviderKeyStore()
        let library = ChatModelLibrary(defaults: defaults, keys: keys)
        try library.save(Self.deepSeek, key: " sk-1 ")
        library.defaultModelRef = Self.localChat
        #expect(library.key(for: "p1") == "sk-1")
        #expect(library.models.map(\.reference) == [Self.localChat, "local:p1/deepseek-vl"])
        #expect(library.resolve(Self.localChat)?.model.id == "deepseek-chat")
        #expect(library.resolve("local:p1/off") == nil)
        #expect(library.resolve("cloud:x") == nil)

        var renamed = Self.deepSeek
        renamed.name = "Work"
        try library.save(renamed, key: nil)
        #expect(library.key(for: "p1") == "sk-1")
        let reloaded = ChatModelLibrary(defaults: defaults, keys: keys)
        #expect(reloaded.providers.map(\.name) == ["Work"])
        #expect(reloaded.defaultModelRef == Self.localChat)

        try reloaded.save(renamed, key: "")
        #expect(reloaded.key(for: "p1") == nil)
        try reloaded.delete(providerID: "p1")
        #expect(reloaded.providers.isEmpty)
        #expect(reloaded.defaultModelRef == nil)
        #expect(reloaded.provider(id: "p1") == nil)
    }

    @Test func `provider keys round-trip through the Keychain`() throws {
        let keys = KeychainProviderKeyStore(service: "app.typeflux.ios.tests." + UUID().uuidString)
        defer { try? keys.delete(id: "p1") }
        #expect(try keys.load(id: "p1") == nil)
        try keys.save("sk-first", id: "p1")
        #expect(try keys.load(id: "p1") == "sk-first")
        try keys.save("sk-second", id: "p1")
        #expect(try keys.load(id: "p1") == "sk-second")
        try keys.delete(id: "p1")
        #expect(try keys.load(id: "p1") == nil)
        try keys.delete(id: "p1")
    }

    @Test func `provider failures are written as sentences`() {
        let errors: [Error] = [ChatProviderError.invalidKey, ChatProviderError.missingKey, ChatProviderError.notFound,
                               ChatProviderError.rateLimited, ChatProviderError.redirected,
                               ChatProviderError.invalidEndpoint, ChatProviderError.server(status: 500),
                               URLError(.notConnectedToInternet), URLError(.cannotConnectToHost)]
        let messages = errors.map(ChatStore.providerMessage(for:))
        #expect(Set(messages).count == messages.count - 0)
        #expect(messages.allSatisfy { $0.hasSuffix(".") && !$0.contains("500") })
    }
}

// MARK: - Connection notice preferences

@MainActor
extension ChatOfflineTests {
    @Test func `connection notice dismissal lasts exactly 24 hours across launches`() async throws {
        let domain = "ChatConnectivityTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        func store(synthetic: Bool = false) -> ChatStore {
            ChatStore(service: OutageAPI(), credentials: MemoryCredentials(), deviceID: "test",
                      isSynthetic: synthetic, noticeDefaults: defaults)
        }
        let first = store()
        await first.login(email: "person@example.com", password: "pw")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!first.showsConnectivityNotice(at: start))
        first.connectivity = .serviceUnavailable
        #expect(first.showsConnectivityNotice(at: start))
        first.dismissConnectivityNotice(at: start)
        #expect(!first.showsConnectivityNotice(at: start))
        #expect(!first.showsConnectivityNotice(at: start.addingTimeInterval(86_399)))
        #expect(first.showsConnectivityNotice(at: start.addingTimeInterval(86_400)))
        #expect(first.showsConnectivityNotice(at: start.addingTimeInterval(-1)))
        let restored = store()
        #expect(restored.connectivityNoticeDismissedAt == start)
        await restored.login(email: "person@example.com", password: "pw")
        restored.connectivity = .offline
        #expect(!restored.showsConnectivityNotice(at: start.addingTimeInterval(60)))
        restored.noteUnsent(.serviceUnavailable)
        #expect(restored.errorMessage == ChatStore.unavailableMessage)
        #expect(!restored.showsConnectivityNotice(at: start.addingTimeInterval(60)))
        restored.markOnline()
        restored.connectivity = .serviceUnavailable
        #expect(!restored.showsConnectivityNotice(at: start.addingTimeInterval(60)))
        let preview = store(synthetic: true)
        #expect(preview.connectivityNoticeDismissedAt == nil)
        preview.dismissConnectivityNotice(at: start.addingTimeInterval(100))
        #expect(store().connectivityNoticeDismissedAt == start)
        #expect(!store().showsConnectivityNotice(at: start.addingTimeInterval(86_400)))
    }

    @Test func `private models cannot select reasoning levels`() throws {
        let fixture = try make(withProvider: true)
        fixture.store.modelRef = Self.localChat
        #expect(fixture.store.sendsLocally)
        #expect(fixture.store.supportedReasoningLevels.isEmpty)
        fixture.store.selectReasoningEffort(.high)
        #expect(fixture.store.reasoningEffort == .providerDefault)
    }
}

// MARK: - Test doubles

/// A Typeflux API whose network can be cut.
actor OutageAPI: ChatAPI {
    private var outage: URLError.Code?
    private var failure: Error?
    private var runModel: String?
    private(set) var sendAttempts = 0
    private var revision: Int64 = 1

    func setOutage(_ code: URLError.Code?) { outage = code }
    func setFailure(_ error: Error?) { failure = error }
    func setRunModel(_ reference: String?) { runModel = reference }
    private var sendOutage: URLError.Code?
    func setSendOutage(_ code: URLError.Code?) { sendOutage = code }

    private func check() throws {
        if let outage { throw URLError(outage) }
        if let failure { throw failure }
    }

    private var document: ChatConversation {
        ChatConversation(id: "one", title: "A conversation", revision: revision,
                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                         messages: [ChatMessage(id: "q", role: "user", text: "Cached question"),
                                    ChatMessage(id: "a", role: "assistant", text: "Answer")],
                         run: ChatRun(id: "r", deviceId: "mac", status: "completed", modelRef: runModel))
    }

    func login(email _: String, password _: String) async throws -> ChatSession {
        try check()
        return ChatSession(accessToken: "token", expiresAt: 0, refreshToken: "refresh")
    }

    func refresh(refreshToken _: String) async throws -> ChatSession {
        ChatSession(accessToken: "token", expiresAt: 0, refreshToken: "refresh")
    }

    func logout(refreshToken _: String) async throws {}

    func models(token _: String) async throws -> [ChatModel] {
        try check()
        return [ChatModel(id: "balanced", name: "Balanced", vision: true, reasoning: true),
                ChatModel(id: "text-only", name: "Text", vision: false)]
    }

    func list(token _: String, offset _: Int) async throws -> [ChatConversationSummary] {
        try check()
        return [ChatConversationSummary(id: "one", title: "A conversation",
                                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
    }

    func conversation(id _: String, token _: String) async throws -> ChatConversation {
        try check()
        return document
    }

    func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
        sendAttempts += 1
        try check()
        if let sendOutage { throw URLError(sendOutage) }
        revision += 1
        return ChatConversation(id: conversationId, title: "New", revision: revision,
                                messages: [ChatMessage(id: request.id, role: "user", text: request.text)])
    }

    func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
        document
    }

    func observe(id _: String, token _: String,
                 onValue _: @concurrent @Sendable (ChatConversation) async throws -> Void) async throws {}

    func profile(token _: String) async throws -> ChatProfile {
        try check()
        return ChatProfile(id: "test-user", email: "person@example.com")
    }

    func aiDisclosure(token _: String) async throws -> ChatAIDisclosure {
        try check()
        return ChatAIDisclosure(version: "test", providers: ["Test Provider"])
    }
}

/// A provider that answers from a script.
actor ScriptedProvider: ChatProviderService {
    enum Step: Sendable {
        case text(String)
        case fail(ChatProviderError)
        case hang
    }

    private var script: [Step] = [.text("Hel"), .text("lo")]
    private(set) var requests: [ChatProviderRequest] = []

    /// Scripts used once each, in order, before falling back to `script`.
    private var queue: [[Step]] = []

    func setScript(_ steps: [Step]) { script = steps }
    func enqueue(_ scripts: [[Step]]) { queue += scripts }

    private func begin(_ request: ChatProviderRequest) -> [Step] {
        requests.append(request)
        return queue.isEmpty ? script : queue.removeFirst()
    }

    nonisolated func models(provider _: ChatProvider, apiKey _: String?) async throws -> [ChatProviderModel] {
        [ChatProviderModel(id: "deepseek-chat")]
    }

    nonisolated func stream(_ request: ChatProviderRequest) -> AsyncThrowingStream<ChatProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let steps = await self.begin(request)
                if case .text = steps.first {
                    continuation.yield(.reasoning("Thinking"))
                }
                for step in steps {
                    switch step {
                    case let .text(value):
                        continuation.yield(.text(value))
                    case let .fail(error):
                        continuation.finish(throwing: error)
                        return
                    case .hang:
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
