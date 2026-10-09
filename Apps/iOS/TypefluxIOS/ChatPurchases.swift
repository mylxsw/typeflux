import Foundation
import Observation
import StoreKit
import TypefluxChat

/// One App Store transaction waiting to be delivered to the server.
nonisolated struct ChatStoreTransaction: Equatable, Sendable {
    let id: UInt64
    let productID: String
    /// StoreKit 2 `jwsRepresentation`; the server verifies it against Apple's root.
    let signed: String
}

nonisolated enum ChatPurchaseOutcome: Equatable, Sendable {
    case purchased(ChatStoreTransaction)
    /// Ask to Buy or extra authentication: StoreKit reports it later as an update.
    case pending
    case cancelled
}

/// StoreKit behind a protocol, so purchase logic is testable and previews never
/// reach the App Store.
nonisolated protocol ChatStoreKit: Sendable {
    /// Localized display prices by product ID. Missing IDs are not on sale.
    func prices(for productIDs: [String]) async throws -> [String: String]
    func purchase(productID: String, account: UUID) async throws -> ChatPurchaseOutcome
    /// Transactions not yet finished, for example after a crash or lost network.
    func unfinished() async -> [ChatStoreTransaction]
    /// Transactions completed outside a purchase call (Ask to Buy, other devices).
    func updates() -> AsyncStream<ChatStoreTransaction>
    func finish(_ transactionID: UInt64) async
}

