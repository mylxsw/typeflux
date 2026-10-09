// swiftlint:disable file_length
import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Mobile session and chat lifecycle")
struct ChatStoreTests {
    @Test func `editing while disclosure refreshes requires another explicit send`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.pausePrivacy()
        store.draft = "Original"
        let sending = Task { await store.send() }
        try await eventually { await api.waitingForPrivacy }
        store.draft = "Edited while checking"
        await api.resumePrivacy()
        await sending.value
        #expect(await api.sentRequests.isEmpty)
        #expect(store.draft == "Edited while checking")
    }

    @Test func `guest can compose and sending asks for login without a request`() async {
        let (store, api, _) = makeStore(consented: false)
        store.draft = "Keep this draft"
        store.imageDataURL = "data:image/png;base64,local"
        #expect(store.canAttemptSend)
        #expect(!store.canSend)
        await store.send()
        #expect(store.showsLogin)
        #expect(await api.sentRequests.isEmpty)
        #expect(await api.loginCount == 0)
        #expect(store.draft == "Keep this draft")
        store.cancelPendingLogin()
        #expect(store.imageDataURL == "data:image/png;base64,local")
    }

    @Test func `login and consent preserve draft and require a separate send`() async {
        let (store, api, _) = makeStore(consented: false)
        store.draft = "Review me"
        store.imageDataURL = "data:image/png;base64,local"
        await store.login(email: "user@example.com", password: "password")
        #expect(store.showsConsent)
        #expect(store.draft == "Review me")
        #expect(store.imageDataURL != nil)
        #expect(!store.hasAIConsent)
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        store.acceptAIConsent()
        #expect(store.hasAIConsent)
        #expect(await api.sentRequests.isEmpty)
        await store.send()
        #expect(await api.sentRequests.count == 1)
    }

    @Test func `withdrawal and changed recipients prevent sending`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.draft = "Private"
        store.revokeAIConsent()
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        store.acceptAIConsent()
        await api.changePrivacy(version: "updated")
        await store.send()
        #expect(!store.hasAIConsent)
        #expect(await api.sentRequests.isEmpty)
        #expect(store.draft == "Private")
    }

    @Test func `unavailable disclosure fails closed`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.disablePrivacy()
        store.draft = "Private"
        await store.send()
        store.acceptAIConsent()
        #expect(!store.hasAIConsent)
        #expect(await api.sentRequests.isEmpty)
    }

    @Test func `failed deletion retains account and successful deletion clears everything`() async {
        let (store, api, credentials) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        #expect(await store.deleteAccount(proof: .init(provider: "password", password: "proof")))
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
        #expect(store.conversations.isEmpty)
        #expect(!store.hasAIConsent)
        #expect(await api.deletedAccounts == 1)
        let (other, rejected, saved) = makeStore()
        await other.login(email: "user@example.com", password: "password")
        await rejected.rejectDeletion()
        #expect(await !other.deleteAccount(proof: .init(provider: "password", password: "proof")))
        #expect(other.isAuthenticated)
        #expect(saved.value != nil)
        #expect(other.errorMessage != nil)
    }

    @Test func `report sends only the selected answer after explicit submission`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await store.select("one")
        let wrong = ChatMessage(id: "not-in-conversation", role: "assistant", text: "example")
        #expect(await !store.reportAnswer(message: wrong, reason: "unsafe", details: ""))
        #expect(await api.reports.isEmpty)
    }

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
}

extension ChatStoreTests {
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

extension ChatStoreTests {
    @Test func `login displays and saves the email actually sent to the server`() async {
        let (store, api, credentials) = makeStore()
        await store.login(email: "  Person@example.com\n", password: "password")
        #expect(await api.loginEmails == ["Person@example.com"])
        #expect(store.email == "Person@example.com")
        #expect(credentials.value?.email == "Person@example.com")
    }

    @Test func `confirmed send preserves a new draft and image prepared during the request`() async throws {
        for uncertainResponse in [false, true] {
            let (store, api, _) = makeStore()
            await store.login(email: "user@example.com", password: "password")
            await api.pauseNextSend()
            if uncertainResponse {
                await api.failSend()
            }
            store.draft = " First message "
            store.imageDataURL = "first-image"
            let sending = Task { await store.send() }
            try await eventually { await api.waitingForSend }
            #expect(store.isBusy)
            #expect(try !store.selectModel(#require(store.models.last)))
            store.selectReasoningEffort(.high)
            #expect(store.reasoningEffort == .providerDefault)
            store.draft = "Second message"
            store.imageDataURL = "second-image"
            await api.completeSend()
            await sending.value
            #expect(store.draft == "Second message")
            #expect(store.imageDataURL == "second-image")
            #expect(!store.isSending)
            #expect(await api.sentRequests.count == 1)
            #expect(store.conversation?.messages.last?.text == "First message")
            #expect(store.errorMessage == nil)
        }
    }

