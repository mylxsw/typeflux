import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Account details, Apple sign-in and conversation actions")
struct ChatAccountTests {
    @Test func `refresh loads profile and credits and sign out clears them`() async {
        let (store, _, _) = makeStore()
        await store.login(email: "demir.von@example.com", password: "password")
        #expect(store.profile?.name == "Demir Von")
        #expect(store.creditUsage?.credits.remaining == 316)
        #expect(store.displayName == "Demir Von")
        #expect(store.initials == "DV")
        #expect(store.planLabel == "Pro")
        await store.signOut()
        #expect(store.profile == nil)
        #expect(store.creditUsage == nil)
        #expect(store.planLabel == nil)
    }

    @Test func `missing account endpoints never block chatting`() async {
        let (store, api, _) = makeStore()
        await api.disableAccountEndpoints()
        await store.login(email: "plain@example.com", password: "password")
        #expect(store.isAuthenticated)
        #expect(store.errorMessage == nil)
        #expect(store.profile == nil)
        #expect(store.displayName == "plain")
        #expect(store.initials == "PL")
        #expect(store.planLabel == nil)
    }

    @Test func `display name falls back to email and free plans say Free`() async {
        let (store, api, _) = makeStore()
        await api.setProfile(ChatProfile(id: "u", email: "x@example.com", name: "  "))
        await api.setPaid(false)
        await store.login(email: "x@example.com", password: "password")
        #expect(store.displayName == "x")
        #expect(store.initials == "X")
        #expect(store.planLabel == "Free")
    }

    @Test func `apple sign in saves the profile email and loads history`() async {
        let (store, api, credentials) = makeStore()
        await store.loginWithApple(identityToken: "apple-token", email: nil)
        #expect(store.isAuthenticated)
        #expect(store.email == "demir.von@example.com")
        #expect(credentials.value?.email == "demir.von@example.com")
        #expect(await api.appleTokens == ["apple-token"])
        #expect(store.conversations.map(\.id) == ["one"])
    }

    @Test func `apple sign in uses the shared email when the profile is unavailable`() async {
        let (store, api, credentials) = makeStore()
        await api.disableAccountEndpoints()
        await store.loginWithApple(identityToken: "apple-token", email: " first@example.com ")
        #expect(store.email == "first@example.com")
        #expect(credentials.value?.email == "first@example.com")
    }

    @Test func `rejected apple sign in reports the server message and stays signed out`() async {
        let (store, api, credentials) = makeStore()
        await api.rejectApple()
        await store.loginWithApple(identityToken: "bad", email: nil)
        #expect(!store.isAuthenticated)
        #expect(credentials.value == nil)
        #expect(store.errorMessage == "Apple sign-in is not configured.")
    }

    @Test func `google sign in saves the verified profile and reuses the account lifecycle`() async {
        let (store, api, credentials) = makeStore()
        await store.loginWithGoogle(using: FakeGoogleAuthorizer())
        #expect(store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(store.email == "demir.von@example.com")
        #expect(credentials.value?.session.accessToken == "valid")
        #expect(await api.googleTokens == ["google-token"])
        #expect(store.conversations.map(\.id) == ["one"])
        await store.signOut()
        #expect(credentials.value == nil)
        #expect(!store.isAuthenticated)
    }

    @Test func `cancelled google authorization stays signed out without an error`() async {
        let (store, api, credentials) = makeStore()
        await store.loginWithGoogle(using: FakeGoogleAuthorizer(error: CancellationError()))
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
        #expect(credentials.value == nil)
        #expect(await api.googleTokens.isEmpty)
    }

    @Test func `google configuration and backend errors are recoverable`() async {
        let (store, api, credentials) = makeStore()
        await store.loginWithGoogle(using: FakeGoogleAuthorizer(error: GoogleOAuthError.notConfigured))
        #expect(store.errorMessage == GoogleOAuthError.notConfigured.rawValue)
        await api.rejectApple()
        await store.loginWithGoogle(using: FakeGoogleAuthorizer())
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(credentials.value == nil)
        #expect(store.errorMessage == "Google sign-in is not configured.")
    }

    @Test func `google login tolerates a missing profile endpoint`() async {
        let (store, api, credentials) = makeStore()
        await api.disableAccountEndpoints()
        await store.loginWithGoogle(using: FakeGoogleAuthorizer())
        #expect(store.isAuthenticated)
        #expect(credentials.value?.session.accessToken == "valid")
        #expect(store.email.isEmpty)
    }

