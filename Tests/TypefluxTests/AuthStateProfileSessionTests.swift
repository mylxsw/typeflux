// swiftlint:disable file_length type_body_length
@testable import Typeflux
import XCTest

/// Profile and subscription refreshes belong to the session that started
/// them: an access token that lapsed while the Mac slept is renewed instead of
/// logging out, and a response that arrives after logout or a new login never
/// overwrites, persists for, or logs out the newer session.
@MainActor
final class AuthStateProfileSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
    }

    override func tearDown() {
        KeychainTokenStore.clearAll()
        KeychainTokenStore.useInMemoryStoreForTesting = false
        super.tearDown()
    }

    // MARK: - Expired access token

    func testExpiredAccessTokenIsRenewedBeforeFetchingTheProfile() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "r1", profile: "user-a")
        fixture.expireAccessToken()

        async let result = fixture.state.refreshProfile()
        await fixture.refresh.waitForCalls(1)
        fixture.refresh.resolveNext(with: .success(Self.login(access: "a2", refresh: "r2")))
        await fixture.profiles.waitForCalls(2)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))

        let outcome = await result
        XCTAssertEqual(outcome, .authenticated)
        XCTAssertEqual(fixture.refresh.calls, ["r1"])
        XCTAssertEqual(fixture.profiles.calls, ["a1", "a2"])
        XCTAssertTrue(fixture.state.isLoggedIn)
        XCTAssertEqual(fixture.state.accessToken, "a2")
        XCTAssertEqual(fixture.logoutCount, 0)
    }

    func testConcurrentProfileRefreshesWithAnExpiredTokenShareOneExchange() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "r1", profile: "user-a")
        fixture.expireAccessToken()

        async let first = fixture.state.refreshProfile()
        async let second = fixture.state.refreshProfile()
        await fixture.refresh.waitForCalls(1)
        fixture.refresh.resolveNext(with: .success(Self.login(access: "a2", refresh: "r2")))
        await fixture.profiles.waitForCalls(3)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))

        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.authenticated, .authenticated])
        XCTAssertEqual(fixture.refresh.calls, ["r1"])
        XCTAssertEqual(fixture.profiles.calls, ["a1", "a2", "a2"])
    }

    func testTransientRenewalFailureKeepsTheSession() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "r1", profile: "user-a")
        fixture.expireAccessToken()

        async let result = fixture.state.refreshProfile()
        await fixture.refresh.waitForCalls(1)
        fixture.refresh.resolveNext(with: .failure(AuthError.networkError(URLError(.notConnectedToInternet))))

        let outcome = await result
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fixture.state.isLoggedIn)
        XCTAssertEqual(fixture.state.cachedRefreshToken, "r1")
        XCTAssertEqual(fixture.state.userProfile?.id, "user-a")
        XCTAssertEqual(fixture.profiles.calls, ["a1"])
        XCTAssertEqual(fixture.logoutCount, 0)
    }

    func testRevokedRenewalLogsOutExactlyOnce() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "r1", profile: "user-a")
        fixture.expireAccessToken()

        async let result = fixture.state.refreshProfile()
        await fixture.refresh.waitForCalls(1)
        fixture.refresh.resolveNext(with: .failure(Self.reusedRefreshToken))

        let outcome = await result
        XCTAssertEqual(outcome, .unauthenticated)
        XCTAssertFalse(fixture.state.isLoggedIn)
        XCTAssertNil(fixture.state.cachedRefreshToken)
        XCTAssertEqual(fixture.logoutCount, 1)
        XCTAssertEqual(fixture.profiles.calls, ["a1"])
    }

    func testExpiredTokenWithoutRefreshTokenStillLogsOut() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: nil, profile: "user-a")
        fixture.expireAccessToken()

        let outcome = await fixture.state.refreshProfile()

        XCTAssertEqual(outcome, .unauthenticated)
        XCTAssertFalse(fixture.state.isLoggedIn)
        XCTAssertTrue(fixture.refresh.calls.isEmpty)
        XCTAssertEqual(fixture.logoutCount, 1)
    }

    // MARK: - Responses for a replaced session

    func testLateProfileFromOldSessionDoesNotOverwriteNewLogin() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
        XCTAssertEqual(fixture.persistedProfiles, ["user-a", "user-b"])
        // The discarded response does not fetch a subscription for session A.
        XCTAssertEqual(fixture.subscriptionTokens, ["a1", "b1"])
    }

    func testLateProfileAfterLogoutDoesNotRepopulateTheProfile() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(fixture.state.isLoggedIn)
        XCTAssertNil(fixture.state.userProfile)
        XCTAssertEqual(fixture.persistedProfiles, ["user-a"])
        XCTAssertEqual(fixture.logoutCount, 1)
    }

    func testLateUnauthorizedFromOldSessionDoesNotLogOutNewLogin() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.profiles.resolveNext(with: .failure(AuthError.unauthorized))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fixture.state.isLoggedIn)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(fixture.state.cachedRefreshToken, "rb")
        XCTAssertTrue(fixture.refresh.calls.isEmpty)
        XCTAssertEqual(fixture.logoutCount, 0)
    }

    func testLateNetworkFailureFromOldSessionIsIgnored() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.profiles.resolveNext(with: .failure(URLError(.timedOut)))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
        XCTAssertTrue(fixture.state.isLoggedIn)
    }

    func testRefreshAfterUnauthorizedThatFinishesForANewLoginDoesNotLogItOut() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        fixture.profiles.resolveNext(with: .failure(AuthError.unauthorized))
        await fixture.refresh.waitForCalls(1)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.refresh.resolveNext(with: .success(Self.login(access: "a-late", refresh: "ra-late")))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fixture.state.isLoggedIn)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(fixture.state.cachedRefreshToken, "rb")
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
        XCTAssertEqual(fixture.logoutCount, 0)
    }

    func testLateSubscriptionFromOldSessionIsNotApplied() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .authSubscriptionDidChange, object: fixture.state, queue: nil
        ) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        async let old = fixture.state.refreshSubscription()
        await fixture.waitForHeldSubscription()
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.releaseSubscription(with: .success(Self.paidSubscription()))

        let snapshot = await old
        XCTAssertNil(snapshot)
        XCTAssertEqual(fixture.state.subscription, .none)
        XCTAssertNil(fixture.state.subscriptionError)
        XCTAssertEqual(changes, 0)
    }

    func testLateSubscriptionErrorFromOldSessionIsNotShown() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true

        async let old = fixture.state.refreshSubscription()
        await fixture.waitForHeldSubscription()
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.releaseSubscription(with: .failure(AuthError.networkError(URLError(.timedOut))))

        _ = await old
        XCTAssertNil(fixture.state.subscriptionError)
    }

    // MARK: - Results that outlive their session after the profile arrived

    func testProfileRefreshWhoseSessionEndsDuringTheSubscriptionIsNotAuthenticated() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))
        await fixture.waitForHeldSubscription()
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.releaseSubscription(with: .success(Self.paidSubscription()))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(fixture.state.isLoggedIn)
        XCTAssertNil(fixture.state.userProfile)
        XCTAssertEqual(fixture.state.subscription, .none)
        XCTAssertFalse(fixture.state.isLoading)
    }

    func testProfileRefreshWhoseSessionIsReplacedDuringTheSubscriptionIsNotAuthenticated() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))
        await fixture.waitForHeldSubscription()
        fixture.holdSubscriptions = false
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.releaseSubscription(with: .success(Self.paidSubscription()))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
        // Session B loaded its own subscription although A's was still running.
        XCTAssertEqual(fixture.subscriptionTokens, ["a1", "a1", "b1"])
        XCTAssertEqual(fixture.state.subscription, .none)
        XCTAssertFalse(fixture.state.isLoadingSubscription)
    }

    func testStaleProfileRefreshDoesNotEndTheNewSessionsLoadingState() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshProfile()
        await fixture.profiles.waitForCalls(2)
        async let login: Void = fixture.state.handleLoginSuccess(
            token: "b1", expiresAt: Int(Date().timeIntervalSince1970) + 900, refreshToken: "rb"
        )
        await fixture.profiles.waitForCalls(3)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))

        let outcome = await old
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fixture.state.isLoading, "Session B's profile is still loading")

        fixture.profiles.resolveNext(with: .success(Self.profile("user-b")))
        await login
        XCTAssertFalse(fixture.state.isLoading)
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
    }

    func testLoginWhoseSessionEndsDuringItsProfileFetchIsNotAnnounced() async {
        let fixture = Fixture()
        var logins = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .authDidLogin, object: fixture.state, queue: nil
        ) { _ in logins += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        async let login: Void = fixture.state.handleLoginSuccess(
            token: "a1", expiresAt: Int(Date().timeIntervalSince1970) + 900, refreshToken: "ra"
        )
        await fixture.profiles.waitForCalls(1)
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.profiles.resolveNext(with: .success(Self.profile("user-a")))
        await login

        XCTAssertEqual(logins, 0)
        XCTAssertFalse(fixture.state.isLoggedIn)
        XCTAssertNil(fixture.state.userProfile)

        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        XCTAssertEqual(logins, 1)
    }

    func testNewSessionLoadsItsSubscriptionWhileALoggedOutLoadIsRunning() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true

        async let old = fixture.state.refreshSubscription()
        await fixture.waitForHeldSubscription()
        XCTAssertTrue(fixture.state.isLoadingSubscription)
        fixture.state.logout(clearRecentInputMemory: false)
        XCTAssertFalse(fixture.state.isLoadingSubscription)

        fixture.holdSubscriptions = false
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        XCTAssertEqual(fixture.subscriptionTokens, ["a1", "a1", "b1"])
        XCTAssertFalse(fixture.state.isLoadingSubscription)

        fixture.releaseSubscription(with: .success(Self.paidSubscription()))
        let snapshot = await old
        XCTAssertNil(snapshot)
        XCTAssertEqual(fixture.state.subscription, .none)
        XCTAssertFalse(fixture.state.isLoadingSubscription)
    }

    func testConcurrentSubscriptionRefreshesOfOneSessionStillShareALoad() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")
        fixture.holdSubscriptions = true

        async let first = fixture.state.refreshSubscription()
        await fixture.waitForHeldSubscription()
        let second = await fixture.state.refreshSubscription()
        fixture.releaseSubscription(with: .success(Self.paidSubscription()))

        let loaded = await first
        XCTAssertEqual(second, BillingSubscriptionSnapshot.none)
        XCTAssertEqual(loaded, Self.paidSubscription())
        XCTAssertEqual(fixture.subscriptionTokens, ["a1", "a1"])
        XCTAssertFalse(fixture.state.isLoadingSubscription)
    }

    func testLateUsageFromOldSessionIsNotShown() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshUsage()
        await fixture.usage.waitForCalls(1)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")

        // Session B loads its own usage while A's is still running.
        async let current = fixture.state.refreshUsage()
        await fixture.usage.waitForCalls(2)
        XCTAssertEqual(fixture.usage.calls, ["a1", "b1"])
        fixture.usage.resolveLast(with: .success(Self.usage(period: "period-b")))
        _ = await current
        fixture.usage.resolveNext(with: .success(Self.usage(period: "period-a")))

        let stats = await old
        XCTAssertNil(stats)
        XCTAssertEqual(fixture.state.usagePeriodStart, "period-b")
        XCTAssertFalse(fixture.state.isLoadingUsage)
    }

    func testLateUsageErrorAfterLogoutIsNotShown() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshUsage()
        await fixture.usage.waitForCalls(1)
        fixture.state.logout(clearRecentInputMemory: false)
        XCTAssertFalse(fixture.state.isLoadingUsage)
        fixture.usage.resolveNext(with: .failure(URLError(.timedOut)))

        _ = await old
        XCTAssertNil(fixture.state.usageError)
        XCTAssertEqual(fixture.state.usageStats, .empty)
        XCTAssertFalse(fixture.state.isLoadingUsage)
    }

    func testLateUsageAuthErrorAfterLogoutIsNotShown() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshUsage()
        await fixture.usage.waitForCalls(1)
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.usage.resolveNext(with: .failure(AuthError.serverError(code: "INTERNAL", message: "boom")))

        _ = await old
        XCTAssertNil(fixture.state.usageError)
    }

    func testLateUsageBreakdownFromOldSessionIsNotShown() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshUsageBreakdown()
        await fixture.breakdowns.waitForCalls(1)
        fixture.state.logout(clearRecentInputMemory: false)
        XCTAssertFalse(fixture.state.isLoadingUsageBreakdown)
        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")

        async let current = fixture.state.refreshUsageBreakdown()
        await fixture.breakdowns.waitForCalls(2)
        XCTAssertEqual(fixture.breakdowns.calls, ["a1", "b1"])
        fixture.breakdowns.resolveNext(with: .success(Self.breakdown(period: "period-a")))
        let stale = await old
        XCTAssertNil(stale)
        XCTAssertNil(fixture.state.usageBreakdown)
        XCTAssertTrue(fixture.state.isLoadingUsageBreakdown, "Session B's breakdown is still loading")

        fixture.breakdowns.resolveNext(with: .success(Self.breakdown(period: "period-b")))
        _ = await current
        XCTAssertEqual(fixture.state.usageBreakdown?.periodStart, "period-b")
        XCTAssertFalse(fixture.state.isLoadingUsageBreakdown)
    }

    func testLateUsageBreakdownFailureAfterLogoutIsIgnored() async {
        let fixture = Fixture()
        await fixture.login(token: "a1", refreshToken: "ra", profile: "user-a")

        async let old = fixture.state.refreshUsageBreakdown()
        await fixture.breakdowns.waitForCalls(1)
        fixture.state.logout(clearRecentInputMemory: false)
        fixture.breakdowns.resolveNext(with: .failure(URLError(.timedOut)))

        let result = await old
        XCTAssertNil(result)
        XCTAssertNil(fixture.state.usageBreakdown)
        XCTAssertFalse(fixture.state.isLoadingUsageBreakdown)
    }

    // MARK: - Session restore

    func testRestoreThatFinishesAfterANewLoginLeavesItAlone() async {
        let fixture = Fixture(storedToken: ("expired", Self.now - 60), storedRefreshToken: "r-old")
        await fixture.refresh.waitForCalls(1)
        XCTAssertTrue(fixture.state.isLoggedIn)

        await fixture.login(token: "b1", refreshToken: "rb", profile: "user-b")
        fixture.refresh.resolveNext(with: .failure(Self.reusedRefreshToken))
        for _ in 0 ..< 50 { await Task.yield() }

        XCTAssertTrue(fixture.state.isLoggedIn)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(fixture.state.userProfile?.id, "user-b")
        XCTAssertEqual(fixture.profiles.calls, ["b1"])
        XCTAssertEqual(fixture.logoutCount, 0)
    }

    // MARK: - Helpers

    private static var now: Int {
        Int(Date().timeIntervalSince1970)
    }

    private static let reusedRefreshToken = AuthError.serverError(code: "AUTH_REFRESH_TOKEN_REUSED", message: nil)

    private static func login(access: String, refresh: String?) -> LoginResponse {
        LoginResponse(accessToken: access, expiresAt: now + 900, refreshToken: refresh)
    }

    static func profile(_ id: String) -> UserProfile {
        UserProfile(id: id, email: "\(id)@example.com", name: nil, status: 1, provider: "password",
                    createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z")
    }

    private static func usage(period: String) -> CloudUsageCurrentPeriodStats {
        CloudUsageCurrentPeriodStats(periodStart: period, periodEnd: "2026-11-01T00:00:00Z", stats: .empty)
    }

    private static func breakdown(period: String) -> CloudUsageBreakdown {
        CloudUsageBreakdown(
            periodStart: period, periodEnd: "2026-11-01T00:00:00Z", timezone: "UTC",
            days: [], voice: 0, rewrite: 0, ask: 0
        )
    }

    private static func paidSubscription() -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: "pro",
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-11-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )
    }
}

