@testable import Typeflux
import XCTest

@MainActor
final class AuthStateAccountSummaryTests: XCTestCase {
    private static let breakdown = CloudUsageBreakdown(
        periodStart: "2026-10-01T00:00:00Z", periodEnd: "2026-11-01T00:00:00Z", timezone: "Asia/Shanghai",
        days: [.init(date: "2026-10-02", voice: 3, rewrite: 2, ask: 1)], voice: 3, rewrite: 2, ask: 1
    )

    private func makeState(
        breakdown: @escaping (String, TimeZone) async throws -> CloudUsageBreakdown = { _, _ in breakdown },
        onSubscription: @escaping () -> Void = {},
        onUsage: @escaping () -> Void = {}
    ) -> AuthState {
        AuthState(
            loadStoredToken: { ("valid-token", Int(Date().timeIntervalSince1970) + 3600) },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in
                UserProfile(id: "u", email: "a@b.c", name: nil, status: 1, provider: "google",
                            createdAt: "2026-03-01T00:00:00Z", updatedAt: "2026-03-01T00:00:00Z")
            },
            fetchSubscription: { _ in
                onSubscription()
                return BillingSubscriptionSnapshot(planCode: "free", status: "free", currentPeriodStart: nil,
                                                   currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true)
            },
            fetchCurrentPeriodUsageStats: { _ in
                onUsage()
                return CloudUsageCurrentPeriodStats(periodStart: "2026-10-01T00:00:00Z",
                                                    periodEnd: "2026-11-01T00:00:00Z", stats: .empty)
            },
            fetchCurrentPeriodUsageBreakdown: breakdown
        )
    }

    func testBreakdownRefreshPassesTheTimeZoneAndStoresTheResult() async {
        var zone: TimeZone?
        let state = makeState(breakdown: { _, timeZone in
            zone = timeZone
            return Self.breakdown
        })
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let result = await state.refreshUsageBreakdown(timeZone: tokyo)
        XCTAssertEqual(result, Self.breakdown)
        XCTAssertEqual(state.usageBreakdown, Self.breakdown)
        XCTAssertEqual(zone, tokyo)
        XCTAssertFalse(state.isLoadingUsageBreakdown)
    }

    func testBreakdownFailureHidesTheCharts() async {
        var fail = false
        let state = makeState(breakdown: { _, _ in
            if fail { throw AuthError.serverError(code: "NOT_IMPLEMENTED", message: nil) }
            return Self.breakdown
        })
        await state.refreshUsageBreakdown()
        XCTAssertNotNil(state.usageBreakdown)
        fail = true
        let result = await state.refreshUsageBreakdown()
        XCTAssertNil(result)
        XCTAssertNil(state.usageBreakdown)
    }

    func testBreakdownCancellationKeepsWhatWasShown() async {
        var cancel = false
        let state = makeState(breakdown: { _, _ in
            if cancel { throw CancellationError() }
            return Self.breakdown
        })
        await state.refreshUsageBreakdown()
        cancel = true
        let result = await state.refreshUsageBreakdown()
        XCTAssertEqual(result, Self.breakdown)
        XCTAssertEqual(state.usageBreakdown, Self.breakdown)
    }

    func testBreakdownNeedsASession() async {
        let state = makeState()
        state.logout()
        let result = await state.refreshUsageBreakdown()
        XCTAssertNil(result)
        XCTAssertNil(state.usageBreakdown)
    }

    func testAccountSummaryRefreshIsThrottledUntilInvalidated() async {
        var subscriptions = 0, usages = 0
        let state = makeState(onSubscription: { subscriptions += 1 }, onUsage: { usages += 1 })
        let now = Date()
        await state.refreshAccountSummary(now: now)
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(usages, 1)
        await state.refreshAccountSummary(now: now.addingTimeInterval(30))
        XCTAssertEqual(subscriptions, 1, "Within a minute the hover does not refetch.")
        await state.refreshAccountSummary(now: now.addingTimeInterval(61))
        XCTAssertEqual(subscriptions, 2)
        state.invalidateAccountSummary()
        await state.refreshAccountSummary(now: now.addingTimeInterval(62))
        XCTAssertEqual(subscriptions, 3)
        XCTAssertEqual(usages, 3)
    }

    func testAccountSummaryIsSkippedWhenSignedOutAndResetOnLogout() async {
        var subscriptions = 0
        let state = makeState(onSubscription: { subscriptions += 1 })
        await state.refreshUsageBreakdown()
        await state.refreshAccountSummary()
        XCTAssertNotNil(state.lastAccountSummaryRefresh)
        state.logout()
        XCTAssertNil(state.lastAccountSummaryRefresh)
        XCTAssertNil(state.usageBreakdown)
        let before = subscriptions
        await state.refreshAccountSummary()
        XCTAssertEqual(subscriptions, before)
        XCTAssertNil(state.lastAccountSummaryRefresh)
    }

    func testStatusDestinationsMapOntoTheBillingFlow() async throws {
        let plans = URL(string: "https://billing.example/plans")!
        let portal = URL(string: "https://billing.example/portal")!
        let toPlans = try await AccountBillingFlow.destination(
            for: AccountStatusPresentation.Destination.plans,
            requestBillingPageToken: { plans }, createPortalSession: { portal }
        )
        let toPortal = try await AccountBillingFlow.destination(
            for: AccountStatusPresentation.Destination.billingPortal,
            requestBillingPageToken: { plans }, createPortalSession: { portal }
        )
        XCTAssertEqual(toPlans, plans)
        XCTAssertEqual(toPortal, portal)
    }
}
