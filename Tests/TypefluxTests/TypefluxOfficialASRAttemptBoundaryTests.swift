@testable import Typeflux
import XCTest

/// Failover may only move a recording to another endpoint before any audio
/// was sent, every replacement grant is requested with a valid access token
/// of the session that started the recording, and a cancelled recording
/// requests no further grant and opens no further connection.
final class TypefluxOfficialASRAttemptBoundaryTests: XCTestCase {
    private let serverA = URL(string: "https://asr-a.example.com")!
    private let serverB = URL(string: "https://asr-b.example.com")!

    // MARK: - Replacement grant credentials

    func testReplacementGrantUsesAFreshAccessTokenOfTheSameSession() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let credentials = CredentialSequence([
            TypefluxCloudSessionCredential(accessToken: "access-1", session: 7),
            TypefluxCloudSessionCredential(accessToken: "access-2", session: 7)
        ])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .handshake])
        let transcriber = makeTranscriber(routing: routing, transport: transport, credentials: credentials)

        let text = try await transcriber.transcribeStream(
            audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
        )

        XCTAssertEqual(text, "ok")
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["access-1", "access-2"])
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
    }

    func testRecordingStopsWhenTheSessionChangesBeforeAReplacementGrant() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        // The recording starts, its first grant is checked, then account B
        // signs in before the replacement grant.
        let credentials = CredentialSequence([
            TypefluxCloudSessionCredential(accessToken: "account-a", session: 7),
            TypefluxCloudSessionCredential(accessToken: "account-a", session: 7),
            TypefluxCloudSessionCredential(accessToken: "account-b", session: 8)
        ])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .handshake])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(
            routing: routing, transport: transport, credentials: credentials, registry: registry
        )

        do {
            _ = try await transcriber.transcribeStreamWithLLMRewrite(
                audioFile: makeSilentAudioFile(),
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { _ in }
            )
            XCTFail("Expected the recording to stop")
        } catch let error as TypefluxOfficialASRError {
            guard case .sessionChanged = error else { return XCTFail("Unexpected error \(error)") }
        }

        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a"])
        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString])
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testRecordingStopsWhenTheSessionEndsBeforeAReplacementGrant() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let credentials = CredentialSequence([
            TypefluxCloudSessionCredential(accessToken: "access-1", session: 7),
            TypefluxCloudSessionCredential(accessToken: "access-1", session: 7),
            nil
        ])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .handshake])
        let transcriber = makeTranscriber(routing: routing, transport: transport, credentials: credentials)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected the recording to stop")
        } catch let error as TypefluxOfficialASRError {
            guard case .notLoggedIn = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(transport.attempts.count, 1)
    }

    func testRecordingWithoutCredentialDoesNotRequestAGrant() async throws {
        let routing = RecordingRoutingClient(servers: [serverA])
        let transport = ScriptedTransport(failures: [:])
        let transcriber = makeTranscriber(
            routing: routing, transport: transport, credentials: CredentialSequence([nil])
        )

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected notLoggedIn")
        } catch TypefluxOfficialASRError.notLoggedIn {}
        let tokens = await routing.accessTokens
        XCTAssertTrue(tokens.isEmpty)
    }

    func testSessionCredentialPairsTheTokenWithItsSession() async {
        let state = await MainActor.run {
            AuthState(
                loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil },
                saveStoredToken: { _, _ in }, saveStoredSession: { _, _, _ in }, saveStoredUserProfile: { _ in },
                clearStoredSession: {},
                fetchProfile: { _ in AuthStateProfileSessionTests.profile("user") },
                fetchSubscription: { _ in .none }
            )
        }
        let loggedOut = await state.validSessionCredential()
        XCTAssertNil(loggedOut)

        let expiresAt = Int(Date().timeIntervalSince1970) + 900
        await state.handleLoginSuccess(token: "first", expiresAt: expiresAt)
        let first = await state.validSessionCredential()
        await state.handleLoginSuccess(token: "second", expiresAt: expiresAt)
        let second = await state.validSessionCredential()

        XCTAssertEqual(first?.accessToken, "first")
        XCTAssertEqual(second?.accessToken, "second")
        XCTAssertNotEqual(first?.session, second?.session)
    }

    // MARK: - Admitted streams

    func testFailureAfterAudioWasSentDoesNotFailOver() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .afterAudio])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected the stream failure")
        } catch let error as TypefluxOfficialASRError {
            let expected = TypefluxOfficialASRError.serverError("PROVIDER_FAILED")
            XCTAssertEqual(error.errorDescription, expected.errorDescription)
        }

        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString])
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testBillingStopAfterAudioIsStillReportedAsBilling() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .billingAfterAudio])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected the billing error")
        } catch {
            XCTAssertNotNil(TypefluxCloudBillingError.fromError(error))
        }
        XCTAssertEqual(transport.attempts.count, 1)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    func testDirectiveAfterAudioFallsBackWithoutBlamingTheEndpoint() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .directiveAfterAudio])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected the local fallback directive")
        } catch {
            XCTAssertTrue(error is TypefluxCloudASRDirectiveError)
        }
        XCTAssertEqual(transport.attempts.count, 1)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Helpers

    private func makeTranscriber(
        routing: RecordingRoutingClient,
        transport: ScriptedTransport,
        credentials: CredentialSequence = CredentialSequence([
            TypefluxCloudSessionCredential(accessToken: "cloud-token", session: 1)
        ]),
        registry: RecordingRegistry = RecordingRegistry()
    ) -> TypefluxOfficialTranscriber {
        TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: registry,
            credentialProvider: { await credentials.next() }
        )
    }

    private func makeSilentAudioFile() throws -> AudioFile {
        let url = try ASRTestAudio.writeSilentWAV()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioFile(fileURL: url, duration: 0.1)
    }
}