/// An `AuthState` whose profile and refresh requests stay open until the
/// test settles them, plus a record of what it persisted and notified.
@MainActor
private final class Fixture {
    let refresh = GatedCalls<LoginResponse>()
    let profiles = GatedCalls<UserProfile>()
    let usage = GatedCalls<CloudUsageCurrentPeriodStats>()
    let breakdowns = GatedCalls<CloudUsageBreakdown>()
    private(set) var persistedProfiles: [String] = []
    private(set) var subscriptionTokens: [String] = []
    private(set) var logoutCount = 0
    var holdSubscriptions = false
    private var heldSubscription: CheckedContinuation<BillingSubscriptionSnapshot, Error>?
    private var observer: NSObjectProtocol?
    private(set) var state: AuthState!

    init(storedToken: (String, Int)? = nil, storedRefreshToken: String? = nil) {
        state = AuthState(
            loadStoredToken: { storedToken.map { (token: $0.0, expiresAt: $0.1) } },
            loadStoredRefreshToken: { storedRefreshToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredSession: { _, _, _ in },
            saveStoredUserProfile: { [unowned self] profile in persistedProfiles.append(profile.id) },
            clearStoredSession: {},
            fetchProfile: { [unowned self] token in try await profiles.next(token) },
            refreshAccessToken: { [unowned self] token in try await refresh.next(token) },
            fetchSubscription: { [unowned self] token in
                subscriptionTokens.append(token)
                guard holdSubscriptions else { return .none }
                return try await withCheckedThrowingContinuation { heldSubscription = $0 }
            },
            fetchCurrentPeriodUsageStats: { [unowned self] token in try await usage.next(token) },
            fetchCurrentPeriodUsageBreakdown: { [unowned self] token, _ in try await breakdowns.next(token) }
        )
        observer = NotificationCenter.default.addObserver(
            forName: .authDidLogout, object: state, queue: nil
        ) { [unowned self] _ in
            MainActor.assumeIsolated { logoutCount += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Completes an explicit login, answering its profile request.
    func login(token: String, refreshToken: String?, profile: String) async {
        let profileCalls = profiles.calls.count
        async let login: Void = state.handleLoginSuccess(
            token: token,
            expiresAt: Int(Date().timeIntervalSince1970) + 900,
            refreshToken: refreshToken
        )
        await profiles.waitForCalls(profileCalls + 1)
        profiles.resolveLast(with: .success(AuthStateProfileSessionTests.profile(profile)))
        await login
    }

    func expireAccessToken() {
        let expired = Int(Date().timeIntervalSince1970) - 30
        if let token = state.inMemorySessionToken?.token {
            state.inMemorySessionToken = (token, expired)
            state.cachedStoredToken = (token, expired)
        }
    }

    func waitForHeldSubscription() async {
        for _ in 0 ..< 1000 where heldSubscription == nil {
            await Task.yield()
        }
    }

    func releaseSubscription(with result: Result<BillingSubscriptionSnapshot, Error>) {
        heldSubscription?.resume(with: result)
        heldSubscription = nil
    }
}

/// Records each call's argument and keeps it pending until the test settles it.
@MainActor
private final class GatedCalls<Value> {
    private(set) var calls: [String] = []
    private var pending: [CheckedContinuation<Value, Error>] = []

    func next(_ argument: String) async throws -> Value {
        calls.append(argument)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0 ..< 1000 where calls.count < count {
            await Task.yield()
        }
    }

    /// Settles the oldest pending call.
    func resolveNext(with result: Result<Value, Error>) {
        guard !pending.isEmpty else {
            XCTFail("No call is waiting")
            return
        }
        pending.removeFirst().resume(with: result)
    }

    /// Settles the newest pending call.
    func resolveLast(with result: Result<Value, Error>) {
        guard !pending.isEmpty else {
            XCTFail("No call is waiting")
            return
        }
        pending.removeLast().resume(with: result)
    }
}
