@testable import Typeflux
import XCTest

/// Subscription syncs and billing links belong to the session that requested
/// them: a result that arrives after logout or a new login is neither applied
/// to, reported to, nor opened for the newer session.
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
        let fixture = BillingFixture()
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
        let fixture = BillingFixture()
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
        let fixture = BillingFixture()
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
        let fixture = BillingFixture()
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
        let fixture = BillingFixture()
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

    // MARK: - Billing links

    func testLateBillingPageLinkAfterLogoutIsNotReturned() async throws {
        let fixture = BillingFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.requestBillingPageToken() }, body: { old in
            try await fixture.pageTokens.waitForCalls(1)
            fixture.state.logout(clearRecentInputMemory: false)
            fixture.pageTokens.resolveNext(with: .success(BillingPageTokenResponse(
                token: "page-a",
                plansURL: URL(string: "https://billing.example/plans#t=page-a")!
            )))

            await Self.assertUnauthorized { try await old.value }
        })
    }

    func testLatePortalLinkForAReplacedSessionIsNotReturned() async throws {
        let fixture = BillingFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.createBillingPortalSession() }, body: { old in
            try await fixture.portals.waitForCalls(1)
            await fixture.login(token: "b1")
            fixture.portals.resolveNext(with: .success(BillingPortalSession(
                url: URL(string: "https://billing.stripe.example/portal-a")!
            )))

            await Self.assertUnauthorized { try await old.value }
        })
        XCTAssertEqual(fixture.portals.calls, ["a1"])
    }

    func testLateCheckoutForAReplacedSessionStartsNoPolling() async throws {
        let fixture = BillingFixture()
        await fixture.login(token: "a1")
        var refreshesAfterLogin = 0

        try await fixture.withTask({ try await fixture.state.startCheckout() }, body: { old in
            try await fixture.checkouts.waitForCalls(1)
            await fixture.login(token: "b1")
            refreshesAfterLogin = fixture.subscriptionTokens.count
            fixture.checkouts.resolveNext(with: .success(BillingCheckoutSession(
                sessionID: "cs_a",
                url: URL(string: "https://checkout.stripe.example/cs_a")!
            )))

            await Self.assertUnauthorized { try await old.value }
        })
        XCTAssertNil(fixture.state.checkoutPollingTask)
        XCTAssertFalse(fixture.state.pendingCheckoutSubscriptionEntitlement)
        XCTAssertEqual(fixture.subscriptionTokens, ["a1", "b1"])
        XCTAssertEqual(fixture.subscriptionTokens.count, refreshesAfterLogin)
    }

    func testCheckoutOfTheCurrentSessionStillStartsPolling() async throws {
        let fixture = BillingFixture()
        await fixture.login(token: "a1")

        try await fixture.withTask({ try await fixture.state.startCheckout() }, body: { current in
            try await fixture.checkouts.waitForCalls(1)
            fixture.checkouts.resolveNext(with: .success(BillingCheckoutSession(
                sessionID: "cs_a",
                url: URL(string: "https://checkout.stripe.example/cs_a")!
            )))

            let url = try await current.value
            XCTAssertEqual(url.absoluteString, "https://checkout.stripe.example/cs_a")
        })
        XCTAssertNotNil(fixture.state.checkoutPollingTask)
        XCTAssertTrue(fixture.state.pendingCheckoutSubscriptionEntitlement)
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

    private static func assertUnauthorized<T>(
        _ body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected unauthorized", file: file, line: line)
        } catch AuthError.unauthorized {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

/// An `AuthState` whose billing requests stay open until the test settles
/// them. Profile and subscription refreshes answer immediately.
@MainActor
private final class BillingFixture {
    let syncs = HeldCalls<BillingSubscriptionSnapshot>()
    let pageTokens = HeldCalls<BillingPageTokenResponse>()
    let portals = HeldCalls<BillingPortalSession>()
    let checkouts = HeldCalls<BillingCheckoutSession>()
    var refreshedSubscription: BillingSubscriptionSnapshot = .none
    private(set) var subscriptionTokens: [String] = []
    private(set) var state: AuthState!

    init() {
        state = AuthState(
            loadStoredToken: { nil },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredSession: { _, _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { token in AuthStateProfileSessionTests.profile("user-\(token)") },
            refreshAccessToken: { _ in throw AuthError.unauthorized },
            fetchSubscription: { [unowned self] token in
                subscriptionTokens.append(token)
                return refreshedSubscription
            },
            syncSubscription: { [unowned self] token in try await syncs.next(token) },
            createCheckoutSession: { [unowned self] token, _ in try await checkouts.next(token) },
            createPortalSession: { [unowned self] token in try await portals.next(token) },
            issueBillingPageToken: { [unowned self] token in try await pageTokens.next(token) }
        )
    }

    /// Runs `operation` in a task that `body` drives. On every exit, normal
    /// or thrown, held calls are failed and the task and any checkout polling
    /// it started are cancelled and joined, so nothing outlives the test.
    func withTask<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T,
        body: (Task<T, Error>) async throws -> Void
    ) async throws {
        let task = Task { try await operation() }
        do {
            try await body(task)
        } catch {
            await finish(task)
            throw error
        }
        await finish(task)
    }

    private func finish<T: Sendable>(_ task: Task<T, Error>) async {
        for gate in [syncs, pageTokens, portals, checkouts] as [any HeldCallsClosing] {
            gate.close()
        }
        task.cancel()
        _ = try? await task.value
        let polling = state.checkoutPollingTask
        polling?.cancel()
        await polling?.value
        state.refreshTimer?.invalidate()
    }

    func login(token: String) async {
        await state.handleLoginSuccess(token: token, expiresAt: Int(Date().timeIntervalSince1970) + 900)
    }
}

@MainActor
private protocol HeldCallsClosing: AnyObject {
    func close()
}

/// Records each call's argument and keeps it pending until the test settles
/// it. A failed wait or `close()` fails every pending and later call.
@MainActor
private final class HeldCalls<Value>: HeldCallsClosing {
    private(set) var calls: [String] = []
    private var pending: [CheckedContinuation<Value, Error>] = []
    private var closed = false

    func next(_ argument: String) async throws -> Value {
        calls.append(argument)
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        do {
            while calls.count < count {
                guard ContinuousClock.now < deadline else { throw GateWaitError.timedOut }
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch {
            close()
            throw error
        }
    }

    func resolveNext(with result: Result<Value, Error>) {
        guard !pending.isEmpty else {
            XCTFail("No call is waiting")
            return
        }
        pending.removeFirst().resume(with: result)
    }

    func close() {
        closed = true
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }
}