// MARK: - Cancellation

extension TypefluxOfficialASRAttemptBoundaryTests {

    func testCancellationWhileAReplacementGrantIsIssuedOpensNoSecondConnection() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 2)
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .handshake])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)
        let audio = try makeSilentAudioFile()

        let recording = OwnedWorker {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        addTeardownBlock { await recording.stop(releasing: [routing.gate]) }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        recording.cancel()
        await routing.gate.release()

        do {
            _ = try await recording.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString])
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testCancellationWhileTheFirstRouteIsFetchedStartsNoAttempt() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 1)
        let transport = ScriptedTransport(failures: [:])
        let transcriber = makeTranscriber(routing: routing, transport: transport)
        let audio = try makeSilentAudioFile()

        let recording = OwnedWorker {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        addTeardownBlock { await recording.stop(releasing: [routing.gate]) }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        recording.cancel()
        await routing.gate.release()

        do {
            _ = try await recording.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(transport.attempts.isEmpty)
    }

    func testURLCancellationIsNotBlamedOnTheEndpoint() async throws {
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let transport = ScriptedTransport(failures: [serverA.absoluteString: .urlCancelled])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(transport.attempts.count, 1)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
    }

    func testCancellationClassification() {
        XCTAssertTrue(TypefluxOfficialASRCancellation.isCancellation(CancellationError()))
        XCTAssertTrue(TypefluxOfficialASRCancellation.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(TypefluxOfficialASRCancellation.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        XCTAssertTrue(TypefluxOfficialASRCancellation.isCancellation(
            TypefluxOfficialASRGrantRefreshError(underlying: URLError(.cancelled))
        ))
        XCTAssertTrue(TypefluxOfficialASRCancellation.isCancellation(
            TypefluxOfficialASRAdmittedStreamError(underlying: CancellationError())
        ))
        XCTAssertFalse(TypefluxOfficialASRCancellation.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(TypefluxOfficialASRCancellation.isCancellation(TypefluxOfficialASRError.unexpectedClose))
    }

    func testReceiveFailureClassification() {
        let reset = NSError(domain: NSPOSIXErrorDomain, code: 54)
        let classified = TypefluxOfficialASRReceiveFailure.classify(reset) as? TypefluxOfficialASRError
        guard case .unexpectedClose? = classified else {
            return XCTFail("A dropped connection must surface as an unexpected close")
        }
        let directive = TypefluxOfficialASRReceiveFailure.classify(TypefluxCloudASRDirectiveError())
        XCTAssertTrue(directive is TypefluxCloudASRDirectiveError)
        let billing = TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
        XCTAssertTrue(TypefluxOfficialASRReceiveFailure.classify(billing) is TypefluxCloudBillingError)
    }

    func testSessionChangedHasADescription() {
        XCTAssertFalse(TypefluxOfficialASRError.sessionChanged.errorDescription?.isEmpty ?? true)
    }
}

/// Returns the scripted credentials in order, repeating the last one.
private actor CredentialSequence {
    private var values: [TypefluxCloudSessionCredential?]

    init(_ values: [TypefluxCloudSessionCredential?]) {
        self.values = values
    }

    func next() -> TypefluxCloudSessionCredential? {
        values.count > 1 ? values.removeFirst() : values.first ?? nil
    }
}

/// A transport whose attempts fail in a scripted way per endpoint.
private final class ScriptedTransport: TypefluxOfficialASRTransport, @unchecked Sendable {
    enum Failure {
        /// The handshake fails before any audio is sent.
        case handshake
        /// The endpoint fails after it received audio.
        case afterAudio
        /// The endpoint stops the recording for billing after audio.
        case billingAfterAudio
        /// The endpoint asks for local fallback after audio.
        case directiveAfterAudio
        /// URL loading reports the task as cancelled.
        case urlCancelled
    }

    struct Attempt: Equatable {
        let baseURL: String
        let token: String
    }

    private let lock = NSLock()
    private let failures: [String: Failure]
    private var recorded: [Attempt] = []

    init(failures: [String: Failure]) {
        self.failures = failures
    }

    var attempts: [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func attempt(baseURL: String, token: String) throws {
        lock.lock()
        recorded.append(Attempt(baseURL: baseURL, token: token))
        lock.unlock()
        switch failures[baseURL] {
        case .handshake:
            throw TypefluxOfficialASRError.connectionFailed("ASR_GRANT_REJECTED")
        case .afterAudio:
            throw TypefluxOfficialASRAdmittedStreamError(
                underlying: TypefluxOfficialASRError.serverError("PROVIDER_FAILED")
            )
        case .billingAfterAudio:
            throw TypefluxOfficialASRAdmittedStreamError(
                underlying: TypefluxCloudBillingError(reason: .quotaExceeded, serverMessage: nil)
            )
        case .directiveAfterAudio:
            throw TypefluxOfficialASRAdmittedStreamError(underlying: TypefluxCloudASRDirectiveError())
        case .urlCancelled:
            throw URLError(.cancelled)
        case nil:
            return
        }
    }

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocket(
        pcmData _: Data,
        apiBaseURL: String,
        token: String,
        provider _: String,
        scenario _: TypefluxCloudScenario,
        optimize _: Bool,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try attempt(baseURL: apiBaseURL, token: token)
        return "ok"
    }

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocketWithLLM(
        pcmData _: Data,
        apiBaseURL: String,
        token: String,
        provider _: String,
        scenario _: TypefluxCloudScenario,
        llmConfig _: ASRLLMConfig,
        onASRUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart _: @escaping @Sendable () async -> Void,
        onLLMChunk _: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        try attempt(baseURL: apiBaseURL, token: token)
        return ("ok", nil)
    }
}