    @Test func `late send response cannot clear the next conversation draft`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.pauseNextSend()
        store.draft = "Old question"
        let sending = Task { await store.send() }
        try await eventually { await api.waitingForSend }
        store.newConversation()
        let selected = store.selectedID
        store.draft = "New question"
        await api.completeSend()
        await sending.value
        #expect(store.selectedID == selected)
        #expect(store.conversation == nil)
        #expect(store.draft == "New question")
        #expect(!store.isSending)
    }

    @Test func `late send response cannot enter a new account`() async throws {
        let (store, api, credentials) = makeStore()
        await store.login(email: "old@example.com", password: "password")
        await api.pauseNextSend()
        store.draft = "Private old account message"
        let sending = Task { await store.send() }
        try await eventually { await api.waitingForSend }
        await store.signOut()
        await store.login(email: "new@example.com", password: "password")
        store.draft = "New account question"
        await api.completeSend()
        await sending.value
        #expect(store.email == "new@example.com")
        #expect(credentials.value?.email == "new@example.com")
        #expect(store.conversation == nil)
        #expect(store.selectedID == nil)
        #expect(store.draft == "New account question")
        #expect(store.errorMessage == nil)
    }

    @Test func `history must load before sending or validating photo compatibility`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.setMessages([ChatMessage(id: "photo", role: "user", text: "Describe", image: "synthetic")])
        await api.pauseConversation()
        let selection = Task { await store.select("one") }
        try await eventually { await api.waitingForConversation }
        #expect(store.isLoadingConversation)
        store.modelRef = "cloud:text-only"
        store.draft = "Follow up"
        #expect(!store.canSend)
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        await api.completeConversation()
        await selection.value
        #expect(!store.isLoadingConversation)
        #expect(store.hasConversationImages)
        #expect(!store.canSend)
        #expect(store.composerValidation?.contains("conversation contains photos") == true)
    }

    @Test func `failed history load stays unsendable until reload or a new conversation`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.failConversationFetch()
        await store.select("one")
        store.draft = "Follow up"
        #expect(!store.isLoadingConversation)
        #expect(!store.canSend)
        #expect(store.errorMessage != nil)
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        await api.allowConversationFetch()
        await store.reloadConversation()
        #expect(store.canSend)
        #expect(store.errorMessage == nil)
        await api.failConversationFetch()
        await store.select("one")
        store.newConversation()
        store.draft = "New question"
        #expect(store.canSend)
    }

    @Test func `reasoning choice reaches the actual request and auto omits the parameter`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        #expect(store.selectedModelID == "balanced")
        #expect(store.supportedReasoningLevels == [.low, .medium, .high])
        store.selectReasoningEffort(.high)
        store.draft = "Think through this"
        await store.send()
        let request = try #require(await api.sentRequests.first)
        let body = try #require(JSONSerialization
            .jsonObject(with: ChatCoding.encoder().encode(request)) as? [String: Any])
        #expect(body["reasoning_effort"] as? String == "high")
        store.selectReasoningEffort(.providerDefault)
        store.draft = "Use your default"
        await store.send()
        let automatic = try #require(await api.sentRequests.last)
        let autoBody = try #require(JSONSerialization
            .jsonObject(with: ChatCoding.encoder().encode(automatic)) as? [String: Any])
        #expect(!autoBody.keys.contains("reasoning_effort"))
    }

    @Test func `model changes clamp reasoning to closest supported level`() async throws {
        let (store, api, _) = makeStore()
        await api.setModels([
            ChatModel(id: "balanced", name: "Balanced", reasoning: true),
            ChatModel(id: "advanced", name: "Advanced", reasoning: true, reasoningEfforts: ["low", "max"]),
            ChatModel(id: "plain", name: "Plain", reasoning: false)
        ])
        await store.login(email: "user@example.com", password: "password")
        store.selectReasoningEffort(.high)
        #expect(try store.selectModel(#require(store.models.first { $0.id == "advanced" })))
        #expect(store.reasoningEffort == .low)
        store.selectReasoningEffort(.max)
        store.modelRef = "cloud:balanced"
        #expect(store.reasoningEffort == .high)
        store.modelRef = "cloud:plain"
        #expect(store.reasoningEffort == .providerDefault)
        #expect(store.supportedReasoningLevels.isEmpty)
        store.selectReasoningEffort(.max)
        #expect(store.reasoningEffort == .providerDefault)
        #expect(!store.selectModel(ChatModel(id: "unavailable", name: "Unavailable")))
    }

    @Test func `catalog refresh clamps effort even when model reference is unchanged`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.selectReasoningEffort(.high)
        await api.setModels([ChatModel(id: "balanced", name: "Balanced", reasoning: true, reasoningEfforts: ["low"])])
        await store.refreshHome()
        #expect(store.modelRef == "cloud:balanced")
        #expect(store.reasoningEffort == .low)
        await api.setModels([ChatModel(id: "replacement", name: "Replacement", reasoning: false)])
        await store.refreshHome()
        #expect(store.modelRef == "cloud:replacement")
        #expect(store.reasoningEffort == .providerDefault)
    }

    @Test func `photos keep incompatible models visible but prevent choosing or sending them`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        store.imageDataURL = "synthetic"
        store.draft = "Describe this"
        let textOnly = try #require(store.models.first { $0.id == "text-only" })
        #expect(store.hasConversationImages)
        #expect(!store.selectModel(textOnly))
        #expect(store.selectedModelID == "balanced")
        // Selection validates the catalog entry, not capability claims from a stale picker.
        #expect(!store.selectModel(ChatModel(id: "text-only", name: "Text", vision: true)))
        store.modelRef = textOnly.reference
        await store.send()
        #expect(await api.sentRequests.isEmpty)
        store.imageDataURL = nil
        #expect(!store.hasConversationImages)
        #expect(store.selectModel(textOnly))
        #expect(store.canSend)
    }

    @Test func `photos in conversation history require vision for every follow up`() async throws {
        for message in [
            ChatMessage(id: "photo", role: "user", text: "Describe", image: "synthetic"),
            ChatMessage(id: "attachment", role: "user", text: "Describe", attachments: [.init(kind: "image")])
        ] {
            let (store, api, _) = makeStore()
            await store.login(email: "user@example.com", password: "password")
            await api.setMessages([message])
            await store.select("one")
            #expect(store.hasConversationImages)
            #expect(store.imageDataURL == nil)
            let textOnly = try #require(store.models.first { $0.id == "text-only" })
            #expect(!store.selectModel(textOnly))
            store.modelRef = textOnly.reference
            store.draft = "What else?"
            #expect(store.composerValidation?.contains("conversation contains photos") == true)
            await store.send()
            #expect(await api.sentRequests.isEmpty)
            store.newConversation()
            #expect(!store.hasConversationImages)
            #expect(store.selectModel(textOnly))
        }
    }

    @Test func `active runs prevent model and reasoning changes`() async throws {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await store.setForeground(false)
        await api.setActiveRun()
        await store.select("one")
        #expect(store.isBusy)
        #expect(try !store.selectModel(#require(store.models.first { $0.id == "text-only" })))
        store.selectReasoningEffort(.high)
        #expect(store.reasoningEffort == .providerDefault)
        await store.cancelRun()
        #expect(!store.isBusy)
        store.selectReasoningEffort(.high)
        #expect(store.reasoningEffort == .high)
    }

    @Test func `new conversations and account changes isolate model and reasoning choices`() async {
        let (store, _, _) = makeStore()
        await store.login(email: "first@example.com", password: "password")
        store.selectReasoningEffort(.high)
        store.newConversation()
        #expect(store.reasoningEffort == .providerDefault)
        store.modelRef = "cloud:text-only"
        store.newConversation()
        #expect(store.modelRef == "cloud:balanced")
        store.selectReasoningEffort(.high)
        await store.select("one")
        #expect(store.reasoningEffort == .providerDefault)
        store.selectReasoningEffort(.high)
        await store.login(email: "second@example.com", password: "password")
        #expect(store.reasoningEffort == .providerDefault)
        #expect(store.modelRef == "cloud:balanced")
        store.selectReasoningEffort(.high)
        await store.signOut()
        #expect(store.reasoningEffort == .providerDefault)
        #expect(store.selectedModel == nil)
        #expect(store.supportedReasoningLevels.isEmpty)
    }

    @Test func `changing effort after failed send creates a new request identity`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "user@example.com", password: "password")
        await api.loseNextSend()
        store.selectReasoningEffort(.low)
        store.draft = "Hello"
        await store.send()
        #expect(store.draft == "Hello")
        store.selectReasoningEffort(.high)
        await store.send()
        let requests = await api.sentRequests
        #expect(requests.count == 2)
        #expect(requests.first?.reasoningEffort == "low")
        #expect(requests.last?.reasoningEffort == "high")
        #expect(requests.first?.id != requests.last?.id)
    }
}

