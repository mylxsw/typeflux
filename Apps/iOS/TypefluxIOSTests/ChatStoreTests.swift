// swiftlint:disable file_length
import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Mobile session and chat lifecycle")
struct ChatStoreTests {
    @Test func `login loads history and cloud model`() async {
        let (store, _, credentials) = makeStore()
        await store.login(email: "person@example.com", password: "password")
        #expect(store.isAuthenticated)
        #expect(store.conversations.map(\.id) == ["one"])
        #expect(store.modelRef == "cloud:balanced")
        #expect(credentials.value?.email == "person@example.com")
    }

    @Test func `restore loads saved session without login`() async {
        let (store, api, credentials) = makeStore()
        credentials.value = account("valid")
        await store.restore()
        #expect(store.isAuthenticated)
        #expect(await api.loginCount == 0)
        await store.restore()
        #expect(await api.listCount == 1)
    }

    @Test func `missing credentials remain signed out`() async {
        let (store, _, _) = makeStore()
        await store.restore()
        #expect(!store.isAuthenticated)
        #expect(store.errorMessage == nil)
        await store.refreshHome()
        await store.loadMore()
        await store.reloadConversation()
        await store.cancelRun()
    }

    @Test func `failed login clears previous saved account`() async {
        let (store, api, credentials) = makeStore()
        credentials.value = account("valid")
        await api.rejectLogin()
        await store.login(email: "new@example.com", password: "wrong")
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
        #expect(store.errorMessage == "Please check your email and password.")
    }

    @Test func `refresh on 401 persists rotated credentials`() async {
        let (store, api, credentials) = makeStore()
        credentials.value = account("expired")
        await store.restore()
        #expect(store.isAuthenticated)
        #expect(await api.refreshCount == 1)
        #expect(credentials.value?.accessToken == "fresh")
        #expect(credentials.value?.refreshToken == "rotated")
    }

    @Test func `expired refresh returns to login and clears history`() async {
        let (store, api, credentials) = makeStore()
        credentials.value = account("expired")
        await api.rejectRefresh()
        await store.restore()
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
        #expect(store.conversations.isEmpty)
        #expect(store.errorMessage?.contains("expired") == true)
    }

    @Test func `expired account without refresh token returns to login`() async {
        let (store, _, credentials) = makeStore()
        credentials.value = SavedAccount(
            email: "user@example.com",
            session: ChatSession(accessToken: "expired", expiresAt: 0, refreshToken: nil)
        )
        await store.restore()
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
    }

    @Test func `concurrent 401 s share one refresh`() async throws {
        let (store, api, credentials) = makeStore()
        credentials.value = account("expired")
        await api.pauseRefresh()
        let first = Task { await store.restore() }
        try await eventually { await api.refreshCount == 1 }
        let second = Task { await store.refreshHome() }
        try await eventually { await api.listCount >= 2 }
        await api.completeRefresh()
        await first.value
        await second.value
        #expect(await api.refreshCount == 1)
        #expect(store.isAuthenticated)
    }

    @Test func `signing out during refresh does not restore account`() async throws {
        let (store, api, credentials) = makeStore()
        credentials.value = account("expired")
        await api.pauseRefresh()
        let restore = Task { await store.restore() }
        try await eventually { await api.refreshCount == 1 }
        await store.signOut()
        await api.completeRefresh()
        await restore.value
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
        #expect(store.conversations.isEmpty)
    }

