@testable import Typeflux
import XCTest

/// Subscription syncs belong to the session that requested them: a result or
/// failure that arrives after logout or a new login is neither applied nor
/// reported to the newer session. Billing links are covered by
/// `AuthStateBillingLinkSessionTests`.
@MainActor
final class AuthStateBillingSessionTests: XCTestCase {
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

    // MARK: - Subscription sync

    func testLateSyncAfterLogoutIsNotApplied() async throws {
        let fixture = BillingSessionFixture()
        await fixture.login(token: "a1")
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .authSubscriptionDidChange, object: fixture.state, queue: nil
        ) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { old in
            try await fixture.syncs.waitForCalls(1)
            fixture.state.logout(clearRecentInputMemory: false)
            fixture.syncs.resolveNext(with: .success(Self.paid))

            let result = try await old.value
            XCTAssertEqual(result, .none)
        })
        XCTAssertEqual(fixture.state.subscription, .none)
        XCTAssertNil(fixture.state.subscriptionError)
        XCTAssertFalse(fixture.state.isSyncingSubscription)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(fixture.syncs.calls, ["a1"])
    }

    func testLateSyncDoesNotOverwriteTheNewLoginsSubscription() async throws {
        let fixture = BillingSessionFixture()
        await fixture.login(token: "a1")
        var changes = 0

        try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { old in
            try await fixture.syncs.waitForCalls(1)
            fixture.refreshedSubscription = Self.free
            await fixture.login(token: "b1")
            let observer = NotificationCenter.default.addObserver(
                forName: .authSubscriptionDidChange, object: fixture.state, queue: nil
            ) { _ in changes += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            fixture.syncs.resolveNext(with: .success(Self.paid))

            let result = try await old.value
            XCTAssertEqual(result, Self.free)
        })
        XCTAssertEqual(fixture.state.subscription, Self.free)
        XCTAssertEqual(fixture.state.accessToken, "b1")
        XCTAssertEqual(changes, 0)
    }

    func testLateSyncFailureAfterLogoutIsNotReported() async throws {
        let fixture = BillingSessionFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { old in
            try await fixture.syncs.waitForCalls(1)
            fixture.state.logout(clearRecentInputMemory: false)
            fixture.syncs.resolveNext(with: .failure(BillingSubscriptionSyncError.rateLimited(retryAfterSeconds: 9)))

            let result = try await old.value
            XCTAssertEqual(result, .none)
        })
        XCTAssertNil(fixture.state.subscriptionError)
        XCTAssertFalse(fixture.state.isSyncingSubscription)
    }

    func testSyncFailureOfTheCurrentSessionIsStillThrown() async throws {
        let fixture = BillingSessionFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { current in
            try await fixture.syncs.waitForCalls(1)
            fixture.syncs.resolveNext(with: .failure(BillingSubscriptionSyncError.rateLimited(retryAfterSeconds: 9)))

            do {
                _ = try await current.value
                XCTFail("Expected the current session's sync error")
            } catch {
                XCTAssertEqual(error as? BillingSubscriptionSyncError, .rateLimited(retryAfterSeconds: 9))
            }
        })
        XCTAssertFalse(fixture.state.isSyncingSubscription)
    }

    func testNewSessionSyncsWhileAReplacedSessionsSyncIsRunning() async throws {
        let fixture = BillingSessionFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { old in
            try await fixture.syncs.waitForCalls(1)
            await fixture.login(token: "b1")
            try await fixture.withTask({ try await fixture.state.syncSubscription() }, body: { current in
                try await fixture.syncs.waitForCalls(2)
                XCTAssertEqual(fixture.syncs.calls, ["a1", "b1"])

                // The replaced sync finishing first must not end the new one's state.
                fixture.syncs.resolveNext(with: .success(Self.free))
                _ = try await old.value
                XCTAssertTrue(fixture.state.isSyncingSubscription)
                // A second request of the new session still shares its running sync.
                let duplicate = try await fixture.state.syncSubscription()
                XCTAssertEqual(duplicate, fixture.state.subscription)
                XCTAssertEqual(fixture.syncs.calls.count, 2)

                fixture.syncs.resolveNext(with: .success(Self.paid))
                let result = try await current.value
                XCTAssertEqual(result, Self.paid)
            })
        })
        XCTAssertEqual(fixture.state.subscription, Self.paid)
        XCTAssertFalse(fixture.state.isSyncingSubscription)
    }

    // MARK: - Helpers

    private static let paid = BillingSubscriptionSnapshot(
        planCode: "pro",
        status: "active",
        currentPeriodStart: nil,
        currentPeriodEnd: "2026-11-01T00:00:00Z",
        cancelAtPeriodEnd: false,
        entitled: true,
        active: true,
        paid: true
    )

    private static let free = BillingSubscriptionSnapshot(
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
}
