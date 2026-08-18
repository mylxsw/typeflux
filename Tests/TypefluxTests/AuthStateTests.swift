@testable import Typeflux
import XCTest

@MainActor
final class AuthStateTests: XCTestCase {
    func testRestoreSessionRefreshesProfileAndPersistsUser() async {
        let fetchExpectation = expectation(description: "fetch profile")
        let storedToken = validStoredToken()
        var savedProfile: UserProfile?
        let profile = makeProfile(email: "refresh@test.com")
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { savedProfile },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { savedProfile = $0 },
            clearStoredSession: {},
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                return profile
            },
            fetchSubscription: { _ in .none }
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(state.userProfile, profile)
        XCTAssertEqual(savedProfile, profile)
    }

    func testRestoreSessionLogsOutWhenProfileRefreshUnauthorized() async {
        let fetchExpectation = expectation(description: "fetch profile")
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        var clearedSession = false
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
                storedToken = nil
            },
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                throw AuthError.unauthorized
            }
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertTrue(clearedSession)
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertNil(state.userProfile)
    }

    func testRestoreSessionKeepsSessionOnNetworkFailure() async {
        let fetchExpectation = expectation(description: "fetch profile")
        let storedToken = validStoredToken()
        var clearedSession = false
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
            },
            fetchProfile: { _ in
                fetchExpectation.fulfill()
                throw AuthError.networkError(NSError(domain: "test", code: -1))
            }
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertFalse(clearedSession)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertNil(state.userProfile)
    }

    func testRestoreSessionRefreshesExpiredAccessTokenWithStoredRefreshToken() async {
        let fetchExpectation = expectation(description: "fetch profile after token refresh")
        var storedToken: (token: String, expiresAt: Int)? = ("old-token", Int(Date().timeIntervalSince1970) - 60)
        var savedRefreshToken: String?
        var fetchedProfileToken: String?
        let profile = makeProfile(email: "restore-refresh@test.com")
        let refreshedExpiry = Int(Date().timeIntervalSince1970) + 3600
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredRefreshToken: { "refresh-token" },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredSession: { token, expiresAt, refreshToken in
                storedToken = (token, expiresAt)
                savedRefreshToken = refreshToken
            },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { token in
                fetchedProfileToken = token
                fetchExpectation.fulfill()
                return profile
            },
            refreshAccessToken: { refreshToken in
                XCTAssertEqual(refreshToken, "refresh-token")
                return LoginResponse(accessToken: "new-token", expiresAt: refreshedExpiry, refreshToken: nil)
            },
            fetchSubscription: { _ in .none }
        )

        await fulfillment(of: [fetchExpectation], timeout: 1.0)
        await waitForRefreshCompletion(state)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(storedToken?.token, "new-token")
        XCTAssertEqual(savedRefreshToken, "refresh-token")
        XCTAssertEqual(fetchedProfileToken, "new-token")
        XCTAssertEqual(state.userProfile, profile)
    }

    func testLoginSuccessRefreshesSubscription() async {
        var storedToken: (token: String, expiresAt: Int)?
        var savedProfile: UserProfile?
        var fetchedSubscriptionToken: String?
        var subscriptionFetchCount = 0
        let profile = makeProfile(email: "billing@test.com")
        let activeSubscription = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { savedProfile = $0 },
            clearStoredSession: {},
            fetchProfile: { _ in profile },
            fetchSubscription: { token in
                subscriptionFetchCount += 1
                fetchedSubscriptionToken = token
                return activeSubscription
            }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(savedProfile, profile)
        XCTAssertEqual(fetchedSubscriptionToken, "token-1")
        XCTAssertEqual(subscriptionFetchCount, 1)
        XCTAssertEqual(state.subscription, activeSubscription)
    }

    func testLoginSuccessKeepsSessionWhenSubscriptionRefreshIsUnauthorized() async {
        var storedToken: (token: String, expiresAt: Int)?
        var savedProfile: UserProfile?
        var clearedSession = false
        let profile = makeProfile(email: "billing-auth@test.com")
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { savedProfile = $0 },
            clearStoredSession: {
                clearedSession = true
                storedToken = nil
            },
            fetchProfile: { _ in profile },
            fetchSubscription: { _ in
                throw AuthError.unauthorized
            }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)

        XCTAssertFalse(clearedSession)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(storedToken?.token, "token-1")
        XCTAssertEqual(savedProfile, profile)
        XCTAssertEqual(state.subscription, .none)
        XCTAssertNotNil(state.subscriptionError)
    }

    func testSubscriptionRefreshFailureFailsBillingVisibilityClosed() async {
        var storedToken: (token: String, expiresAt: Int)?
        var shouldFail = false
        let activeSubscription = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2999-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true,
            active: true,
            paid: true,
            billingEnabled: true
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "billing-fail-closed@test.com") },
            fetchSubscription: { _ in
                if shouldFail { throw AuthError.networkError(URLError(.notConnectedToInternet)) }
                return activeSubscription
            }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        XCTAssertTrue(state.subscription.billingEnabled)

        shouldFail = true
        await state.refreshSubscription()

        XCTAssertFalse(state.subscription.billingEnabled)
        XCTAssertEqual(state.subscription.planCode, BillingPlan.defaultPlanCode)
        XCTAssertNotNil(state.subscriptionError)
    }

    func testLoginSuccessUsesInMemoryTokenWhenPersistenceDoesNotImmediatelyLoad() async {
        var savedProfile: UserProfile?
        var fetchedProfileToken: String?
        let profile = makeProfile(email: "memory-session@test.com")
        let state = AuthState(
            loadStoredToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { savedProfile = $0 },
            clearStoredSession: {},
            fetchProfile: { token in
                fetchedProfileToken = token
                return profile
            },
            fetchSubscription: { _ in .none }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(fetchedProfileToken, "token-1")
        XCTAssertEqual(savedProfile, profile)
    }

    func testProfileUnauthorizedRefreshesAccessTokenBeforeLoggingOut() async {
        var storedToken: (token: String, expiresAt: Int)?
        var savedRefreshToken: String?
        var fetchProfileCallCount = 0
        var clearedSession = false
        let profile = makeProfile(email: "profile-refresh@test.com")
        let refreshedExpiry = Int(Date().timeIntervalSince1970) + 3600
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredRefreshToken: { savedRefreshToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredSession: { token, expiresAt, refreshToken in
                storedToken = (token, expiresAt)
                savedRefreshToken = refreshToken
            },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
                storedToken = nil
                savedRefreshToken = nil
            },
            fetchProfile: { token in
                fetchProfileCallCount += 1
                if fetchProfileCallCount == 1 {
                    XCTAssertEqual(token, "old-token")
                    throw AuthError.unauthorized
                }
                XCTAssertEqual(token, "new-token")
                return profile
            },
            refreshAccessToken: { refreshToken in
                XCTAssertEqual(refreshToken, "refresh-token")
                return LoginResponse(accessToken: "new-token", expiresAt: refreshedExpiry, refreshToken: nil)
            },
            fetchSubscription: { _ in .none }
        )

        await state.handleLoginSuccess(
            token: "old-token",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            refreshToken: "refresh-token"
        )

        XCTAssertFalse(clearedSession)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(fetchProfileCallCount, 2)
        XCTAssertEqual(storedToken?.token, "new-token")
        XCTAssertEqual(savedRefreshToken, "refresh-token")
        XCTAssertEqual(state.userProfile, profile)
    }

    func testLoginSuccessAcceptsRelativeExpirySeconds() async {
        var storedToken: (token: String, expiresAt: Int)?
        let now = Int(Date().timeIntervalSince1970)
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "relative-expiry@test.com") },
            fetchSubscription: { _ in .none }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: 3600)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(storedToken?.token, "token-1")
        XCTAssertGreaterThanOrEqual(storedToken?.expiresAt ?? 0, now + 3600)
    }

    func testLoginSuccessNormalizesMillisecondExpiryTimestamp() async {
        var storedToken: (token: String, expiresAt: Int)?
        let expiresAt = Int(Date().timeIntervalSince1970) + 3600
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "millisecond-expiry@test.com") },
            fetchSubscription: { _ in .none }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: expiresAt * 1000)

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(storedToken?.token, "token-1")
        XCTAssertEqual(storedToken?.expiresAt, expiresAt)
    }

    func testStartCheckoutCreatesSessionAndRefreshesSubscriptionDuringPolling() async throws {
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        var requestedPlanCode: String?
        var refreshCount = 0
        let activeSubscription = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "checkout@test.com") },
            fetchSubscription: { _ in
                refreshCount += 1
                return activeSubscription
            },
            createCheckoutSession: { _, planCode in
                requestedPlanCode = planCode
                return BillingCheckoutSession(
                    sessionID: "cs_test_1",
                    url: URL(string: "https://checkout.stripe.com/cs_test_1")!
                )
            }
        )

        let url = try await state.startCheckout()
        await waitForSubscriptionRefreshCount { refreshCount }

        XCTAssertEqual(url.absoluteString, "https://checkout.stripe.com/cs_test_1")
        XCTAssertEqual(requestedPlanCode, BillingPlan.defaultPlanCode)
        XCTAssertEqual(state.subscription, activeSubscription)
    }

    func testStartCheckoutPostsEntitlementNotificationWhenSubscriptionBecomesActive() async throws {
        var storedToken: (token: String, expiresAt: Int)?
        var checkoutStarted = false
        let activeSubscription = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "checkout-entitled@test.com") },
            fetchSubscription: { _ in checkoutStarted ? activeSubscription : .none },
            createCheckoutSession: { _, _ in
                checkoutStarted = true
                return BillingCheckoutSession(
                    sessionID: "cs_test_1",
                    url: URL(string: "https://checkout.stripe.com/cs_test_1")!
                )
            }
        )
        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        XCTAssertFalse(state.subscription.entitled)

        let expectation = expectation(description: "checkout subscription entitlement notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .authCheckoutSubscriptionDidBecomeEntitled,
            object: state,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        _ = try await state.startCheckout()

        await fulfillment(of: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    func testStartCheckoutPostsEntitlementNotificationWhenFreeSubscriptionBecomesPaid() async throws {
        var storedToken: (token: String, expiresAt: Int)?
        var checkoutStarted = false
        let freeSubscription = BillingSubscriptionSnapshot(
            planCode: "free",
            status: "free",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: true,
            active: true,
            paid: false,
            periodSource: "free"
        )
        let paidSubscription = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true,
            active: true,
            paid: true
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "checkout-free-to-paid@test.com") },
            fetchSubscription: { _ in checkoutStarted ? paidSubscription : freeSubscription },
            createCheckoutSession: { _, _ in
                checkoutStarted = true
                return BillingCheckoutSession(
                    sessionID: "cs_test_1",
                    url: URL(string: "https://checkout.stripe.com/cs_test_1")!
                )
            }
        )
        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        await state.refreshSubscription()
        XCTAssertTrue(state.subscription.entitled)
        XCTAssertTrue(state.subscription.isFreePlan)
        XCTAssertFalse(state.subscription.hasPaidSubscription)

        let expectation = expectation(description: "checkout subscription paid upgrade notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .authCheckoutSubscriptionDidBecomeEntitled,
            object: state,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        _ = try await state.startCheckout()

        await fulfillment(of: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(state.subscription, paidSubscription)
    }

    func testLogoutClearsSubscription() async {
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "logout@test.com") },
            fetchSubscription: { _ in
                BillingSubscriptionSnapshot(
                    planCode: BillingPlan.defaultPlanCode,
                    status: "active",
                    currentPeriodStart: nil,
                    currentPeriodEnd: nil,
                    cancelAtPeriodEnd: false,
                    entitled: true
                )
            }
        )
        await waitForRefreshCompletion(state)
        await state.refreshSubscription()

        let logoutNotification = expectation(description: "logout presence notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .authDidLogout,
            object: state,
            queue: .main
        ) { _ in
            logoutNotification.fulfill()
        }
        state.logout()

        await fulfillment(of: [logoutNotification], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertEqual(state.subscription, .none)
    }

    func testRefreshUsageUsesCurrentSubscriptionPeriod() async {
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        var usageFetchCount = 0
        let stats = CloudUsageStats(
            asrCount: 2,
            asrAudioDurationMs: 60000,
            asrOutputChars: 300,
            chatCount: 1,
            chatOutputChars: 100,
            chatInputTokens: 200,
            chatOutputTokens: 50,
            chatTotalTokens: 250
        )
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "usage@test.com") },
            fetchSubscription: { _ in
                BillingSubscriptionSnapshot(
                    planCode: BillingPlan.defaultPlanCode,
                    status: "active",
                    currentPeriodStart: "2026-05-01T00:00:00Z",
                    currentPeriodEnd: "2026-06-01T00:00:00Z",
                    cancelAtPeriodEnd: false,
                    entitled: true
                )
            },
            fetchCurrentPeriodUsageStats: { _ in
                usageFetchCount += 1
                return CloudUsageCurrentPeriodStats(
                    periodStart: "2026-05-01T00:00:00Z",
                    periodEnd: "2026-06-01T00:00:00Z",
                    stats: stats,
                    credits: CloudCreditSummary(limit: 2000, used: 120, remaining: 1880, unlimited: false)
                )
            }
        )

        await state.refreshSubscription()
        await state.refreshUsage()

        XCTAssertEqual(usageFetchCount, 1)
        XCTAssertEqual(state.usageStats, stats)
        XCTAssertEqual(
            state.usageCredits,
            CloudCreditSummary(limit: 2000, used: 120, remaining: 1880, unlimited: false)
        )
        XCTAssertEqual(state.usagePeriodStart, "2026-05-01T00:00:00Z")
        XCTAssertEqual(state.usagePeriodEnd, "2026-06-01T00:00:00Z")
    }

    func testRefreshUsageSurfacesServerPeriodError() async {
        var storedToken: (token: String, expiresAt: Int)? = validStoredToken()
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: { storedToken = nil },
            fetchProfile: { _ in self.makeProfile(email: "usage@test.com") },
            fetchSubscription: { _ in .none },
            fetchCurrentPeriodUsageStats: { _ in
                throw AuthError.serverError(
                    code: "USAGE_PERIOD_UNAVAILABLE",
                    message: "current billing period is unavailable"
                )
            }
        )

        await state.refreshSubscription()
        await state.refreshUsage()

        XCTAssertEqual(state.usageStats, .empty)
        XCTAssertNil(state.usageCredits)
        XCTAssertNil(state.usagePeriodStart)
        XCTAssertNil(state.usagePeriodEnd)
        XCTAssertNil(state.usageError)
    }

    func testRefreshUsageKeepsSessionWhenUnauthorized() async {
        var storedToken: (token: String, expiresAt: Int)?
        var clearedSession = false
        let state = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, expiresAt in storedToken = (token, expiresAt) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {
                clearedSession = true
                storedToken = nil
            },
            fetchProfile: { _ in self.makeProfile(email: "usage-auth@test.com") },
            fetchSubscription: { _ in .none },
            fetchCurrentPeriodUsageStats: { _ in
                throw AuthError.unauthorized
            }
        )

        await state.handleLoginSuccess(token: "token-1", expiresAt: Int(Date().timeIntervalSince1970) + 3600)
        await state.refreshUsage()

        XCTAssertFalse(clearedSession)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(storedToken?.token, "token-1")
        XCTAssertEqual(state.usageStats, .empty)
        XCTAssertNil(state.usageCredits)
        XCTAssertNotNil(state.usageError)
    }

    private func makeProfile(email: String) -> UserProfile {
        UserProfile(
            id: UUID().uuidString,
            email: email,
            name: "Test User",
            status: 1,
            provider: "password",
            createdAt: "2024-04-09T12:00:00Z",
            updatedAt: "2024-04-09T12:00:00Z"
        )
    }

    private func validStoredToken() -> (token: String, expiresAt: Int) {
        ("valid-token", Int(Date().timeIntervalSince1970) + 3600)
    }

    private func waitForRefreshCompletion(_ state: AuthState) async {
        while state.isLoading {
            await Task.yield()
        }
        await Task.yield()
    }

    private func waitForSubscriptionRefreshCount(_ count: @escaping () -> Int) async {
        for _ in 0 ..< 100 where count() == 0 {
            await Task.yield()
        }
    }
}