    @Test func `old conversation response cannot enter new account`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "old@example.com", password: "password")
        await api.pauseConversation()
        let select = Task { await store.select("one") }
        try await eventually { await api.waitingForConversation }
        await store.login(email: "new@example.com", password: "password")
        await api.completeConversation()
        await select.value
        #expect(store.email == "new@example.com")
        #expect(store.conversation == nil)
        #expect(store.selectedID == nil)
    }

    @Test func `switching conversation ignores old response`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "old@example.com", password: "password")
        await api.pauseConversation()
        let select = Task { await store.select("one") }
        try await eventually { await api.waitingForConversation }
        store.newConversation()
        let selected = store.selectedID
        await api.completeConversation()
        await select.value
        #expect(store.conversation == nil)
        #expect(store.selectedID == selected)
    }

    @Test func `text send uses persistent device and clears composer`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.draft = "  Hello  "
        store.imageDataURL = "data:image/jpeg;base64,synthetic"
        await store.send()
        let requests = await api.sentRequests
        #expect(requests.count == 1)
        #expect(requests.first?.deviceId == "ios-test")
        #expect(requests.first?.text == "Hello")
        #expect(requests.first?.modelRef == "cloud:balanced")
        #expect(requests.first?.tools == [])
        #expect(requests.first?.platform == "iOS")
        #expect(store.draft.isEmpty)
        #expect(store.imageDataURL == nil)
        #expect(!store.isSending)
        #expect(store.conversation?.messages.last?.text == "Hello")
    }

    @Test func `empty draft does not send`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.draft = " \n "
        await store.send()
        #expect(await api.sentRequests.isEmpty)
    }

    @Test func `composer validates UTF 8 byte limit and photo model`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.draft = String(repeating: "文", count: 10667)
        #expect(!store.canSend)
        #expect(store.composerValidation?.contains("32 KB") == true)
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        store.draft = "Describe this"
        store.imageDataURL = "synthetic"
        store.modelRef = "cloud:text-only"
        #expect(!store.canSend)
        #expect(store.composerValidation?.contains("photos") == true)
        store.modelRef = "cloud:balanced"
        #expect(store.canSend)
    }

    @Test func `foreground recovery never resends message`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.draft = "Hello"
        await store.send()
        await store.setForeground(false)
        await store.setForeground(true)
        #expect(await api.sentRequests.count == 1)
        #expect(await api.conversationCount == 1)
    }

    @Test func `failed send reloads without automatic post retry`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.failSend()
        store.draft = "Hello"
        await store.send()
        #expect(await api.sentRequests.count == 1)
        #expect(await api.conversationCount == 1)
        #expect(!store.isSending)
        #expect(store.draft.isEmpty)
        #expect(store.errorMessage == nil)
        await store.send()
        #expect(await api.sentRequests.count == 1)
    }

    @Test func `cancelling refresh caller still persists rotated token`() async throws {
        let (store, api, credentials) = makeStore()
        credentials.value = account("expired")
        await api.pauseRefresh()
        let restore = Task { await store.restore() }
        try await eventually { await api.refreshCount == 1 }
        restore.cancel()
        await api.completeRefresh()
        await restore.value
        #expect(store.isAuthenticated)
        #expect(credentials.value?.refreshToken == "rotated")
        await store.refreshHome()
        #expect(await api.refreshCount == 1)
    }

    @Test func `stream EOF reconnects snapshot without sending again`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setActiveRun()
        await api.dropFirstStream()
        await store.select("one")
        try await eventually { await MainActor.run { store.conversation?.revision == 5 } }
        #expect(await api.observeCount == 2)
        #expect(await api.conversationCount == 2)
        #expect(await api.sentRequests.isEmpty)
    }

    @Test func `healthy stream EO fs do not exhaust failure budget`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setActiveRun()
        await api.dropStreams(6)
        await store.select("one")
        try await eventually { await MainActor.run { store.conversation?.revision == 5 } }
        #expect(await api.observeCount == 7)
        #expect(store.errorMessage == nil)
    }

    @Test func `persistent stream errors stop after three retries`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setActiveRun()
        await api.failStreams(10)
        await store.select("one")
        try await eventually { await MainActor.run { store.errorMessage != nil } }
        #expect(await api.observeCount == 4)
        #expect(store.errorMessage?.contains("Refresh") == true)
        #expect(await api.sentRequests.isEmpty)
    }

    @Test func `failed model can be changed without reusing old request`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.rejectNextSend()
        await api.failConversationFetch()
        store.draft = "Hello"
        await store.send()
        #expect(store.draft == "Hello")
        #expect(store.errorMessage == "Choose another model.")
        store.modelRef = "cloud:text-only"
        await store.send()
        let requests = await api.sentRequests
        #expect(requests.count == 2)
        #expect(requests.first?.modelRef == "cloud:balanced")
        #expect(requests.last?.modelRef == "cloud:text-only")
        #expect(requests.first?.id != requests.last?.id)
    }

    @Test func `uncertain send retries with same message identity`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.loseNextSend()
        store.draft = "Hello"
        await store.send()
        #expect(store.draft == "Hello")
        await store.send()
        let requests = await api.sentRequests
        #expect(requests.count == 2)
        #expect(requests.first?.id == requests.last?.id)
        #expect(store.draft.isEmpty)
    }

    @Test func `confirmed send unlocks composer before history refresh finishes`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.pauseNextList()
        store.draft = "First message"
        let send = Task { await store.send() }
        try await eventually { await api.waitingForList }
        #expect(!store.isSending)
        store.draft = "Second message"
        #expect(store.canSend)
        await api.completeList()
        await send.value
        #expect(store.draft == "Second message")
    }

    @Test func `terminal run can be cancelled and new turn enabled`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await store.setForeground(false)
        await api.setActiveRun()
        await store.select("one")
        store.draft = "Next"
        #expect(!store.canSend)
        await store.cancelRun()
        #expect(await api.cancelCount == 1)
        #expect(store.conversation?.run?.status == "cancelled")
        #expect(store.canSend)
    }

    @Test func `stream rejects stale revisions and publishes final snapshot`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setActiveRun()
        await store.select("one")
        try await eventually { await MainActor.run { store.conversation?.revision == 5 } }
        #expect(store.conversation?.messages.last?.text == "Final")
        #expect(!store.isRunning)
        #expect(await api.observeCount == 1)
    }

    @Test func `pagination removes duplicates and stops at empty page`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setExtraPage()
        await store.loadMore()
        #expect(store.conversations.map(\.id) == ["one", "two"])
        await store.loadMore()
        #expect(!store.hasMore)
        await store.loadMore()
        #expect(await api.listCount == 3)
    }

    @Test func `signing out clears all per account content`() async {
        let (store, api, credentials) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await store.select("one")
        store.draft = "Private text"
        store.imageDataURL = "Private image"
        await store.signOut()
        #expect(!store.isAuthenticated)
        #expect(store.conversations.isEmpty)
        #expect(store.models.isEmpty)
        #expect(store.conversation == nil)
        #expect(store.draft.isEmpty)
        #expect(store.imageDataURL == nil)
        #expect(credentials.value == nil)
        #expect(await api.logoutCount == 1)
    }

    @Test func `secure storage failure does not authenticate`() async {
        let (store, _, credentials) = makeStore()
        credentials.failSave = true
        await store.login(email: "user@example.com", password: "password")
        #expect(!store.isAuthenticated)
        #expect(store.errorMessage != nil)
    }
}

