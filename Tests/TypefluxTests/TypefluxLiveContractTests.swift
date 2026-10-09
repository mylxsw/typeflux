import AppKit
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
        // Every exit, including a failed assertion or an unexpected error,
        // restores the password before the test ends.
        var failure: Error?
        do {
            // The old access token is rejected immediately (no TTL window).
            do {
                _ = try await AuthAPIService.fetchProfile(token: deviceA.accessToken)
                XCTFail("Old access token must be rejected after a password change")
            } catch let error as AuthError {
                guard case .unauthorized = error else { throw LiveContractFailure("Expected 401, got \(error)") }
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
        } catch {
            failure = error
        }
        state.logout(clearRecentInputMemory: false)
        await restorePassword(from: changed)
        if let failure { throw failure }
    }

    /// Changes the disposable account's password back, reporting a failure
    /// instead of leaving later tests with an unknown password.
    private func restorePassword(from changed: String) async {
        do {
            let login = try await AuthAPIService.login(email: email, password: changed)
            _ = try await AuthAPIService.changePassword(
                token: login.accessToken, oldPassword: changed, newPassword: password
            )
        } catch {
            XCTFail("Could not restore the disposable account's password: \(error)")
        }
    }

    // MARK: - ASR grants

    func testASRGrantIsSingleUseAcrossGateways() async throws {
        let login = try await AuthAPIService.login(email: email, password: password)
        let routing = TypefluxOfficialASRRoutingHTTPClient()
        let route = try await routing.fetchRoute(accessToken: login.accessToken, scenario: .voiceInput)
        let grant = TypefluxOfficialASRGrantSequence.Grant(route: route)
        let servers = route.serverBaseURLs
        guard servers.count >= 2 else {
            throw LiveContractFailure("Configure two gateway origins; the API returned \(servers.count)")
        }

        // The first use is admitted: the gateway claims the grant and upgrades.
        let first = try await upgrade(server: servers[0], grant: grant)
        XCTAssertEqual(first.status, 101, "first use must be admitted: \(String(describing: first.error))")
        let settled = try await stableUsage(token: login.accessToken)

        // Reusing it on another gateway is rejected before the upgrade with
        // 403 ASR_GRANT_REJECTED. A transport outage has no HTTP status and
        // fails this assertion instead of passing as a rejection.
        let replay = try await upgrade(server: servers[1], grant: grant)
        XCTAssertEqual(replay.status, 403, "replay must be rejected: \(String(describing: replay.error))")
        XCTAssertNotNil(replay.error)

        // The rejected replay adds no admission or credit debit. The admitted
        // session's audio duration is held at the admission maximum until its
        // gateway reports the end, which may land after the replay, so only
        // the admission count and credits are compared.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let afterReplay = try await CloudUsageAPIService.fetchCurrentPeriodStats(token: login.accessToken)
        XCTAssertEqual(afterReplay.stats.asrCount, settled.stats.asrCount)
        XCTAssertEqual(afterReplay.credits, settled.credits)
        XCTAssertNotNil(afterReplay.credits)
    }

    func testFailureAfterAudioUsesOneGrantAndNoSecondGateway() async throws {
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

        // The isolated gateway has no speech provider, so the admitted
        // session fails after its audio was sent. That failure is final:
        // replaying the audio on gateway B would claim and bill a second grant.
        let error = await capture {
            try await transcriber.transcribeStream(
                audioFile: AudioFile(fileURL: url, duration: 0.5),
                scenario: .voiceInput,
                optimize: false,
                onUpdate: { _ in }
            )
        }
        let tokens = await routing.tokens
        print("LIVE grants: \(tokens.count), error: \(String(describing: error))")
        XCTAssertNotNil(error)
        XCTAssertFalse(error is CancellationError)
        XCTAssertEqual(tokens.count, 1, "no second grant after audio was sent")
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
        assertUploadRejected(duplicate, status: 409, code: "FEEDBACK_UPLOAD_UNAVAILABLE")

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
        assertUploadRejected(falseSize, status: 413, code: "PAYLOAD_TOO_LARGE")

        // Another account's bearer cannot claim this account's target.
        let owned = try await FeedbackAPIService.createImageUploadTarget(
            filename: "b.png", contentType: "image/png", sizeBytes: Int64(png.count), token: login.accessToken
        )
        let wrongOwner = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "b.png", contentType: "image/png", to: owned, token: other.accessToken
            )
        }
        assertUploadRejected(wrongOwner, status: 409, code: "FEEDBACK_UPLOAD_UNAVAILABLE")
        let missingBearer = await capture {
            try await FeedbackAPIService.uploadImage(
                data: png, filename: "b.png", contentType: "image/png", to: owned, token: nil
            )
        }
        assertUploadRejected(missingBearer, status: 409, code: "FEEDBACK_UPLOAD_UNAVAILABLE")

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

    /// The Settings feedback path against two API nodes sharing one backend:
    /// failover node B issues a ticket for canonical upload origin A. The
    /// ticket and PUT share one credential, the submission re-reads it after
    /// a rotation, and a switch to another account refuses the old upload.
    /// Needs `TYPEFLUX_LIVE_FAILOVER_API_URL` (B, deployed with
    /// `FEEDBACK_UPLOAD_API_BASE_URL` set to `TYPEFLUX_LIVE_API_URL`).
    func testSettingsFeedbackFlowUploadsCanonicalTicketFromFailoverNode() async throws {
        guard let rawFailover = ProcessInfo.processInfo.environment["TYPEFLUX_LIVE_FAILOVER_API_URL"],
              let failover = URL(string: rawFailover)
        else {
            throw XCTSkip("Set TYPEFLUX_LIVE_FAILOVER_API_URL to run the canonical upload origin check")
        }
        let png = LivePNG.onePixel
        let image = PreparedFeedbackImage(
            data: png, filename: "live.png", contentType: "image/png", thumbnail: NSImage(size: .zero)
        )
        let executor = CloudRequestExecutor(
            selector: CloudEndpointSelector(baseURLs: [failover, apiURL], prober: LiveNoOpProber())
        )
        let state = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil })
        let login = try await AuthAPIService.login(email: email, password: password)
        await state.handleLoginSuccess(token: login.accessToken, expiresAt: login.expiresAt, refreshToken: login.refreshToken)
        defer { state.logout(clearRecentInputMemory: false) }

        // B issues an absolute ticket on A; A is a configured API origin, so
        // it receives the bearer and accepts the ticket B issued.
        let uploadCredentialValue = await state.validSessionCredential()
        let uploadCredential = try XCTUnwrap(uploadCredentialValue)
        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: "probe.png", contentType: "image/png", sizeBytes: Int64(png.count),
            token: uploadCredential.accessToken, executor: executor
        )
        XCTAssertEqual(target.issuingAPIBaseURL, failover)
        let resolved = try FeedbackAPIService.resolveUploadURL(for: target)
        XCTAssertTrue(resolved.isAPIOrigin)
        XCTAssertEqual(resolved.url.host, apiURL.host)
        XCTAssertEqual(resolved.url.port, apiURL.port)
        print("LIVE canonical ticket: issued by \(failover) for \(resolved.url.scheme ?? "")://\(resolved.url.host ?? ""):\(resolved.url.port ?? 0)")

        // Without A among the configured origins the same ticket is refused
        // before any bearer is sent.
        var untrusted = target
        untrusted.trustedAPIBaseURLs = [failover]
        XCTAssertThrowsError(try FeedbackAPIService.resolveUploadURL(for: untrusted))

        // Step 1+2: the Settings upload flow (ticket from B, PUT on A).
        let imageURL = try await FeedbackUploadFlow.upload(image, credential: uploadCredential, executor: executor)
        let attachment = FeedbackImageAttachment(
            filename: "live.png", state: .uploaded(imageURL),
            uploadOwner: FeedbackUploadOwner(uploadCredential)
        )

        // Step 3 after a rotation: same sign-in, new access token.
        let rotated = await state.refreshStoredAccessToken(force: true)
        XCTAssertEqual(rotated, .refreshed)
        let submitCredentialValue = await state.validSessionCredential()
        let submitCredential = try XCTUnwrap(submitCredentialValue)
        XCTAssertNotEqual(submitCredential.accessToken, uploadCredential.accessToken)
        XCTAssertEqual(submitCredential.session, uploadCredential.session)
        let urls = try FeedbackUploadFlow.submissionImageURLs(
            for: [attachment], submittingAs: FeedbackUploadOwner(submitCredential)
        )
        XCTAssertEqual(urls, [imageURL])
        let feedback = try await FeedbackAPIService.submit(
            content: "GUL-296 live canonical upload check", contact: nil, imageURLs: urls,
            token: submitCredential.accessToken, executor: executor
        )
        XCTAssertFalse(feedback.id.isEmpty)

        // Another account signs in: the earlier upload is refused.
        state.logout(clearRecentInputMemory: false)
        let other = try await AuthAPIService.login(email: secondEmail, password: secondPassword)
        await state.handleLoginSuccess(token: other.accessToken, expiresAt: other.expiresAt, refreshToken: other.refreshToken)
        let otherCredentialValue = await state.validSessionCredential()
        let otherCredential = try XCTUnwrap(otherCredentialValue)
        XCTAssertNotEqual(otherCredential.session, uploadCredential.session)
        XCTAssertThrowsError(
            try FeedbackUploadFlow.submissionImageURLs(for: [attachment], submittingAs: FeedbackUploadOwner(otherCredential))
        ) { error in
            XCTAssertEqual((error as? FeedbackUploadOwnerError)?.staleImageIDs, [attachment.id])
        }
    }

    // MARK: - Helpers

    /// Opens a WebSocket session with `grant` and closes it right after the
    /// upgrade. Returns the HTTP status of the upgrade response (nil when no
    /// response arrived) and the error, if any.
    private func upgrade(
        server: URL,
        grant: TypefluxOfficialASRGrantSequence.Grant
    ) async throws -> (status: Int?, error: Error?) {
        let request = try TypefluxOfficialASRRequestFactory.makeWebSocketRequest(
            apiBaseURL: server.absoluteString, token: grant.token, scenario: .voiceInput, provider: grant.provider
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        let error = await capture { try await task.send(.string(#"{"type":"stop"}"#)) }
        return ((task.response as? HTTPURLResponse)?.statusCode, error)
    }

    /// Waits until the account's usage stops changing, so a later comparison
    /// only sees what happened after this point.
    private func stableUsage(token: String) async throws -> CloudUsageCurrentPeriodStats {
        var previous = try await CloudUsageAPIService.fetchCurrentPeriodStats(token: token)
        for _ in 0 ..< 20 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let current = try await CloudUsageAPIService.fetchCurrentPeriodStats(token: token)
            if current == previous { return current }
            previous = current
        }
        throw LiveContractFailure("Usage did not settle")
    }

    private func assertUploadRejected(
        _ error: Error?,
        status: Int,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .serverError(_, message)? = error as? FeedbackAPIError,
              let message,
              message.hasPrefix("HTTP \(status)"),
              message.contains(code)
        else {
            return XCTFail("Expected HTTP \(status) \(code), got \(String(describing: error))", file: file, line: line)
        }
    }

    private func capture<T>(_ operation: () async throws -> T) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private struct LiveContractFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
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
