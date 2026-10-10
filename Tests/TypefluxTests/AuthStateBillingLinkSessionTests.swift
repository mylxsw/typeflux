@testable import Typeflux
import XCTest

/// Billing links (checkout, portal, billing page) belong to the session that
/// requested them: a link or failure that arrives after logout or a new login
/// is neither returned, reported, opened nor logged for the newer session,
/// while the current session's failures and a token refresh of the same
/// session keep their outcome.
@MainActor
final class AuthStateBillingLinkSessionTests: XCTestCase {
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

    func testLateLinkForAReplacedSessionIsNotReturned() async throws {
        for kind in BillingLinkKind.allCases {
            for replacement in SessionReplacement.allCases {
                let fixture = BillingSessionFixture()
                await fixture.login(token: "a1")

                try await fixture.withTask(fixture.request(kind), body: { old in
                    try await fixture.waitForCalls(kind, 1)
                    await fixture.replace(by: replacement)
                    fixture.succeed(kind, path: "private-account-a")

                    await Self.assertSessionReplaced("\(kind) after \(replacement)") { try await old.value }
                })
                XCTAssertEqual(fixture.calls(kind), ["a1"], "\(kind) after \(replacement)")
                XCTAssertNil(fixture.state.checkoutPollingTask, "\(kind) after \(replacement)")
                XCTAssertFalse(fixture.state.pendingCheckoutSubscriptionEntitlement, "\(kind) after \(replacement)")
            }
        }
    }

    func testLateLinkFailureForAReplacedSessionIsNotReported() async throws {
        for kind in BillingLinkKind.allCases {
            for replacement in SessionReplacement.allCases {
                let fixture = BillingSessionFixture()
                await fixture.login(token: "a1")

                try await fixture.withTask(fixture.request(kind), body: { old in
                    try await fixture.waitForCalls(kind, 1)
                    await fixture.replace(by: replacement)
                    fixture.fail(kind, with: Self.privateFailure)

                    await Self.assertSessionReplaced("\(kind) after \(replacement)") { try await old.value }
                })
                XCTAssertNil(fixture.state.subscriptionError, "\(kind) after \(replacement)")
                XCTAssertNil(fixture.state.checkoutPollingTask, "\(kind) after \(replacement)")
            }
        }
    }

    func testLinkFailureOfTheCurrentSessionIsThrownUnchanged() async throws {
        for kind in BillingLinkKind.allCases {
            let fixture = BillingSessionFixture()
            await fixture.login(token: "a1")

            try await fixture.withTask(fixture.request(kind), body: { current in
                try await fixture.waitForCalls(kind, 1)
                fixture.fail(kind, with: Self.privateFailure)

                await Self.assertPrivateFailure("\(kind)") { try await current.value }
            })
            XCTAssertNil(fixture.state.checkoutPollingTask, "\(kind)")
            XCTAssertFalse(fixture.state.pendingCheckoutSubscriptionEntitlement, "\(kind)")
        }
    }

    func testLinkOutcomeSurvivesATokenRefreshOfTheSameSession() async throws {
        for kind in BillingLinkKind.allCases {
            for succeeds in [true, false] {
                let fixture = BillingSessionFixture()
                await fixture.login(token: "a1", refreshToken: "refresh-a")

                try await fixture.withTask(fixture.request(kind), body: { current in
                    try await fixture.waitForCalls(kind, 1)
                    let refreshed = await fixture.state.refreshStoredAccessToken(force: true)
                    XCTAssertEqual(refreshed, .refreshed)
                    XCTAssertEqual(fixture.state.accessToken, "a2")

                    if succeeds {
                        fixture.succeed(kind, path: "account-a")
                        let url = try await current.value
                        XCTAssertTrue(url.absoluteString.contains("account-a"), "\(kind): \(url)")
                    } else {
                        fixture.fail(kind, with: Self.privateFailure)
                        await Self.assertPrivateFailure("\(kind)") { try await current.value }
                    }
                })
                XCTAssertEqual(fixture.refreshTokens, ["refresh-a"])
                XCTAssertEqual(fixture.state.checkoutPollingTask != nil, kind == .checkout && succeeds, "\(kind)")
            }
        }
    }

