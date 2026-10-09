import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS

@MainActor
@Suite("Credits, App Store purchases and user-facing errors")
struct ChatPurchasesTests {
    static let userID = "6f1b3c1e-7d3c-4a33-9c55-6c5cbd6c0d11"

    // MARK: Shop

    @Test func `loading offers only packs the App Store prices`() async {
        let (store, _, kit) = await signedIn()
        await kit.setPrices(["app.typeflux.ios.credits.small": "¥12.00"])
        let shop = ChatCreditShop(store: store, storeKit: kit)
        await shop.load()
        #expect(shop.phase == .ready)
        #expect(shop.offers.map(\.pack.code) == ["pack_s"])
        #expect(shop.offers.first?.price == "¥12.00")
    }

    @Test func `closed or empty catalogs and failures are explained`() async {
        let (store, api, kit) = await signedIn()
        let shop = ChatCreditShop(store: store, storeKit: kit)
        await api.setCatalog(.init(enabled: false, packs: CreditsAPI.packs))
        await shop.load()
        #expect(shop.phase == .unavailable)
        await api.setCatalog(.init(enabled: true, packs: CreditsAPI.packs))
        await kit.setPrices([:])
        await shop.load()
        #expect(shop.phase == .unavailable)
        await api.setCatalogError(URLError(.notConnectedToInternet))
        await shop.load()
        #expect(shop.phase == .failed("Couldn't reach Typeflux. Check your connection and try again."))
        await api.setCatalogError(ChatAPIError.server(code: "APPLE_IAP_DISABLED", message: nil))
        await shop.load()
        #expect(shop.phase == .failed("Buying credits in the app isn't available right now."))
        await api.setCatalogError(nil)
        await kit.setPriceError(StoreKitFixtureError())
        await shop.load()
        #expect(shop.phase == .failed("Couldn't reach Typeflux. Check your connection and try again."))

        let guest = ChatStore(service: api, credentials: MemoryCredentials(), deviceID: "d")
        let guestShop = ChatCreditShop(store: guest, storeKit: kit)
        await guestShop.load()
        #expect(guestShop.phase == .unavailable)
    }

    @Test func `a purchase is delivered to this account then finished`() async throws {
        let (store, api, kit) = await signedIn()
        let shop = ChatCreditShop(store: store, storeKit: kit)
        await shop.load()
        let offer = try #require(shop.offers.first { $0.pack.code == "pack_m" })
        await shop.buy(offer)
        #expect(try await kit.purchasedAccounts == [#require(UUID(uuidString: Self.userID))])
        #expect(await api.submitted == ["jws-1"])
        #expect(await kit.finished == [1])
        #expect(shop.notice == .delivered(credits: 220_000))
        #expect(shop.purchasingCode == nil)
        #expect(store.creditUsage?.addonRemaining == 220_000)
    }

    @Test func `pending cancelled and failed purchases never submit`() async throws {
        let (store, api, kit) = await signedIn()
        let shop = ChatCreditShop(store: store, storeKit: kit)
        await shop.load()
        let offer = try #require(shop.offers.first)
        await kit.setOutcome(.pending)
        await shop.buy(offer)
        #expect(shop.notice == .pending)
        await kit.setOutcome(.cancelled)
        shop.notice = nil
        await shop.buy(offer)
        #expect(shop.notice == nil)
        await kit.setPurchaseError(ChatPurchaseError.productUnavailable)
        await shop.buy(offer)
        #expect(shop.notice == .failed("This credit pack is not available right now. Try again later."))
        #expect(await api.submitted.isEmpty)
    }