    @Test(arguments: [ChatAPIError.unauthorized,
                      .server(code: "AUTH_OAUTH_INVALID_TOKEN", message: "invalid OAuth token")])
    func `rejected social sign in never suggests an email password error`(error: ChatAPIError) async {
        let (store, api, credentials) = makeStore()
        await api.setOAuthError(error)
        await store.loginWithGoogle(using: FakeGoogleAuthorizer())
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(credentials.value == nil)
        #expect(store.errorMessage ==
            "The server could not verify your Google sign-in. Please try again or contact support.")
        await store.loginWithApple(identityToken: "apple-token", email: nil)
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(credentials.value == nil)
        #expect(store.errorMessage ==
            "The server could not verify your Apple sign-in. Please try again or contact support.")
        await api.setOAuthError(nil)
        await store.loginWithGoogle(using: FakeGoogleAuthorizer())
        #expect(store.isAuthenticated)
        #expect(store.errorMessage == nil)
    }

    @Test func `google login cannot resurrect an account after sign out during authorization`() async {
        let (store, api, credentials) = makeStore()
        await store.loginWithGoogle(using: ClosureGoogleAuthorizer {
            await store.signOut()
            return "late-token"
        })
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(credentials.value == nil)
        #expect(await api.googleTokens.isEmpty)
    }

    @Test func `duplicate google sign in is ignored and keychain failures stay signed out`() async {
        let (store, api, credentials) = makeStore()
        credentials.failSave = true
        await store.loginWithGoogle(using: ClosureGoogleAuthorizer {
            await store.loginWithGoogle(using: FakeGoogleAuthorizer())
            return "first-token"
        })
        #expect(await api.googleTokens == ["first-token"])
        #expect(!store.isAuthenticated)
        #expect(!store.isLoading)
        #expect(credentials.value == nil)
        #expect(store.errorMessage != nil)
    }

    @Test func `password reset sends a code then resets with it`() async {
        let (store, api, _) = makeStore()
        #expect(await store.requestPasswordReset(email: "  ") == false)
        #expect(await store.requestPasswordReset(email: " me@example.com ") == true)
        #expect(await api.resetEmails == ["me@example.com"])
        #expect(await store.resetPassword(email: "me@example.com", code: " 123456 ", newPassword: "new-password"))
        #expect(await api.resetCodes == ["123456"])
        await api.rejectReset()
        #expect(await store.requestPasswordReset(email: "me@example.com") == false)
        #expect(store.errorMessage == "Too many requests.")
        #expect(await store.resetPassword(email: "me@example.com", code: "1", newPassword: "x") == false)
    }

    @Test func `only the last answer after the last question can be regenerated`() async {
        let (store, api, _) = makeStore()
        await api.setMessages([
            ChatMessage(id: "q1", role: "user", text: "One"),
            ChatMessage(id: "a1", role: "assistant", text: "First"),
            ChatMessage(id: "q2", role: "user", text: "Two"),
            ChatMessage(id: "a2", role: "assistant", text: "Second"),
            ChatMessage(id: "empty", role: "assistant", text: "")
        ])
        await store.login(email: "me@example.com", password: "password")
        await store.select("one")
        #expect(store.regenerableMessageID == "a2")
        await store.regenerate(messageID: "a1")
        #expect(await api.regenerateRequests.isEmpty)
        await store.regenerate(messageID: "a2")
        let requests = await api.regenerateRequests
        #expect(requests.map(\.messageId) == ["a2"])
        #expect(requests.first?.deviceId == "ios-test")
        #expect(requests.first?.modelRef == "cloud:balanced")
        #expect(store.conversation?.messages.last?.text == "Regenerated")
        #expect(!store.isSending)
    }

    @Test func `an unanswered question has nothing to regenerate`() async {
        let (store, api, _) = makeStore()
        await api.setMessages([
            ChatMessage(id: "a1", role: "assistant", text: "Hello"),
            ChatMessage(id: "q1", role: "user", text: "Question")
        ])
        await store.login(email: "me@example.com", password: "password")
        await store.select("one")
        #expect(store.regenerableMessageID == nil)
    }

    @Test func `failed regeneration reports the error`() async {
        let (store, api, _) = makeStore()
        await api.setMessages([
            ChatMessage(id: "q1", role: "user", text: "One"),
            ChatMessage(id: "a1", role: "assistant", text: "First")
        ])
        await api.rejectRegenerate()
        await store.login(email: "me@example.com", password: "password")
        await store.select("one")
        await store.regenerate(messageID: "a1")
        #expect(store.errorMessage == "Run already active.")
        #expect(!store.isSending)
    }

    @Test func `deleting the open conversation starts a new one`() async {
        let (store, api, _) = makeStore()
        await store.login(email: "me@example.com", password: "password")
        await store.select("one")
        await store.deleteConversation("one")
        #expect(await api.deleted == ["one"])
        #expect(store.conversations.isEmpty)
        #expect(store.selectedID != "one")
        #expect(store.conversation == nil)
    }

    @Test func `failed delete keeps the conversation`() async {
        let (store, api, _) = makeStore()
        await api.rejectDelete()
        await store.login(email: "me@example.com", password: "password")
        await store.deleteConversation("one")
        #expect(store.conversations.map(\.id) == ["one"])
        #expect(store.errorMessage == "Not found.")
    }
}

private extension ChatAccountTests {
    // swiftlint:disable:next large_tuple
    func makeStore() -> (ChatStore, AccountFakeAPI, MemoryCredentials) {
        let api = AccountFakeAPI()
        let credentials = MemoryCredentials()
        return (ChatStore(service: api, credentials: credentials, deviceID: "ios-test"), api, credentials)
    }
}

