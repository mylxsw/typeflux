@testable import Typeflux
import XCTest

/// The three billing link requests that are fenced to their session.
enum BillingLinkKind: CaseIterable {
    case pageToken
    case portal
    case checkout
}

/// How a request's session ends while the request is in flight.
enum SessionReplacement: CaseIterable {
    case logout
    case newLogin
}

/// An `AuthState` whose billing requests stay open until the test settles
/// them. Profile and subscription refreshes answer immediately; a token
/// refresh rotates the session's access token to "a2".
@MainActor
final class BillingSessionFixture {
    let syncs = BillingHeldCalls<BillingSubscriptionSnapshot>()
    let pageTokens = BillingHeldCalls<BillingPageTokenResponse>()
    let portals = BillingHeldCalls<BillingPortalSession>()
    let checkouts = BillingHeldCalls<BillingCheckoutSession>()
    var refreshedSubscription: BillingSubscriptionSnapshot = .none
    private(set) var subscriptionTokens: [String] = []
    private(set) var refreshTokens: [String] = []
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
            refreshAccessToken: { [unowned self] refreshToken in
                refreshTokens.append(refreshToken)
                return LoginResponse(
                    accessToken: "a2",
                    expiresAt: Int(Date().timeIntervalSince1970) + 900,
                    refreshToken: "refresh-a2"
                )
            },
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
        for gate in [syncs, pageTokens, portals, checkouts] as [any BillingHeldCallsClosing] {
            gate.close()
        }
        task.cancel()
        _ = try? await task.value
        let polling = state.checkoutPollingTask
        polling?.cancel()
        await polling?.value
        state.refreshTimer?.invalidate()
    }

    func login(token: String, refreshToken: String? = nil) async {
        await state.handleLoginSuccess(
            token: token,
            expiresAt: Int(Date().timeIntervalSince1970) + 900,
            refreshToken: refreshToken
        )
    }

    func replace(by replacement: SessionReplacement) async {
        switch replacement {
        case .logout:
            state.logout(clearRecentInputMemory: false)
        case .newLogin:
            await login(token: "b1")
        }
    }

    func request(_ kind: BillingLinkKind) -> @MainActor () async throws -> URL {
        switch kind {
        case .pageToken:
            { [state] in try await state!.requestBillingPageToken() }
        case .portal:
            { [state] in try await state!.createBillingPortalSession() }
        case .checkout:
            { [state] in try await state!.startCheckout() }
        }
    }

    func calls(_ kind: BillingLinkKind) -> [String] {
        switch kind {
        case .pageToken: pageTokens.calls
        case .portal: portals.calls
        case .checkout: checkouts.calls
        }
    }

    func waitForCalls(_ kind: BillingLinkKind, _ count: Int) async throws {
        switch kind {
        case .pageToken: try await pageTokens.waitForCalls(count)
        case .portal: try await portals.waitForCalls(count)
        case .checkout: try await checkouts.waitForCalls(count)
        }
    }

    func succeed(_ kind: BillingLinkKind, path: String) {
        let url = URL(string: "https://billing.example/\(path)")!
        switch kind {
        case .pageToken:
            pageTokens.resolveNext(with: .success(BillingPageTokenResponse(token: path, plansURL: url)))
        case .portal:
            portals.resolveNext(with: .success(BillingPortalSession(url: url)))
        case .checkout:
            checkouts.resolveNext(with: .success(BillingCheckoutSession(sessionID: path, url: url)))
        }
    }

    func fail(_ kind: BillingLinkKind, with error: Error) {
        switch kind {
        case .pageToken: pageTokens.resolveNext(with: .failure(error))
        case .portal: portals.resolveNext(with: .failure(error))
        case .checkout: checkouts.resolveNext(with: .failure(error))
        }
    }
}

@MainActor
protocol BillingHeldCallsClosing: AnyObject {
    func close()
}

/// Records each call's argument and keeps it pending until the test settles
/// it. A failed wait or `close()` fails every pending and later call.
@MainActor
final class BillingHeldCalls<Value>: BillingHeldCallsClosing {
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