private extension ChatStoreTests {
    // A fixture groups the subject with its two independent test doubles.
    // swiftlint:disable:next large_tuple
    func makeStore() -> (ChatStore, FakeChatAPI, MemoryCredentials) {
        let api = FakeChatAPI()
        let credentials = MemoryCredentials()
        return (
            ChatStore(service: api, credentials: credentials, deviceID: "ios-test", reconnectDelay: .milliseconds(1)),
            api,
            credentials
        )
    }

    private func account(_ token: String) -> SavedAccount {
        SavedAccount(
            email: "saved@example.com",
            session: ChatSession(accessToken: token, expiresAt: 0, refreshToken: "refresh")
        )
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the test operation")
    }
}

@MainActor
final class MemoryCredentials: CredentialStore {
    var value: SavedAccount?
    var failSave = false
    func load() throws -> SavedAccount? {
        value
    }

    func save(_ account: SavedAccount) throws {
        if failSave {
            throw CocoaError(.fileWriteNoPermission)
        }
        value = account
    }

    func clear() throws {
        value = nil
    }
}

private actor FakeChatAPI: ChatAPI {
    var loginCount = 0
    var listCount = 0
    var refreshCount = 0
    var logoutCount = 0
    var conversationCount = 0
    var cancelCount = 0
    var observeCount = 0
    var sentRequests: [ChatSendRequest] = []
    var waitingForConversation: Bool {
        conversationContinuation != nil
    }

    var waitingForList: Bool {
        listContinuation != nil
    }

    var document = ChatConversation(id: "one", title: "A conversation", revision: 1)
    private var loginRejected = false
    private var refreshRejected = false
    private var refreshPaused = false
    private var conversationPaused = false
    private var sendFails = false
    private var extraPage = false
    private var emptyStreams = 0
    private var failingStreams = 0
    private var nextSendRejected = false
    private var nextSendLost = false
    private var conversationFails = false
    private var listPaused = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var conversationContinuation: CheckedContinuation<Void, Never>?
    private var listContinuation: CheckedContinuation<Void, Never>?

    func rejectLogin() {
        loginRejected = true
    }

    func rejectRefresh() {
        refreshRejected = true
    }

    func pauseRefresh() {
        refreshPaused = true
    }

    func completeRefresh() {
        refreshContinuation?.resume(); refreshContinuation = nil
    }

    func pauseConversation() {
        conversationPaused = true
    }

    func completeConversation() {
        conversationContinuation?.resume(); conversationContinuation = nil
    }

    func failSend() {
        sendFails = true
    }

    func setExtraPage() {
        extraPage = true
    }

    func dropFirstStream() {
        emptyStreams = 1
    }

    func dropStreams(_ count: Int) {
        emptyStreams = count
    }

    func failStreams(_ count: Int) {
        failingStreams = count
    }

    func rejectNextSend() {
        nextSendRejected = true
    }

    func loseNextSend() {
        nextSendLost = true
    }

    func failConversationFetch() {
        conversationFails = true
    }

    func pauseNextList() {
        listPaused = true
    }

    func completeList() {
        listContinuation?.resume(); listContinuation = nil
    }

    func setActiveRun() {
        document.run = ChatRun(id: "run", deviceId: "mac", status: "running")
    }

    func login(email _: String, password _: String) async throws -> ChatSession {
        loginCount += 1
        if loginRejected {
            throw ChatAPIError.unauthorized
        }
        return ChatSession(accessToken: "valid", expiresAt: 0, refreshToken: "refresh")
    }

    func refresh(refreshToken _: String) async throws -> ChatSession {
        refreshCount += 1
        if refreshPaused {
            await withCheckedContinuation { refreshContinuation = $0 }
        }
        if refreshRejected {
            throw ChatAPIError.unauthorized
        }
        return ChatSession(accessToken: "fresh", expiresAt: 0, refreshToken: "rotated")
    }

    func logout(refreshToken _: String) async throws {
        logoutCount += 1
    }

    func models(token _: String) async throws -> [ChatModel] {
        [
            ChatModel(id: "balanced", name: "Balanced", vision: true),
            ChatModel(id: "text-only", name: "Text", vision: false)
        ]
    }

    func list(token: String, offset: Int) async throws -> [ChatConversationSummary] {
        listCount += 1
        if listPaused {
            listPaused = false
            await withCheckedContinuation { listContinuation = $0 }
        }
        if token == "expired" {
            throw ChatAPIError.unauthorized
        }
        let first = ChatConversationSummary(id: "one", title: "A conversation")
        if offset == 0 {
            return [first]
        }
        if offset == 1, extraPage {
            return [first, ChatConversationSummary(id: "two", title: "Second")]
        }
        return []
    }

    func conversation(id _: String, token _: String) async throws -> ChatConversation {
        conversationCount += 1
        if conversationFails {
            throw ChatAPIError.server(code: "NOT_FOUND", message: "Conversation not found")
        }
        if conversationPaused {
            await withCheckedContinuation { conversationContinuation = $0 }
        }
        return document
    }

    func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
        sentRequests.append(request)
        if nextSendRejected {
            nextSendRejected = false
            throw ChatAPIError.server(code: "MODEL_UNAVAILABLE", message: "Choose another model.")
        }
        if nextSendLost {
            nextSendLost = false
            throw URLError(.networkConnectionLost)
        }
        document.id = conversationId
        document.messages.append(ChatMessage(id: request.id, role: "user", text: request.text))
        document.revision += 1
        if sendFails {
            throw URLError(.networkConnectionLost)
        }
        return document
    }

    func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
        cancelCount += 1
        document.run?.status = "cancelled"
        document.revision += 1
        return document
    }

    func observe(
        id _: String,
        token _: String,
        onValue: @concurrent @Sendable (ChatConversation) async throws -> Void
    ) async throws {
        observeCount += 1
        if emptyStreams > 0 {
            emptyStreams -= 1; return
        }
        if failingStreams > 0 {
            failingStreams -= 1; throw URLError(.networkConnectionLost)
        }
        var snapshot = document
        snapshot.revision = 3
        snapshot.run?.preview = "Partial"
        try await onValue(snapshot)
        snapshot.revision = 2
        try await onValue(snapshot)
        snapshot.revision = 5
        snapshot.run?.status = "completed"
        snapshot.messages.append(ChatMessage(id: "final", role: "assistant", text: "Final"))
        try await onValue(snapshot)
    }
}