private extension ChatStoreTests {
    // A fixture groups the subject with its two independent test doubles.
    // swiftlint:disable:next large_tuple
    func makeStore(consented: Bool = true) -> (ChatStore, FakeChatAPI, MemoryCredentials) {
        let api = FakeChatAPI()
        let credentials = MemoryCredentials()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if consented {
            defaults.set("test|Test Provider", forKey: "ai-consent.test-user")
        }
        return (
            ChatStore(
                service: api,
                credentials: credentials,
                deviceID: "ios-test",
                consentDefaults: defaults,
                reconnectDelay: .milliseconds(1),
                historyPageSize: 1
            ),
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
    func profile(token _: String) async throws -> ChatProfile {
        .init(id: "test-user", email: "test@example.com")
    }

    var waitingForPrivacy: Bool {
        privacyContinuation != nil
    }

    private var privacyPaused = false
    private var privacyContinuation: CheckedContinuation<Void, Never>?
    func pausePrivacy() {
        privacyPaused = true
    }

    func resumePrivacy() {
        privacyPaused = false; privacyContinuation?.resume(); privacyContinuation = nil
    }

    var privacyVersion = "test"
    var privacyUnavailable = false
    var deletionRejected = false
    var deletedAccounts = 0
    var reports: [String] = []
    func changePrivacy(version: String) {
        privacyVersion = version
    }

    func disablePrivacy() {
        privacyUnavailable = true
    }

    func rejectDeletion() {
        deletionRejected = true
    }

    func aiDisclosure(token _: String) async throws -> ChatAIDisclosure {
        if privacyPaused {
            await withCheckedContinuation { privacyContinuation = $0 }
        }
        if privacyUnavailable {
            throw ChatAPIError.unavailable
        }
        return .init(version: privacyVersion, providers: ["Test Provider"])
    }

    func deleteAccount(proof _: ChatDeletionProof, token _: String) async throws {
        if deletionRejected {
            throw ChatAPIError.unavailable
        }
        deletedAccounts += 1
    }

    func reportAnswer(content: String, token _: String) async throws {
        reports.append(content)
    }

    var loginCount = 0
    var loginEmails: [String] = []
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

    var waitingForSend: Bool {
        sendContinuation != nil
    }

    var document = ChatConversation(id: "one", title: "A conversation", revision: 1)
    private var catalog = [
        ChatModel(id: "balanced", name: "Balanced", vision: true, reasoning: true),
        ChatModel(id: "text-only", name: "Text", vision: false, reasoning: false)
    ]
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
    private var sendPaused = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var conversationContinuation: CheckedContinuation<Void, Never>?
    private var listContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

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

    func allowConversationFetch() {
        conversationFails = false
    }

    func pauseNextList() {
        listPaused = true
    }

    func completeList() {
        listContinuation?.resume(); listContinuation = nil
    }

    func pauseNextSend() {
        sendPaused = true
    }

    func completeSend() {
        sendContinuation?.resume(); sendContinuation = nil
    }

    func setActiveRun() {
        document.run = ChatRun(id: "run", deviceId: "mac", status: "running")
    }

    func setModels(_ models: [ChatModel]) {
        catalog = models
    }

    func setMessages(_ messages: [ChatMessage]) {
        document.messages = messages
    }

    func login(email: String, password _: String) async throws -> ChatSession {
        loginCount += 1
        loginEmails.append(email)
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
        catalog
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
        if sendPaused {
            sendPaused = false
            await withCheckedContinuation { sendContinuation = $0 }
        }
        if nextSendRejected {
            nextSendRejected = false
            throw ChatAPIError.server(code: "MODEL_UNAVAILABLE", message: "Choose another model.")
        }
        if nextSendLost {
            nextSendLost = false
            throw URLError(.networkConnectionLost)
        }
        document.id = conversationId
        document.messages.append(ChatMessage(id: request.id, role: "user", text: request.text, image: request.image))
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
