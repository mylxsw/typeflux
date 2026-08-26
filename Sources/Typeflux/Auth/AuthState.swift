import Foundation
import os

extension Notification.Name {
    /// Posted on the main actor after a successful explicit login
    /// (email/password, Google/Apple/GitHub OAuth). Not fired on silent
    /// token refresh or session restore at app launch.
    static let authDidLogin = Notification.Name("AuthState.authDidLogin")

    /// Posted on the main actor after the local Cloud session is cleared so
    /// presence heartbeats can immediately drop the previous user association.
    static let authDidLogout = Notification.Name("AuthState.authDidLogout")

    /// Posted on the main actor when a checkout-started subscription refresh
    /// observes that the account has become entitled to Typeflux Cloud or has
    /// upgraded from a free/non-paid plan to a paid Cloud subscription.
    static let authCheckoutSubscriptionDidBecomeEntitled = Notification.Name(
        "AuthState.authCheckoutSubscriptionDidBecomeEntitled"
    )
}

/// Observable auth state manager, shared across the app.
@MainActor
final class AuthState: ObservableObject {
    enum SessionRefreshResult: Equatable {
        case authenticated
        case unauthenticated
        case failed
    }

    enum AccessTokenRefreshResult: Equatable {
        case refreshed
        case unavailable
        case failed
        case invalidated
    }

    static let shared = AuthState()