private actor AccountFakeAPI: ChatAPI {
    var appleTokens: [String] = []
    var googleTokens: [String] = []
    var resetEmails: [String] = []
    var resetCodes: [String] = []
    var regenerateRequests: [ChatRegenerateRequest] = []
    var deleted: [String] = []
    private var document = ChatConversation(id: "one", title: "A conversation", revision: 1)
    private var profileValue: ChatProfile? = ChatProfile(id: "u1", email: "demir.von@example.com", name: "Demir Von")
    private var paid = true
    private var accountEndpoints = true
    private var appleRejected = false
    private var oauthError: ChatAPIError?
    private var resetRejected = false
    private var regenerateRejected = false
    private var deleteRejected = false

    func disableAccountEndpoints() {
        accountEndpoints = false
    }

    func setProfile(_ value: ChatProfile) {
        profileValue = value
    }

    func setPaid(_ value: Bool) {
        paid = value
    }

    func rejectApple() {
        appleRejected = true
    }

    func setOAuthError(_ error: ChatAPIError?) {
        oauthError = error
    }

    func rejectReset() {
        resetRejected = true
    }

    func rejectRegenerate() {
        regenerateRejected = true
    }

    func rejectDelete() {
        deleteRejected = true
    }

    func setMessages(_ messages: [ChatMessage]) {
        document.messages = messages
    }

    func login(email _: String, password _: String) async throws -> ChatSession {
        ChatSession(accessToken: "valid", expiresAt: 0, refreshToken: "refresh")
    }

    func refresh(refreshToken _: String) async throws -> ChatSession {
        throw ChatAPIError.unauthorized
    }

    func logout(refreshToken _: String) async throws {}

    func models(token _: String) async throws -> [ChatModel] {
        [ChatModel(id: "balanced", name: "Balanced", vision: true, reasoning: true)]
    }

    func list(token _: String, offset: Int) async throws -> [ChatConversationSummary] {
        offset == 0 ? [ChatConversationSummary(id: "one", title: "A conversation")] : []
    }

    func conversation(id _: String, token _: String) async throws -> ChatConversation {
        document
    }

    func send(conversationId _: String, request _: ChatSendRequest, token _: String) async throws -> ChatConversation {
        document
    }

    func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
        document
    }

    func observe(id _: String, token _: String,
                 onValue _: @concurrent @Sendable (ChatConversation) async throws -> Void) async throws {}

    func googleLogin(identityToken: String) async throws -> ChatSession {
        googleTokens.append(identityToken)
        if let oauthError { throw oauthError }
        if appleRejected {
            throw ChatAPIError.server(code: "OAUTH_NOT_CONFIGURED", message: "Google sign-in is not configured.")
        }
        return ChatSession(accessToken: "valid", expiresAt: 0, refreshToken: "refresh")
    }

    func appleLogin(identityToken: String) async throws -> ChatSession {
        appleTokens.append(identityToken)
        if let oauthError { throw oauthError }
        if appleRejected {
            throw ChatAPIError.server(code: "OAUTH_NOT_CONFIGURED", message: "Apple sign-in is not configured.")
        }
        return ChatSession(accessToken: "valid", expiresAt: 0, refreshToken: "refresh")
    }

    func forgotPassword(email: String) async throws {
        if resetRejected {
            throw ChatAPIError.server(code: "RATE_LIMITED", message: "Too many requests.")
        }
        resetEmails.append(email)
    }

    func resetPassword(email _: String, code: String, newPassword _: String) async throws {
        if resetRejected {
            throw ChatAPIError.server(code: "INVALID_CODE", message: "Invalid code.")
        }
        resetCodes.append(code)
    }

    func profile(token _: String) async throws -> ChatProfile {
        guard accountEndpoints, let profileValue else { throw ChatAPIError.unavailable }
        return profileValue
    }

    func creditUsage(token _: String) async throws -> ChatCreditUsage {
        guard accountEndpoints else { throw ChatAPIError.unavailable }
        return ChatCreditUsage(periodEnd: Date(timeIntervalSince1970: 1_800_000_000), planCode: paid ? "pro" : "free",
                               paid: paid, credits: .init(limit: 500, used: 184, remaining: 316))
    }

    func regenerate(conversationId _: String, request: ChatRegenerateRequest,
                    token _: String) async throws -> ChatConversation {
        regenerateRequests.append(request)
        if regenerateRejected {
            throw ChatAPIError.server(code: "RUN_ACTIVE", message: "Run already active.")
        }
        document.messages[document.messages.count - 1] = ChatMessage(id: "regenerated", role: "assistant",
                                                                     text: "Regenerated")
        document.revision += 1
        return document
    }

    func deleteConversation(id: String, token _: String) async throws {
        if deleteRejected {
            throw ChatAPIError.server(code: "NOT_FOUND", message: "Not found.")
        }
        deleted.append(id)
    }
}

@MainActor
private struct FakeGoogleAuthorizer: GoogleSignInAuthorizing {
    var error: (any Error)?
    func signIn() async throws -> String {
        if let error { throw error }
        return "google-token"
    }
}

@MainActor
private struct ClosureGoogleAuthorizer: GoogleSignInAuthorizing {
    var operation: () async throws -> String
    func signIn() async throws -> String { try await operation() }
}
