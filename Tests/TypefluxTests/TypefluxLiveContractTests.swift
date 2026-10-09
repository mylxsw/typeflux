@testable import Typeflux
import XCTest

/// Opt-in end-to-end checks against a real Typeflux API (and its realtime ASR
/// gateways) for the session, ASR grant and feedback upload contracts.
///
/// Skipped unless `TYPEFLUX_LIVE_API_URL`, `TYPEFLUX_LIVE_EMAIL`,
/// `TYPEFLUX_LIVE_PASSWORD`, `TYPEFLUX_LIVE_EMAIL2` and
/// `TYPEFLUX_LIVE_PASSWORD2` are set. Use disposable accounts on an isolated
/// deployment only: the tests change and restore the first account's password
/// and revoke its sessions.
@MainActor
final class TypefluxLiveContractTests: XCTestCase {
    private var apiURL: URL!
    private var email = ""
    private var password = ""
    private var secondEmail = ""
    private var secondPassword = ""

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let rawURL = env["TYPEFLUX_LIVE_API_URL"], let url = URL(string: rawURL),
              let email = env["TYPEFLUX_LIVE_EMAIL"], let password = env["TYPEFLUX_LIVE_PASSWORD"],
              let secondEmail = env["TYPEFLUX_LIVE_EMAIL2"], let secondPassword = env["TYPEFLUX_LIVE_PASSWORD2"]
        else {
            throw XCTSkip("Set TYPEFLUX_LIVE_* to run live contract tests")
        }
        apiURL = url
        self.email = email
        self.password = password
        self.secondEmail = secondEmail
        self.secondPassword = secondPassword
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
        CloudEndpointRegistry.setOverride(CloudEndpointSelector(baseURLs: [url], prober: LiveNoOpProber()))
    }

    override func tearDown() async throws {
        CloudEndpointRegistry.setOverride(nil)
        KeychainTokenStore.clearAll()
        KeychainTokenStore.useInMemoryStoreForTesting = false
        try await super.tearDown()
    }

    // MARK: - Sessions

    func testConcurrentClientRefreshesKeepTheRefreshFamilyAlive() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let state = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil })
        await state.handleLoginSuccess(token: login.accessToken, expiresAt: login.expiresAt, refreshToken: login.refreshToken)
        XCTAssertEqual(AccessTokenClaims.lifetime(of: login.accessToken), 900, "API default access TTL")
        XCTAssertEqual(state.accessTokenRefreshLeadTime(), 300)

        async let first = state.refreshStoredAccessToken(force: true)
        async let second = state.refreshStoredAccessToken(force: true)
        async let third = state.refreshStoredAccessToken(force: true)
        let results = await [first, second, third]

        XCTAssertEqual(results, [.refreshed, .refreshed, .refreshed])
        XCTAssertNotEqual(state.cachedRefreshToken, login.refreshToken)
        // The single exchange left the family active: the new pair works.
        let profile = try await AuthAPIService.fetchProfile(token: XCTUnwrap(state.accessToken))
        XCTAssertEqual(profile.email.lowercased(), email.lowercased())
        let next = await state.refreshStoredAccessToken(force: true)
        XCTAssertEqual(next, .refreshed)
        XCTAssertTrue(state.isLoggedIn)
        state.logout(clearRecentInputMemory: false)
    }

    func testReplayedRefreshRevokesTheFamilyAndTheClientLogsOutOnce() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let original = try XCTUnwrap(login.refreshToken)
        var refreshCalls = 0
        let state = AuthState(
            loadStoredToken: { nil },
            loadStoredRefreshToken: { nil },
            refreshAccessToken: { token in
                refreshCalls += 1
                return try await AuthAPIService.refreshToken(token)
            }
        )
        await state.handleLoginSuccess(token: login.accessToken, expiresAt: login.expiresAt, refreshToken: original)
        let refreshed = await state.refreshStoredAccessToken(force: true)
        XCTAssertEqual(refreshed, .refreshed)

        // Another holder of the consumed token (a stale copy) replays it.
        do {
            _ = try await AuthAPIService.refreshToken(original)
            XCTFail("A consumed refresh token must not be accepted twice")
        } catch let error as AuthError {
            XCTAssertTrue(state.shouldInvalidateSession(for: error), "\(error)")
        }

        // The whole family is revoked, including the client's fresh access.
        let result = await state.refreshProfile()
        XCTAssertEqual(result, .unauthenticated)
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertNil(state.accessToken)
        XCTAssertEqual(refreshCalls, 2, "one rotation plus one failed recovery attempt, no loop")
        await state.refreshTokenIfNeeded()
        XCTAssertEqual(refreshCalls, 2)
    }

    func testPasswordChangeRevokesOtherDeviceWithoutRefreshLoop() async throws {
        let deviceA = try await AuthAPIService.login(email: email, password: password)
        let deviceB = try await AuthAPIService.login(email: email, password: password)
        var refreshCalls = 0
        let state = AuthState(
            loadStoredToken: { nil },
            loadStoredRefreshToken: { nil },
            refreshAccessToken: { token in
                refreshCalls += 1
                return try await AuthAPIService.refreshToken(token)
            }
        )
        await state.handleLoginSuccess(
            token: deviceA.accessToken,
            expiresAt: deviceA.expiresAt,
            refreshToken: deviceA.refreshToken
        )
        XCTAssertTrue(state.isLoggedIn)

        let changed = "\(password)-c"
        _ = try await AuthAPIService.changePassword(token: deviceB.accessToken, oldPassword: password, newPassword: changed)
        do {
            // The old access token is rejected immediately (no TTL window).
            do {
                _ = try await AuthAPIService.fetchProfile(token: deviceA.accessToken)
                XCTFail("Old access token must be rejected after a password change")
            } catch let error as AuthError {
                guard case .unauthorized = error else { return XCTFail("Unexpected \(error)") }
            }

            let result = await state.refreshProfile()
            XCTAssertEqual(result, .unauthenticated)
            XCTAssertFalse(state.isLoggedIn)
            XCTAssertEqual(refreshCalls, 1)
            for _ in 0 ..< 3 {
                await state.refreshTokenIfNeeded()
                _ = await state.validAccessToken()
            }
            XCTAssertEqual(refreshCalls, 1, "a revoked session must not keep retrying")

            // The user can sign in again with the new password.
            let again = try await AuthAPIService.login(email: email, password: changed)
            await state.handleLoginSuccess(token: again.accessToken, expiresAt: again.expiresAt, refreshToken: again.refreshToken)
            let restored = await state.refreshProfile()
            XCTAssertEqual(restored, .authenticated)
            _ = try await AuthAPIService.changePassword(token: again.accessToken, oldPassword: changed, newPassword: password)
        } catch {
            // Restore the password even when an assertion path throws.
            if let again = try? await AuthAPIService.login(email: email, password: changed) {
                _ = try? await AuthAPIService.changePassword(
                    token: again.accessToken,
                    oldPassword: changed,
                    newPassword: password
                )
            }
            throw error
        }
        state.logout(clearRecentInputMemory: false)
    }

    // MARK: - ASR grants

    func testASRGrantIsSingleUseAcrossGateways() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let routing = TypefluxOfficialASRRoutingHTTPClient()
        let route = try await routing.fetchRoute(accessToken: login.accessToken, scenario: .voiceInput)
        let grant = TypefluxOfficialASRGrantSequence.Grant(route: route)
        let servers = route.serverBaseURLs
        XCTAssertGreaterThanOrEqual(servers.count, 2, "configure two gateway origins")
        let transport = DefaultTypefluxOfficialASRTransport()
        let pcm = RemoteSTTTestAudio.pcm16MonoSilence()

        // First use claims the grant (the isolated gateway has no speech
        // provider, so the session itself ends with an upstream failure).
        let firstError = await capture {
            try await transport.transcribeViaWebSocket(
                pcmData: pcm, apiBaseURL: servers[0].absoluteString, token: grant.token,
                provider: grant.provider, scenario: .voiceInput, optimize: false, onUpdate: { _ in }
            )
        }
        // Reusing it on another gateway is rejected before the upgrade.
        let replayError = await capture {
            try await transport.transcribeViaWebSocket(
                pcmData: pcm, apiBaseURL: servers[1].absoluteString, token: grant.token,
                provider: grant.provider, scenario: .voiceInput, optimize: false, onUpdate: { _ in }
            )
        }
        print("LIVE first-use error: \(String(describing: firstError))")
        print("LIVE replay error: \(String(describing: replayError))")
        XCTAssertNotNil(replayError)
    }

    func testTranscriberFailoverUsesAFreshGrantPerGateway() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let routing = LiveCountingRouting(upstream: TypefluxOfficialASRRoutingHTTPClient())
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            serverRegistry: LiveOrderedRegistry(),
            accessTokenProvider: { login.accessToken }
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).wav")
        try LiveWAV.silence(seconds: 0.5).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let error = await capture {
            try await transcriber.transcribeStream(
                audioFile: AudioFile(fileURL: url, duration: 0.5),
                scenario: .voiceInput,
                optimize: false,
                onUpdate: { _ in }
            )
        }
        let tokens = await routing.tokens
        print("LIVE failover grants: \(tokens.count), error: \(String(describing: error))")
        XCTAssertEqual(tokens.count, 2, "one grant for each gateway attempt")
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }

    // MARK: - Feedback uploads

    func testAccountFeedbackUploadUsesTheIssuingOriginAndSameBearer() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let png = LivePNG.onePixel
        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: "live.png", contentType: "image/png", sizeBytes: Int64(png.count), token: login.accessToken
        )
        XCTAssertEqual(target.type, FeedbackAPIService.apiProxyUploadType)
        XCTAssertEqual(target.issuingAPIBaseURL, apiURL)
        let resolved = try FeedbackAPIService.resolveUploadURL(for: target)
        XCTAssertTrue(resolved.isAPIOrigin)
        print("LIVE upload target: url=\(target.url) method=\(target.method) headers=\(target.headers) max=\(target.maxSizeBytes)")

        try await FeedbackAPIService.uploadImage(
            data: png, filename: "live.png", contentType: "image/png", to: target, token: login.accessToken
        )
        // A target is single-use.
        let duplicate = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "live.png", contentType: "image/png", to: target, token: login.accessToken
            )
        }
        XCTAssertNotNil(duplicate)

        let feedback = try await FeedbackAPIService.submit(
            content: "GUL-289 live contract check", contact: nil, imageURLs: [target.imageURL], token: login.accessToken
        )
        XCTAssertFalse(feedback.id.isEmpty)
    }

    func testFeedbackUploadRejectsFalseSizeOtherOwnerAndAnonymousCrossUse() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let other = try await AuthAPIService.login(email: secondEmail, password: secondPassword)
        let png = LivePNG.onePixel

        // Declared size must match the body exactly.
        let small = try await FeedbackAPIService.createImageUploadTarget(
            filename: "a.png", contentType: "image/png", sizeBytes: Int64(png.count - 1), token: login.accessToken
        )
        let falseSize = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "a.png", contentType: "image/png", to: small, token: login.accessToken
            )
        }
        XCTAssertNotNil(falseSize)

        // Another account's bearer cannot claim this account's target.
        let owned = try await FeedbackAPIService.createImageUploadTarget(
            filename: "b.png", contentType: "image/png", sizeBytes: Int64(png.count), token: login.accessToken
        )
        let wrongOwner = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "b.png", contentType: "image/png", to: owned, token: other.accessToken
            )
        }
        XCTAssertNotNil(wrongOwner)
        let missingBearer = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "b.png", contentType: "image/png", to: owned, token: nil
            )
        }
        XCTAssertNotNil(missingBearer)

        // Anonymous feedback still works without any bearer.
        let anonymous = try await FeedbackAPIService.createImageUploadTarget(
            filename: "c.png", contentType: "image/png", sizeBytes: Int64(png.count), token: nil
        )
        try await FeedbackAPIService.uploadImage(
            data: png, filename: "c.png", contentType: "image/png", to: anonymous, token: nil
        )
        print("LIVE false-size: \(String(describing: falseSize))")
        print("LIVE wrong-owner: \(String(describing: wrongOwner)); missing-bearer: \(String(describing: missingBearer))")
    }

    // MARK: - Helpers

    private func capture<T>(_ operation: () async throws -> T) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private struct LiveNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

private actor LiveCountingRouting: TypefluxOfficialASRRoutingClient {
    private let upstream: TypefluxOfficialASRRoutingHTTPClient
    private(set) var tokens: [String] = []

    init(upstream: TypefluxOfficialASRRoutingHTTPClient) {
        self.upstream = upstream
    }

    func fetchRoute(accessToken: String, scenario: TypefluxCloudScenario) async throws -> TypefluxOfficialASRRouteDecision {
        let route = try await upstream.fetchRoute(accessToken: accessToken, scenario: scenario)
        tokens.append(TypefluxOfficialASRGrantSequence.Grant(route: route).token)
        return route
    }
}

private actor LiveOrderedRegistry: TypefluxASRServerProviding {
    func refreshPublicConfig() async {}
    func orderedServers(preferred: [URL]) async -> [URL] { preferred }
    func reportFailure(_: URL, error _: Error) async {}
}

private enum LivePNG {
    static let onePixel = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!
}

private enum LiveWAV {
    static func silence(seconds: Double) -> Data {
        let bytes = Int(seconds * 16000) * 2
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }
}