    let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "AuthState")
    let loadStoredToken: () -> (token: String, expiresAt: Int)?
    let loadStoredRefreshToken: () -> String?
    let loadStoredUserProfile: () -> UserProfile?
    let saveStoredToken: (String, Int) -> Void
    let saveStoredSession: (String, Int, String?) -> Void
    let saveStoredUserProfile: (UserProfile) -> Void
    let clearStoredSession: () -> Void
    let fetchProfile: (String) async throws -> UserProfile
    let refreshAccessToken: (String) async throws -> LoginResponse
    let fetchSubscription: (String) async throws -> BillingSubscriptionSnapshot
    let syncBillingSubscription: (String) async throws -> BillingSubscriptionSnapshot
    let fetchCurrentPeriodUsageStats: (String) async throws -> CloudUsageCurrentPeriodStats
    let createCheckoutSession: (String, String) async throws -> BillingCheckoutSession
    let createPortalSession: (String) async throws -> BillingPortalSession
    let issueBillingPageToken: (String) async throws -> BillingPageTokenResponse

    @Published var isLoggedIn: Bool = false
    @Published var userProfile: UserProfile?
    @Published var isLoading: Bool = false
    @Published var subscription: BillingSubscriptionSnapshot = .none
    @Published var isLoadingSubscription: Bool = false
    @Published var isSyncingSubscription: Bool = false
    @Published var subscriptionError: String?
    @Published var usageStats: CloudUsageStats = .empty
    @Published var usageCredits: CloudCreditSummary?
    @Published var usagePeriodStart: String?
    @Published var usagePeriodEnd: String?
    @Published var isLoadingUsage: Bool = false
    @Published var usageError: String?

    /// Refresh the access token when it expires within this window (7 days).
    static let refreshEarlyInterval: TimeInterval = 7 * 24 * 3600

    /// Background timer interval: check every hour.
    static let timerInterval: TimeInterval = 3600
    static let checkoutPollingAttempts = 120
    static let checkoutPollingInterval: Duration = .seconds(3)

    var refreshTimer: Timer?
    var checkoutPollingTask: Task<Void, Never>?
    var pendingCheckoutSubscriptionEntitlement = false
    var inMemorySessionToken: (token: String, expiresAt: Int)?
    var cachedStoredToken: (token: String, expiresAt: Int)?
    var cachedRefreshToken: String?

    var accessToken: String? {
        if let inMemorySessionToken,
           inMemorySessionToken.expiresAt > Int(Date().timeIntervalSince1970) {
            return inMemorySessionToken.token
        }
        guard let stored = cachedStoredToken,
              stored.expiresAt > Int(Date().timeIntervalSince1970)
        else {
            return nil
        }
        return stored.token
    }

    init(
        loadStoredToken: @escaping () -> (token: String, expiresAt: Int)? = {
            KeychainTokenStore.loadToken()
        },
        loadStoredRefreshToken: @escaping () -> String? = {
            KeychainTokenStore.loadRefreshToken()
        },
        loadStoredUserProfile: @escaping () -> UserProfile? = {
            KeychainTokenStore.loadUserProfile()
        },
        saveStoredToken: @escaping (String, Int) -> Void = { token, expiresAt in
            KeychainTokenStore.saveToken(token, expiresAt: expiresAt)
        },
        saveStoredSession: ((String, Int, String?) -> Void)? = nil,
        saveStoredUserProfile: @escaping (UserProfile) -> Void = { profile in
            KeychainTokenStore.saveUserProfile(profile)
        },
        clearStoredSession: @escaping () -> Void = {
            KeychainTokenStore.clearAll()
        },
        fetchProfile: @escaping (String) async throws -> UserProfile = { token in
            try await AuthAPIService.fetchProfile(token: token)
        },
        refreshAccessToken: @escaping (String) async throws -> LoginResponse = { refreshToken in
            try await AuthAPIService.refreshToken(refreshToken)
        },
        fetchSubscription: @escaping (String) async throws -> BillingSubscriptionSnapshot = { token in
            try await BillingAPIService.fetchSubscription(token: token)
        },
        syncSubscription: @escaping (String) async throws -> BillingSubscriptionSnapshot = { token in
            try await BillingAPIService.syncSubscription(token: token)
        },
        fetchCurrentPeriodUsageStats: @escaping (String) async throws -> CloudUsageCurrentPeriodStats = { token in
            try await CloudUsageAPIService.fetchCurrentPeriodStats(token: token)
        },
        createCheckoutSession: @escaping (String, String) async throws -> BillingCheckoutSession = { token, planCode in
            try await BillingAPIService.createCheckoutSession(token: token, planCode: planCode)
        },
        createPortalSession: @escaping (String) async throws -> BillingPortalSession = { token in
            try await BillingAPIService.createPortalSession(token: token)
        },
        issueBillingPageToken: @escaping (String) async throws -> BillingPageTokenResponse = { token in
            try await BillingAPIService.requestBillingPageToken(token: token)
        }
    ) {
        self.loadStoredToken = loadStoredToken
        self.loadStoredRefreshToken = loadStoredRefreshToken
        self.loadStoredUserProfile = loadStoredUserProfile
        self.saveStoredToken = saveStoredToken
        self.saveStoredSession = saveStoredSession ?? { token, expiresAt, refreshToken in
            if let refreshToken {
                KeychainTokenStore.saveToken(token, expiresAt: expiresAt, refreshToken: refreshToken)
            } else {
                saveStoredToken(token, expiresAt)
            }
        }
        self.saveStoredUserProfile = saveStoredUserProfile
        self.clearStoredSession = clearStoredSession
        self.fetchProfile = fetchProfile
        self.refreshAccessToken = refreshAccessToken
        self.fetchSubscription = fetchSubscription
        syncBillingSubscription = syncSubscription
        self.fetchCurrentPeriodUsageStats = fetchCurrentPeriodUsageStats
        self.createCheckoutSession = createCheckoutSession
        self.createPortalSession = createPortalSession
        self.issueBillingPageToken = issueBillingPageToken
        restoreSession()
    }

    // MARK: - Login

    func handleLoginSuccess(token: String, expiresAt: Int, refreshToken: String? = nil) async {
        let normalizedExpiresAt = normalizeLoginExpiry(expiresAt)
        inMemorySessionToken = (token, normalizedExpiresAt)
        cachedStoredToken = (token, normalizedExpiresAt)
        cachedRefreshToken = refreshToken
        saveStoredSession(token, normalizedExpiresAt, refreshToken)
        logger.info(
            "Login session saved: expiresAt=\(normalizedExpiresAt, privacy: .public), refreshTokenProvided=\((refreshToken?.isEmpty == false), privacy: .public)"
        )
        isLoggedIn = true
        await refreshProfile()
        NotificationCenter.default.post(name: .authDidLogin, object: self)
    }

    // MARK: - Logout

    func logout() {
        if let refreshToken = cachedRefreshToken {
            Task {
                try? await AuthAPIService.logout(refreshToken: refreshToken)
            }
        }
        inMemorySessionToken = nil
        cachedStoredToken = nil
        cachedRefreshToken = nil
        clearStoredSession()
        isLoggedIn = false
        userProfile = nil
        subscription = .none
        subscriptionError = nil
        isSyncingSubscription = false
        usageStats = .empty
        usageCredits = nil
        usagePeriodStart = nil
        usagePeriodEnd = nil
        usageError = nil
        pendingCheckoutSubscriptionEntitlement = false
        checkoutPollingTask?.cancel()
        checkoutPollingTask = nil
        logger.info("User logged out")
        NotificationCenter.default.post(name: .authDidLogout, object: self)
    }

    // MARK: - Token Refresh

    /// Refreshes the access token when it will expire within 7 days.
    /// Safe to call from multiple trigger points; skips silently when not needed.
    func refreshTokenIfNeeded() async {
        guard isLoggedIn else { return }
        let result = await refreshStoredAccessToken(force: false)
        if result == .invalidated {
            logout()
        }
    }
}