    @Test func `buying requires an account identity StoreKit can carry`() async throws {
        let (store, api, kit) = await signedIn(profileID: "not-a-uuid")
        let shop = ChatCreditShop(store: store, storeKit: kit)
        await shop.load()
        try await shop.buy(#require(shop.offers.first))
        #expect(shop.notice == .failed("Sign in again before buying credits."))
        #expect(await kit.purchasedAccounts.isEmpty)
        #expect(await api.submitted.isEmpty)
    }

    @Test func `undelivered purchases stay in StoreKit for a later retry`() async {
        let (store, api, kit) = await signedIn()
        let shop = ChatCreditShop(store: store, storeKit: kit)
        let transaction = ChatStoreTransaction(id: 7, productID: "app.typeflux.ios.credits.small", signed: "jws-7")
        await api.setSubmitError(ChatAPIError.server(code: "APPLE_TRANSACTION_ACCOUNT_MISMATCH", message: nil))
        await shop.deliver(transaction)
        #expect(shop.notice == .waitingForAccount)
        await api.setSubmitError(URLError(.timedOut))
        await shop.deliver(transaction)
        #expect(shop.notice == .failed(ChatCreditShop.deliveryDelayed))
        await api.setSubmitError(ChatAPIError.server(code: "APPLE_TRANSACTION_INVALID", message: nil))
        await shop.deliver(transaction)
        guard case let .failed(message) = shop.notice else {
            Issue.record("An unverifiable purchase must be explained")
            return
        }
        #expect(message.contains("couldn't verify"))
        await api.setSubmitError(nil)
        await api.setReceiptStatus("pending")
        await shop.deliver(transaction)
        #expect(shop.notice == .failed(ChatCreditShop.deliveryDelayed))
        #expect(await kit.finished.isEmpty)

        await api.setReceiptStatus("revoked")
        shop.notice = nil
        await shop.deliver(transaction)
        #expect(await kit.finished == [7])
        #expect(shop.notice == nil, "A refunded purchase is closed without announcing credits")
    }

    @Test func `unfinished and background transactions are delivered once each`() async throws {
        let (store, api, kit) = await signedIn()
        let shop = ChatCreditShop(store: store, storeKit: kit)
        let first = ChatStoreTransaction(id: 1, productID: "app.typeflux.ios.credits.small", signed: "jws-a")
        await kit.setUnfinished([first, first])
        await shop.deliverUnfinished()
        #expect(await api.submitted == ["jws-a", "jws-a"])
        #expect(await kit.finished == [1, 1])

        await kit.setUnfinished([])
        await shop.checkMissingCredits()
        #expect(shop.notice == .upToDate)

        shop.start()
        try await eventually { await kit.hasListener }
        await kit.emit(ChatStoreTransaction(id: 9, productID: "app.typeflux.ios.credits.small", signed: "jws-b"))
        try await eventually { await api.submitted.contains("jws-b") }
        try await eventually { await kit.finished.contains(9) }
        #expect(store.infoMessage == "Your purchased credits have been added.")
        shop.stop()

        await store.signOut()
        shop.reset()
        #expect(shop.notice == nil)
        #expect(shop.offers.isEmpty)
        #expect(shop.phase == .idle)
        await shop.deliver(ChatStoreTransaction(id: 10, productID: "x", signed: "jws-c"))
        await shop.deliverUnfinished()
        #expect(await api.submitted.contains("jws-c") == false, "Signed-out apps keep transactions for later")
    }

    // MARK: Credits in the conversation

    @Test func `running out of credits explains itself and clears after buying`() async throws {
        let (store, api, kit) = await signedIn()
        await api.setOutOfCredits(true)
        store.draft = "Hello"
        await store.send()
        #expect(store.creditsExhausted)
        #expect(store.needsCredits)
        #expect(store.errorMessage == ChatStore.creditsExhaustedMessage)
        #expect(store.draft == "Hello", "The draft survives a refused send")

        let shop = ChatCreditShop(store: store, storeKit: kit)
        await shop.load()
        try await shop.buy(#require(shop.offers.first))
        #expect(!store.creditsExhausted)
        #expect(store.errorMessage == nil)

        await api.setOutOfCredits(false)
        await store.send()
        #expect(!store.needsCredits)
        #expect(store.draft.isEmpty)
    }

    @Test func `a run paused for credits waits for an explicit resume`() async {
        let (store, api, _) = await signedIn()
        await api.setPaused(true)
        await store.select("paused")
        #expect(store.isPausedForCredits)
        #expect(store.needsCredits)
        #expect(store.isRunning)
        #expect(await api.observeCount == 0, "Nothing streams while the server waits for credits")

        await store.resumeRun()
        #expect(store.isPausedForCredits)
        #expect(store.creditsExhausted)

        await api.setOutOfCredits(false)
        await store.resumeRun()
        #expect(!store.isPausedForCredits)
        #expect(!store.needsCredits)
        #expect(store.conversation?.run?.status == "completed")
        #expect(await api.resumed == 2)

        await store.resumeRun()
        #expect(await api.resumed == 2, "Only a paused run can be resumed")
    }

    @Test func `the purchase token is the signed-in account`() async {
        let (store, _, _) = await signedIn()
        #expect(store.purchaseAccountToken == UUID(uuidString: Self.userID))
        await store.signOut()
        #expect(store.purchaseAccountToken == nil)
    }

    @Test func `short history pages do not offer more`() async {
        let api = CreditsAPI()
        let store = ChatStore(service: api, credentials: MemoryCredentials(), deviceID: "d",
                              consentDefaults: Self.consented(Self.userID))
        await store.login(email: "user@example.com", password: "password")
        #expect(store.conversations.count == 1)
        #expect(!store.hasMore)
    }

    // MARK: Errors

    @Test(arguments: [
        (ChatAPIError.unavailable as Error, "This feature isn't available right now. Please try again later."),
        (ChatAPIError.invalidResponse, "Typeflux sent an unexpected response. Please try again."),
        (ChatAPIError.unauthorized, "Please sign in again."),
        (URLError(.notConnectedToInternet), "You're offline. Check your connection and try again."),
        (URLError(.timedOut), "Typeflux is taking too long to respond. Please try again."),
        (URLError(.cannotFindHost), "Couldn't reach Typeflux. Check your connection and try again."),
        (ChatAPIError.server(code: "CREDITS_EXHAUSTED", message: "credits exhausted"),
         ChatStore.creditsExhaustedMessage),
        (ChatAPIError.server(code: "RATE_LIMITED", message: "rate limit exceeded"),
         "You're sending requests too quickly. Wait a moment and try again."),
        (ChatAPIError.server(code: "ASK_NOT_FOUND", message: "Conversation not found"),
         "This conversation is no longer available. It may have been deleted on another device."),
        (ChatAPIError.server(code: "ASK_CONFLICT", message: nil),
         "This conversation changed on another device. Pull down to refresh, then try again."),
        (ChatAPIError.server(code: "AUTH_RESET_CODE_INVALID", message: "invalid reset code"),
         "That code isn't right or has expired. Check the latest email and try again."),
        (ChatAPIError.server(code: "AUTH_RESET_CODE_LOCKED", message: nil),
         "Too many attempts. Please wait a while and try again."),
        (ChatAPIError.server(code: "AUTH_PASSWORD_TOO_WEAK", message: nil),
         "Use at least 8 characters, with uppercase and lowercase letters and a number."),
        (ChatAPIError.server(code: "AUTH_EMAIL_NOT_FOUND", message: nil), "No Typeflux account uses this email."),
        (ChatAPIError.server(code: "AUTH_USER_NOT_ACTIVE", message: nil),
         "This account isn't activated yet. Check your email for the activation link."),
        (ChatAPIError.server(code: "BILLING_UNAVAILABLE",
                             message: "Subscription cancellation is temporarily unavailable. Please retry deletion later."),
         "Subscription cancellation is temporarily unavailable. Please retry deletion later."),
        (ChatAPIError.server(code: "ASK_BAD_REQUEST", message: "content is required"),
         "Typeflux couldn't complete this request. Please try again."),
        (ImageAttachment.ImageError.tooLarge, ImageAttachment.ImageError.tooLarge.errorDescription ?? ""),
        (StoreKitFixtureError(), "Something went wrong. Please try again.")
    ])
    func `errors read as sentences a person can act on`(error: Error, message: String) {
        #expect(ChatStore.userMessage(for: error) == message)
        #expect(!message.contains("ChatAPIError"))
    }

    // MARK: Fixtures

    static func consented(_ id: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("v|Provider", forKey: "ai-consent." + id)
        return defaults
    }

    private func signedIn(profileID: String = userID) async -> (ChatStore, CreditsAPI, FixtureStoreKit) {
        let api = CreditsAPI(profileID: profileID)
        let store = ChatStore(service: api, credentials: MemoryCredentials(), deviceID: "ios-test",
                              consentDefaults: Self.consented(profileID), reconnectDelay: .milliseconds(1))
        await store.login(email: "user@example.com", password: "password")
        await store.loadDisclosure()
        return (store, api, FixtureStoreKit())
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition was not met")
    }
}

struct StoreKitFixtureError: Error {}

private actor FixtureStoreKit: ChatStoreKit {
    private var prices: [String: String] = ["app.typeflux.ios.credits.small": "¥12.00",
                                            "app.typeflux.ios.credits.medium": "¥25.00"]
    private var priceError: Error?
    private var outcome: ChatPurchaseOutcome?
    private var purchaseError: Error?
    private var pendingUnfinished: [ChatStoreTransaction] = []
    private var sequence: UInt64 = 0
    private var continuation: AsyncStream<ChatStoreTransaction>.Continuation?
    private(set) var purchasedAccounts: [UUID] = []
    private(set) var finished: [UInt64] = []

    func setPrices(_ value: [String: String]) {
        prices = value
    }

    func setPriceError(_ error: Error?) {
        priceError = error
    }

    func setOutcome(_ value: ChatPurchaseOutcome?) {
        outcome = value; purchaseError = nil
    }

    func setPurchaseError(_ error: Error?) {
        purchaseError = error
    }

    func setUnfinished(_ values: [ChatStoreTransaction]) {
        pendingUnfinished = values
    }

    var hasListener: Bool {
        continuation != nil
    }

    func emit(_ transaction: ChatStoreTransaction) {
        continuation?.yield(transaction)
    }

    private func attach(_ value: AsyncStream<ChatStoreTransaction>.Continuation) {
        continuation = value
    }

    func prices(for productIDs: [String]) async throws -> [String: String] {
        if let priceError {
            throw priceError
        }
        return prices.filter { productIDs.contains($0.key) }
    }

    func purchase(productID: String, account: UUID) async throws -> ChatPurchaseOutcome {
        if let purchaseError {
            throw purchaseError
        }
        purchasedAccounts.append(account)
        if let outcome {
            return outcome
        }
        sequence += 1
        return .purchased(ChatStoreTransaction(id: sequence, productID: productID, signed: "jws-\(sequence)"))
    }

    func unfinished() async -> [ChatStoreTransaction] {
        pendingUnfinished
    }

    nonisolated func updates() -> AsyncStream<ChatStoreTransaction> {
        let (stream, continuation) = AsyncStream<ChatStoreTransaction>.makeStream()
        Task { await self.attach(continuation) }
        return stream
    }

    func finish(_ transactionID: UInt64) async {
        finished.append(transactionID)
    }
}

private actor CreditsAPI: ChatAPI {
    static let packs = [
        ChatAppleCreditPack(code: "pack_s", productId: "app.typeflux.ios.credits.small", name: "Small",
                            credits: 100_000),
        ChatAppleCreditPack(code: "pack_m", productId: "app.typeflux.ios.credits.medium", name: "Medium",
                            credits: 220_000, highlight: true)
    ]

    let profileID: String
    private var catalog = ChatAppleCreditPacks(enabled: true, packs: packs)
    private var catalogError: Error?
    private var submitError: Error?
    private var receiptStatus = "granted"
    private var outOfCredits = false
    private var paused = false
    private var addon = 0
    private(set) var submitted: [String] = []
    private(set) var observeCount = 0
    private(set) var resumed = 0
    private var document = ChatConversation(id: "paused", title: "Paused")

    init(profileID: String = "6f1b3c1e-7d3c-4a33-9c55-6c5cbd6c0d11") {
        self.profileID = profileID
    }

    func setCatalog(_ value: ChatAppleCreditPacks) {
        catalog = value
    }

    func setCatalogError(_ error: Error?) {
        catalogError = error
    }

    func setSubmitError(_ error: Error?) {
        submitError = error
    }

    func setReceiptStatus(_ value: String) {
        receiptStatus = value
    }

    func setOutOfCredits(_ value: Bool) {
        outOfCredits = value
    }

    func setPaused(_ value: Bool) {
        paused = value
        outOfCredits = value
        document.run = ChatRun(id: "run", deviceId: "d", status: "paused_credits")
    }

    func login(email _: String, password _: String) async throws -> ChatSession {
        ChatSession(accessToken: "access", expiresAt: 0, refreshToken: "refresh")
    }

    func refresh(refreshToken _: String) async throws -> ChatSession {
        throw ChatAPIError.unauthorized
    }

    func logout(refreshToken _: String) async throws {}
    func models(token _: String) async throws -> [ChatModel] {
        [ChatModel(id: "m", name: "Model", vision: false)]
    }

    func list(token _: String, offset: Int) async throws -> [ChatConversationSummary] {
        offset == 0 ? [ChatConversationSummary(id: "paused", title: "Paused")] : []
    }

    func conversation(id _: String, token _: String) async throws -> ChatConversation {
        document
    }

    func send(conversationId: String, request: ChatSendRequest, token _: String) async throws -> ChatConversation {
        if outOfCredits {
            throw ChatAPIError.server(code: "CREDITS_EXHAUSTED", message: "credits exhausted")
        }
        var value = ChatConversation(id: conversationId, title: "New", revision: 1)
        value.messages = [ChatMessage(id: request.id, role: "user", text: request.text)]
        return value
    }

    func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
        document
    }

    func observe(id _: String, token _: String,
                 onValue _: @concurrent @Sendable (ChatConversation) async throws -> Void) async throws {
        observeCount += 1
    }

    func profile(token _: String) async throws -> ChatProfile {
        ChatProfile(id: profileID, email: "user@example.com")
    }

    func aiDisclosure(token _: String) async throws -> ChatAIDisclosure {
        ChatAIDisclosure(version: "v", providers: ["Provider"])
    }

    func creditUsage(token _: String) async throws -> ChatCreditUsage {
        ChatCreditUsage(periodEnd: Date(), planCode: "free", paid: false,
                        credits: .init(limit: 10, used: 10, remaining: 0,
                                       addon: addon > 0 ? .init(remaining: addon) : nil))
    }

    func appleCreditPacks(language _: String, token _: String) async throws -> ChatAppleCreditPacks {
        if let catalogError {
            throw catalogError
        }
        return catalog
    }

    func submitAppleTransaction(_ signed: String, token _: String) async throws -> ChatApplePurchaseReceipt {
        submitted.append(signed)
        if let submitError {
            throw submitError
        }
        let credits = signed == "jws-1" ? 220_000 : 100_000
        if receiptStatus == "granted" {
            addon += credits
        }
        return ChatApplePurchaseReceipt(status: receiptStatus, transactionId: signed, credits: credits)
    }

    func resume(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
        resumed += 1
        if outOfCredits {
            throw ChatAPIError.server(code: "CREDITS_EXHAUSTED", message: "credits exhausted")
        }
        document.run?.status = "completed"
        document.revision += 1
        return document
    }
}