    func testCheckoutOfTheCurrentSessionStillStartsPolling() async throws {
        let fixture = BillingSessionFixture()
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

    // MARK: - Billing callers

    func testCallerDropsALateLinkOrFailureOfAReplacedSession() async throws {
        for kind in [BillingLinkKind.pageToken, .portal] {
            for succeeds in [true, false] {
                let fixture = BillingSessionFixture()
                await fixture.login(token: "a1")
                let caller = BillingCaller()

                try await fixture.withTask({ await caller.open(kind, on: fixture.state) }, body: { opening in
                    try await fixture.waitForCalls(kind, 1)
                    await fixture.login(token: "b1")
                    if succeeds {
                        fixture.succeed(kind, path: "private-account-a")
                    } else {
                        fixture.fail(kind, with: Self.privateFailure)
                    }
                    try await opening.value
                })
                XCTAssertEqual(caller.links, [], "\(kind), succeeds: \(succeeds)")
                XCTAssertEqual(caller.failures, [], "\(kind), succeeds: \(succeeds)")
                XCTAssertEqual(fixture.state.accessToken, "b1")
            }
        }
    }

    func testCallerStillOpensOrReportsTheCurrentSessionsOutcome() async throws {
        for kind in [BillingLinkKind.pageToken, .portal] {
            for succeeds in [true, false] {
                let fixture = BillingSessionFixture()
                await fixture.login(token: "a1")
                let caller = BillingCaller()

                try await fixture.withTask({ await caller.open(kind, on: fixture.state) }, body: { opening in
                    try await fixture.waitForCalls(kind, 1)
                    if succeeds {
                        fixture.succeed(kind, path: "account-a")
                    } else {
                        fixture.fail(kind, with: Self.privateFailure)
                    }
                    try await opening.value
                })
                if succeeds {
                    XCTAssertEqual(caller.links.count, 1, "\(kind)")
                    XCTAssertTrue(caller.links.first?.contains("account-a") == true, "\(kind)")
                    XCTAssertEqual(caller.failures, [], "\(kind)")
                } else {
                    XCTAssertEqual(caller.links, [], "\(kind)")
                    XCTAssertEqual(caller.failures, [Self.privateFailure.localizedDescription], "\(kind)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// A server failure whose message names the old account; it must only
    /// ever reach that account's own session.
    private static let privateFailure = AuthError.serverError(
        code: "CUSTOM_BILLING_FAILURE",
        message: "private-account-a"
    )

    private static func assertSessionReplaced<T>(
        _ context: String,
        _ body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected a replaced-session outcome (\(context))", file: file, line: line)
        } catch let error as BillingSessionReplacedError {
            XCTAssertFalse(
                String(describing: error).contains("private-account-a"),
                "\(context)", file: file, line: line
            )
        } catch {
            XCTFail("Unexpected error \(error) (\(context))", file: file, line: line)
        }
    }

    private static func assertPrivateFailure<T>(
        _ context: String,
        _ body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected the current session's failure (\(context))", file: file, line: line)
        } catch let AuthError.serverError(code, message) {
            XCTAssertEqual(code, "CUSTOM_BILLING_FAILURE", context, file: file, line: line)
            XCTAssertEqual(message, "private-account-a", context, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error) (\(context))", file: file, line: line)
        }
    }
}

/// Stands in for the billing buttons: it opens a destination through the
/// same `AccountBillingFlow.open(_:for:onLink:onFailure:)` they use and
/// records what would be opened or shown.
@MainActor
private final class BillingCaller {
    private(set) var links: [String] = []
    private(set) var failures: [String] = []

    func open(_ kind: BillingLinkKind, on state: AuthState) async {
        await AccountBillingFlow.open(
            kind == .portal ? .billingPortal : .plans,
            for: state,
            onLink: { self.links.append($0.absoluteString) },
            onFailure: { self.failures.append($0.localizedDescription) }
        )
    }
}
