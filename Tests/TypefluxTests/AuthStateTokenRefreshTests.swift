@testable import Typeflux
import XCTest

/// Covers refresh behavior required by the API's session contract: refresh
/// tokens rotate and a replayed one revokes the whole family, so refreshes must
/// be serialized; access tokens default to a 15-minute lifetime.
@MainActor
final class AuthStateTokenRefreshTests: XCTestCase {
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

    // MARK: - Single flight

    func testConcurrentRefreshesShareOneExchange() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        // Inside the 300-second lead time, so the non-forced caller needs it too.
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 100, refreshToken: "r1")

        async let first = state.refreshStoredAccessToken(force: true)
        async let second = state.refreshStoredAccessToken(force: true)
        async let third = state.refreshStoredAccessToken(force: false)
        await probe.waitForCalls(1)
        probe.resolveNext(with: .success(Self.login(access: "a2", refresh: "r2")))

        let results = await [first, second, third]
        XCTAssertEqual(results, [.refreshed, .refreshed, .refreshed])
        XCTAssertEqual(probe.calls, ["r1"])
        XCTAssertEqual(state.accessToken, "a2")
        XCTAssertEqual(state.cachedRefreshToken, "r2")
        XCTAssertNil(state.accessTokenRefreshTask)
    }

    func testSequentialRefreshesUseTheRotatedRefreshToken() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 900, refreshToken: "r1")

        async let first = state.refreshStoredAccessToken(force: true)
        await probe.waitForCalls(1)
        probe.resolveNext(with: .success(Self.login(access: "a2", refresh: "r2")))
        _ = await first

        async let second = state.refreshStoredAccessToken(force: true)
        await probe.waitForCalls(2)
        probe.resolveNext(with: .success(Self.login(access: "a3", refresh: nil)))
        _ = await second

        XCTAssertEqual(probe.calls, ["r1", "r2"])
        XCTAssertEqual(state.accessToken, "a3")
        // A response without a rotated refresh token keeps the current one.
        XCTAssertEqual(state.cachedRefreshToken, "r2")
    }

    func testRefreshFinishingAfterLogoutDoesNotRestoreTheSession() async {
        let probe = RefreshProbe()
        var savedTokens: [String] = []
        let state = makeState(probe: probe, onSave: { savedTokens.append($0) })
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 900, refreshToken: "r1")
        savedTokens.removeAll()

        async let refresh = state.refreshStoredAccessToken(force: true)
        await probe.waitForCalls(1)
        state.logout(clearRecentInputMemory: false)
        probe.resolveNext(with: .success(Self.login(access: "late", refresh: "late-refresh")))

        let result = await refresh
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertNil(state.accessToken)
        XCTAssertNil(state.cachedRefreshToken)
        XCTAssertTrue(savedTokens.isEmpty)
    }

    func testRevocationFromAnOldSessionDoesNotLogOutANewLogin() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 100, refreshToken: "old")

        async let refresh: Void = state.refreshTokenIfNeeded()
        await probe.waitForCalls(1)
        await state.handleLoginSuccess(token: "fresh", expiresAt: Self.now + 900, refreshToken: "new")
        probe.resolveNext(with: .failure(AuthError.serverError(code: "AUTH_REFRESH_TOKEN_REUSED", message: nil)))
        await refresh

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(state.accessToken, "fresh")
        XCTAssertEqual(state.cachedRefreshToken, "new")
    }

    func testReplayedRefreshTokenLogsOutOnceWithoutRetrying() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 100, refreshToken: "r1")

        async let refresh: Void = state.refreshTokenIfNeeded()
        await probe.waitForCalls(1)
        probe.resolveNext(with: .failure(AuthError.serverError(code: "AUTH_REFRESH_TOKEN_REUSED", message: nil)))
        await refresh

        XCTAssertFalse(state.isLoggedIn)
        XCTAssertNil(state.accessToken)
        // No refresh token is left, so later triggers cannot loop.
        let later = await state.refreshStoredAccessToken(force: true)
        XCTAssertEqual(later, .unavailable)
        XCTAssertEqual(probe.calls, ["r1"])
    }

    func testTransientRefreshFailureKeepsTheSession() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        let token = Self.jwt(lifetime: 900)
        await state.handleLoginSuccess(token: token, expiresAt: Self.now + 100, refreshToken: "r1")

        async let refresh: Void = state.refreshTokenIfNeeded()
        await probe.waitForCalls(1)
        probe.resolveNext(with: .failure(AuthError.networkError(URLError(.timedOut))))
        await refresh

        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(state.accessToken, token)
        XCTAssertEqual(state.cachedRefreshToken, "r1")
        XCTAssertNil(state.accessTokenRefreshTask)
    }

    func testUnexpectedRefreshErrorIsTreatedAsTransient() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 100, refreshToken: "r1")

        async let refresh = state.refreshStoredAccessToken(force: false)
        await probe.waitForCalls(1)
        probe.resolveNext(with: .failure(URLError(.notConnectedToInternet)))

        let result = await refresh
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(state.isLoggedIn)
        XCTAssertEqual(state.cachedRefreshToken, "r1")
    }

    // MARK: - Lifetime-aware scheduling

    func testRefreshLeadTimeFollowsTheSignedLifetime() async {
        let state = makeState(probe: RefreshProbe())
        let cases: [(String, TimeInterval)] = [
            (Self.jwt(lifetime: 900), 300),
            (Self.jwt(lifetime: 30 * 24 * 3600), AuthState.refreshEarlyInterval),
            (Self.jwt(lifetime: 90), AuthState.minimumTimerInterval),
            ("opaque-token", AuthState.refreshEarlyInterval),
        ]
        for (token, expected) in cases {
            await state.handleLoginSuccess(token: token, expiresAt: Self.now + 900, refreshToken: nil)
            XCTAssertEqual(state.accessTokenRefreshLeadTime(), expected, token)
        }
    }

    func testShortLivedTokenIsRenewedBeforeItExpires() async {
        let state = makeState(probe: RefreshProbe())
        let token = Self.jwt(lifetime: 900)

        await state.handleLoginSuccess(token: token, expiresAt: Self.now + 900, refreshToken: "r1")
        XCTAssertFalse(state.isAccessTokenExpiringSoon())
        XCTAssertEqual(state.nextRefreshCheckDelay(), 600, accuracy: 2)

        await state.handleLoginSuccess(token: token, expiresAt: Self.now + 200, refreshToken: "r1")
        XCTAssertTrue(state.isAccessTokenExpiringSoon())
        XCTAssertEqual(state.nextRefreshCheckDelay(), AuthState.minimumTimerInterval)

        await state.handleLoginSuccess(
            token: Self.jwt(lifetime: 30 * 24 * 3600),
            expiresAt: Self.now + 30 * 24 * 3600,
            refreshToken: "r1"
        )
        XCTAssertEqual(state.nextRefreshCheckDelay(), AuthState.timerInterval)

        state.logout(clearRecentInputMemory: false)
        XCTAssertEqual(state.nextRefreshCheckDelay(), AuthState.timerInterval)
        XCTAssertTrue(state.isAccessTokenExpiringSoon())
    }

    func testAccessTokenClaimsRejectNonJWTValues() {
        XCTAssertEqual(AccessTokenClaims.lifetime(of: Self.jwt(lifetime: 900)), 900)
        XCTAssertNil(AccessTokenClaims.lifetime(of: "a.b"))
        XCTAssertNil(AccessTokenClaims.lifetime(of: "a.%%%.c"))
        XCTAssertNil(AccessTokenClaims.lifetime(of: Self.jwt(payload: #"{"exp":100}"#)))
        XCTAssertNil(AccessTokenClaims.lifetime(of: Self.jwt(payload: #"{"iat":200,"exp":100}"#)))
    }

    // MARK: - validAccessToken

    func testValidAccessTokenRefreshesAnAlmostExpiredToken() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 30, refreshToken: "r1")

        async let token = state.validAccessToken()
        await probe.waitForCalls(1)
        probe.resolveNext(with: .success(Self.login(access: "a2", refresh: "r2")))

        let value = await token
        XCTAssertEqual(value, "a2")
    }

    func testValidAccessTokenReturnsAHealthyTokenWithoutRefreshing() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        let token = Self.jwt(lifetime: 900)
        await state.handleLoginSuccess(token: token, expiresAt: Self.now + 600, refreshToken: "r1")

        let value = await state.validAccessToken()
        XCTAssertEqual(value, token)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testValidAccessTokenAfterRevocationReturnsNilAndLogsOut() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        await state.handleLoginSuccess(token: Self.jwt(lifetime: 900), expiresAt: Self.now + 10, refreshToken: "r1")

        async let token = state.validAccessToken()
        await probe.waitForCalls(1)
        probe.resolveNext(with: .failure(AuthError.unauthorized))

        let value = await token
        XCTAssertNil(value)
        XCTAssertFalse(state.isLoggedIn)
    }

    func testValidAccessTokenWithoutSessionDoesNotRefresh() async {
        let probe = RefreshProbe()
        let state = makeState(probe: probe)
        let value = await state.validAccessToken()
        XCTAssertNil(value)
        XCTAssertTrue(probe.calls.isEmpty)
    }

    // MARK: - Helpers

    private static var now: Int {
        Int(Date().timeIntervalSince1970)
    }

    private func makeState(probe: RefreshProbe, onSave: @escaping (String) -> Void = { _ in }) -> AuthState {
        AuthState(
            loadStoredToken: { nil },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { token, _ in onSave(token) },
            saveStoredSession: { token, _, _ in onSave(token) },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in
                UserProfile(id: "u", email: "a@b.c", name: nil, status: 1, provider: "password",
                            createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z")
            },
            refreshAccessToken: { refreshToken in
                try await probe.next(refreshToken)
            },
            fetchSubscription: { _ in .none }
        )
    }

    private static func login(access: String, refresh: String?) -> LoginResponse {
        LoginResponse(accessToken: access, expiresAt: now + 900, refreshToken: refresh)
    }

    static func jwt(lifetime: Int) -> String {
        let issuedAt = now
        return jwt(payload: #"{"sub":"u","iat":\#(issuedAt),"exp":\#(issuedAt + lifetime),"sv":1}"#)
    }

    static func jwt(payload: String) -> String {
        func encode(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(payload)).signature"
    }
}

/// Records refresh exchanges and lets each test decide when and how they finish.
@MainActor
private final class RefreshProbe {
    private(set) var calls: [String] = []
    private var pending: [CheckedContinuation<LoginResponse, Error>] = []

    func next(_ refreshToken: String) async throws -> LoginResponse {
        calls.append(refreshToken)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0 ..< 1000 where calls.count < count || pending.isEmpty {
            await Task.yield()
        }
    }

    func resolveNext(with result: Result<LoginResponse, Error>) {
        guard !pending.isEmpty else {
            XCTFail("No refresh exchange is waiting")
            return
        }
        pending.removeFirst().resume(with: result)
    }
}
