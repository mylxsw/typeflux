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

    /// Posted after an access token is refreshed, including silent session
    /// restoration where `authDidLogin` is intentionally not emitted.
    static let authTokenDidRefresh = Notification.Name("AuthState.authTokenDidRefresh")

    /// Posted after the server-backed subscription snapshot is refreshed.
    static let authSubscriptionDidChange = Notification.Name("AuthState.authSubscriptionDidChange")

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
    let fetchCurrentPeriodUsageBreakdown: (String, TimeZone) async throws -> CloudUsageBreakdown
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
    /// Credits per day and per feature; nil until loaded or when the server lacks the endpoint.
    @Published var usageBreakdown: CloudUsageBreakdown?
    @Published var isLoadingUsageBreakdown: Bool = false

    /// Refresh the access token when it expires within this window (7 days).
    static let refreshEarlyInterval: TimeInterval = 7 * 24 * 3600

    /// Longest delay between background refresh checks.
    static let timerInterval: TimeInterval = 3600
    /// Shortest delay between background refresh checks, which also bounds
    /// retries after a failed refresh.
    static let minimumTimerInterval: TimeInterval = 60
    /// `validAccessToken()` refreshes synchronously only inside this window.
    static let validTokenRefreshLeadTime: TimeInterval = 60
    static let checkoutPollingAttempts = 120
    static let checkoutPollingInterval: Duration = .seconds(3)

    var refreshTimer: Timer?
    var checkoutPollingTask: Task<Void, Never>?
    var pendingCheckoutSubscriptionEntitlement = false
    /// When the account summary (subscription + usage) was last fetched for the
    /// account card; throttles refreshes triggered by hovering and app activation.
    var lastAccountSummaryRefresh: Date?
    var inMemorySessionToken: (token: String, expiresAt: Int)?
    var cachedStoredToken: (token: String, expiresAt: Int)?
    var cachedRefreshToken: String?
    /// The single in-flight refresh. The server revokes the whole refresh
    /// family when a consumed refresh token is replayed, so concurrent callers
    /// must share one exchange instead of racing with the same token.
    var accessTokenRefreshTask: Task<AccessTokenRefreshResult, Never>?
    /// Incremented on login and logout so a refresh that started for an older
    /// session cannot overwrite or invalidate the current one.
    var sessionGeneration = 0
    /// Profile refreshes that are running; `isLoading` is true while any is.
    var profileRefreshesInFlight = 0
    /// The session whose subscription, usage or usage breakdown load is
    /// running, if any. The matching `isLoading…` flag belongs to that load.
    var subscriptionLoadGeneration: Int?
    var usageLoadGeneration: Int?
    var usageBreakdownLoadGeneration: Int?
    /// The session whose subscription sync is running, if any;
    /// `isSyncingSubscription` belongs to that sync.
    var subscriptionSyncGeneration: Int?

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
        fetchCurrentPeriodUsageBreakdown: @escaping (String, TimeZone) async throws -> CloudUsageBreakdown =
            CloudUsageAPIService.fetchCurrentPeriodBreakdown(token:timeZone:),
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
        self.fetchCurrentPeriodUsageBreakdown = fetchCurrentPeriodUsageBreakdown
        self.createCheckoutSession = createCheckoutSession
        self.createPortalSession = createPortalSession
        self.issueBillingPageToken = issueBillingPageToken
        restoreSession()
    }

    // MARK: - Login

    func handleLoginSuccess(token: String, expiresAt: Int, refreshToken: String? = nil) async {
        RecentInputMemoryStore.shared.invalidateObservations()
        let normalizedExpiresAt = normalizeLoginExpiry(expiresAt)
        sessionGeneration += 1
        accessTokenRefreshTask = nil
        inMemorySessionToken = (token, normalizedExpiresAt)
        cachedStoredToken = (token, normalizedExpiresAt)
        cachedRefreshToken = refreshToken
        saveStoredSession(token, normalizedExpiresAt, refreshToken)
        logger.info(
            "Login session saved: expiresAt=\(normalizedExpiresAt, privacy: .public), refreshTokenProvided=\((refreshToken?.isEmpty == false), privacy: .public)"
        )
        isLoggedIn = true
        startRefreshTimer()
        let generation = sessionGeneration
        await refreshProfile()
        // A logout or another login during the profile fetch owns the
        // session now; this login must not announce itself afterwards.
        guard generation == sessionGeneration else { return }
        NotificationCenter.default.post(name: .authDidLogin, object: self)
    }

    // MARK: - Logout

    func logout(clearRecentInputMemory: Bool = true) {
        RecentInputMemoryStore.shared.invalidateObservations()
        if clearRecentInputMemory {
            RecentInputMemoryStore.shared.clear(owner: userProfile?.id ?? loadStoredUserProfile()?.id ?? "local")
        }
        if let refreshToken = cachedRefreshToken {
            Task {
                try? await AuthAPIService.logout(refreshToken: refreshToken)
            }
        }
        sessionGeneration += 1
        accessTokenRefreshTask = nil
        inMemorySessionToken = nil
        cachedStoredToken = nil
        cachedRefreshToken = nil
        clearStoredSession()
        isLoggedIn = false
        userProfile = nil
        subscription = .none
        subscriptionError = nil
        subscriptionSyncGeneration = nil
        isSyncingSubscription = false
        // Loads still running for the old session no longer own these flags.
        subscriptionLoadGeneration = nil
        isLoadingSubscription = false
        usageLoadGeneration = nil
        isLoadingUsage = false
        usageBreakdownLoadGeneration = nil
        isLoadingUsageBreakdown = false
        usageStats = .empty
        usageCredits = nil
        usagePeriodStart = nil
        usagePeriodEnd = nil
        usageError = nil
        usageBreakdown = nil
        lastAccountSummaryRefresh = nil
        pendingCheckoutSubscriptionEntitlement = false
        checkoutPollingTask?.cancel()
        checkoutPollingTask = nil
        logger.info("User logged out")
        NotificationCenter.default.post(name: .authDidLogout, object: self)
    }

    // MARK: - Token Refresh

    /// Refreshes the access token when it is inside its refresh lead time
    /// (see `accessTokenRefreshLeadTime`). Safe to call from multiple trigger
    /// points; concurrent calls share one refresh request.
    func refreshTokenIfNeeded() async {
        guard isLoggedIn else { return }
        let generation = sessionGeneration
        let result = await refreshStoredAccessToken(force: false)
        if result == .invalidated, generation == sessionGeneration {
            logout(clearRecentInputMemory: false)
        }
    }

    /// Returns a usable access token, refreshing it first when it has expired
    /// or is about to. Returns nil when the session is gone or was revoked.
    func validAccessToken() async -> String? {
        guard isLoggedIn else { return accessToken }
        let remaining = accessTokenExpiresAt.map { TimeInterval($0) - Date().timeIntervalSince1970 } ?? 0
        if remaining < Self.validTokenRefreshLeadTime, hasStoredRefreshToken {
            let generation = sessionGeneration
            let result = await refreshStoredAccessToken(force: true)
            if result == .invalidated, generation == sessionGeneration {
                logout(clearRecentInputMemory: false)
            }
        }
        return accessToken
    }

    /// A usable access token together with the session it belongs to, read
    /// without a suspension in between so the two always match.
    func validSessionCredential() async -> TypefluxCloudSessionCredential? {
        guard let token = await validAccessToken() else { return nil }
        return TypefluxCloudSessionCredential(accessToken: token, session: sessionGeneration)
    }
}