/// The production StoreKit 2 implementation. Transactions are kept until the
/// server has taken responsibility for them, then finished.
actor LiveStoreKit: ChatStoreKit {
    private var products: [String: Product] = [:]
    private var transactions: [UInt64: Transaction] = [:]

    func prices(for productIDs: [String]) async throws -> [String: String] {
        let loaded = try await Product.products(for: productIDs)
        var prices: [String: String] = [:]
        for product in loaded where product.type == .consumable {
            products[product.id] = product
            prices[product.id] = product.displayPrice
        }
        return prices
    }

    func purchase(productID: String, account: UUID) async throws -> ChatPurchaseOutcome {
        let product: Product
        if let cached = products[productID] {
            product = cached
        } else if let loaded = try await Product.products(for: [productID]).first {
            product = loaded
        } else {
            throw ChatPurchaseError.productUnavailable
        }
        switch try await product.purchase(options: [.appAccountToken(account)]) {
        case let .success(result):
            return .purchased(remember(result))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func unfinished() async -> [ChatStoreTransaction] {
        var values: [ChatStoreTransaction] = []
        for await result in Transaction.unfinished {
            let transaction = result.unsafePayloadValue
            if transaction.productType == .consumable {
                values.append(remember(result))
            }
        }
        return values
    }

    nonisolated func updates() -> AsyncStream<ChatStoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard result.unsafePayloadValue.productType == .consumable else { continue }
                    await continuation.yield(self.remember(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(_ transactionID: UInt64) async {
        await transactions.removeValue(forKey: transactionID)?.finish()
    }

    /// Unverified transactions are still forwarded: the server is the authority
    /// and rejects anything Apple did not sign.
    private func remember(_ result: VerificationResult<Transaction>) -> ChatStoreTransaction {
        let transaction = result.unsafePayloadValue
        transactions[transaction.id] = transaction
        return ChatStoreTransaction(id: transaction.id, productID: transaction.productID,
                                    signed: result.jwsRepresentation)
    }
}

nonisolated enum ChatPurchaseError: LocalizedError, Equatable {
    case productUnavailable

    var errorDescription: String? {
        NSLocalizedString("This credit pack is not available right now. Try again later.", comment: "Purchase error")
    }
}

/// The credit shop: server-defined packs with App Store prices, purchases, and
/// delivery of every transaction exactly once.
@MainActor @Observable
final class ChatCreditShop {
    struct Offer: Identifiable, Equatable {
        let pack: ChatAppleCreditPack
        let price: String
        var id: String {
            pack.code
        }
    }

    enum Phase: Equatable {
        case idle, loading, ready, unavailable, failed(String)
    }

    enum Notice: Equatable {
        case delivered(credits: Int?)
        case pending
        case waitingForAccount
        case upToDate
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var offers: [Offer] = []
    private(set) var purchasingCode: String?
    var notice: Notice?

    private let store: ChatStore
    private let storeKit: any ChatStoreKit
    private var listener: Task<Void, Never>?
    private var delivering: Set<UInt64> = []

    init(store: ChatStore, storeKit: any ChatStoreKit) {
        self.store = store
        self.storeKit = storeKit
    }

    /// Listens for transactions that complete outside the shop and delivers any
    /// left unfinished. Safe to call repeatedly, e.g. after each sign-in.
    func start() {
        if listener == nil {
            let stream = storeKit.updates()
            listener = Task { [weak self] in
                for await transaction in stream {
                    await self?.deliver(transaction)
                }
            }
        }
        Task { await deliverUnfinished() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Forgets what the previous account saw. The listener stays: StoreKit
    /// transactions wait for the next sign-in.
    func reset() {
        phase = .idle
        offers = []
        notice = nil
    }

    /// Returns how many transactions were waiting, so a manual check can say
    /// that everything is already delivered.
    @discardableResult
    func deliverUnfinished() async -> Int {
        guard store.isAuthenticated else { return 0 }
        let pending = await storeKit.unfinished()
        for transaction in pending {
            await deliver(transaction)
        }
        return pending.count
    }

    func checkMissingCredits() async {
        notice = nil
        if await deliverUnfinished() == 0 {
            notice = .upToDate
        }
    }

    func load() async {
        guard store.isAuthenticated else {
            phase = .unavailable
            return
        }
        phase = .loading
        do {
            let catalog = try await store.appleCreditPacks()
            guard catalog.enabled, !catalog.packs.isEmpty else {
                offers = []
                phase = .unavailable
                return
            }
            let prices = try await storeKit.prices(for: catalog.packs.map(\.productId))
            offers = catalog.packs.compactMap { pack in
                prices[pack.productId].map { Offer(pack: pack, price: $0) }
            }
            phase = offers.isEmpty ? .unavailable : .ready
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func buy(_ offer: Offer) async {
        guard purchasingCode == nil else { return }
        guard let account = store.purchaseAccountToken else {
            notice = .failed(NSLocalizedString("Sign in again before buying credits.", comment: "Purchase error"))
            return
        }
        purchasingCode = offer.pack.code
        notice = nil
        defer { purchasingCode = nil }
        do {
            switch try await storeKit.purchase(productID: offer.pack.productId, account: account) {
            case let .purchased(transaction):
                await deliver(transaction)
            case .pending:
                notice = .pending
            case .cancelled:
                break
            }
        } catch {
            notice = .failed(Self.message(for: error))
        }
    }

    /// Finishes a transaction only once the server granted (or refunded) it.
    /// Anything else keeps it in StoreKit, which offers it again on next launch.
    func deliver(_ transaction: ChatStoreTransaction) async {
        guard store.isAuthenticated, !delivering.contains(transaction.id) else { return }
        delivering.insert(transaction.id)
        defer { delivering.remove(transaction.id) }
        do {
            let receipt = try await store.submitApplePurchase(transaction.signed)
            guard receipt.isFinal else {
                notice = .failed(Self.deliveryDelayed)
                return
            }
            await storeKit.finish(transaction.id)
            if receipt.status == "granted" {
                notice = .delivered(credits: receipt.credits)
                if purchasingCode == nil {
                    // Delivered in the background: say so where the person is.
                    store.infoMessage = "Your purchased credits have been added."
                }
            }
        } catch ChatAPIError.server("APPLE_TRANSACTION_ACCOUNT_MISMATCH", _) {
            notice = .waitingForAccount
        } catch let ChatAPIError.server(code, _) where Self.unverifiable.contains(code) {
            notice = .failed(NSLocalizedString(
                "We couldn't verify this purchase. Contact us from Settings › Contact and feedback and we'll sort it out. You won't be charged again.",
                comment: "Purchase verification error"
            ))
        } catch is CancellationError {
            // Signed out or switched accounts: the transaction stays for later.
        } catch {
            notice = .failed(Self.deliveryDelayed)
        }
    }

    /// The server will not accept these as they are; retrying cannot help.
    private static let unverifiable: Set<String> = ["APPLE_TRANSACTION_INVALID", "APPLE_TRANSACTION_ENVIRONMENT",
                                                    "CREDIT_PACK_UNKNOWN"]

    static let deliveryDelayed = NSLocalizedString(
        "Your payment went through, but the credits haven't arrived yet. They'll be added automatically when Typeflux can reach the server.",
        comment: "Purchase delivery error"
    )

    private static func message(for error: Error) -> String {
        if let error = error as? ChatPurchaseError {
            return error.localizedDescription
        }
        if case ChatAPIError.server("APPLE_IAP_DISABLED", _) = error {
            return NSLocalizedString("Buying credits in the app isn't available right now.", comment: "Purchase error")
        }
        if error is StoreKitError || error is Product.PurchaseError {
            return NSLocalizedString("The App Store couldn't complete the purchase. You haven't been charged.",
                                     comment: "Purchase error")
        }
        return NSLocalizedString("Couldn't reach Typeflux. Check your connection and try again.",
                                 comment: "Purchase error")
    }
}
