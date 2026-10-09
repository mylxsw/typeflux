// swiftlint:disable file_length type_body_length
@testable import Typeflux
import XCTest

/// A recording belongs to the session that started it. When that session is
/// logged out or replaced while a grant is issued or the servers are selected,
/// the recording stops before any connection is opened: the grant is not used,
/// no further grant is requested, and the audio never reaches the new account.
/// A token refresh within the same session keeps the recording going.
final class TypefluxOfficialASRSessionFenceTests: XCTestCase {
    private let serverA = URL(string: "https://asr-a.example.com")!
    private let serverB = URL(string: "https://asr-b.example.com")!
    private let accountA = TypefluxCloudSessionCredential(accessToken: "account-a", session: 7)
    private let accountB = TypefluxCloudSessionCredential(accessToken: "account-b", session: 8)

    // MARK: - Initial route

    func testSessionChangeWhileTheFirstRouteIsFetchedOpensNoConnection() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 1)
        let transport = AttemptRecordingTransport()
        let transcriber = makeTranscriber(routing: routing, transport: transport, session: session)
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(accountB)
        await routing.gate.release()

        await assertStops(recording, with: .sessionChanged)
        XCTAssertTrue(transport.attempts.isEmpty)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a"])
    }

    func testLogoutWhileTheFirstLLMRouteIsFetchedOpensNoConnection() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 1)
        let transport = AttemptRecordingTransport()
        let transcriber = makeTranscriber(routing: routing, transport: transport, session: session)
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStreamWithLLMRewrite(
                audioFile: audio,
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { _ in }
            ).transcript
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(nil)
        await routing.gate.release()

        await assertStops(recording, with: .notLoggedIn)
        XCTAssertTrue(transport.attempts.isEmpty)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a"])
    }

    // MARK: - Server selection

    func testSessionChangeWhileServersAreSelectedOpensNoConnection() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let registry = ParkingRegistry()
        let transport = AttemptRecordingTransport()
        let transcriber = makeTranscriber(
            routing: routing, transport: transport, session: session, registry: registry
        )
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [registry.gate]) {
            try await transcriber.transcribeStreamWithLLMRewrite(
                audioFile: audio,
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { _ in }
            ).transcript
        }
        try await registry.gate.waitUntilParked(unlessFinished: recording)
        await session.set(accountB)
        await registry.gate.release()

        await assertStops(recording, with: .sessionChanged)
        XCTAssertTrue(transport.attempts.isEmpty)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a"])
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    func testCancellationWhileServersAreSelectedOpensNoConnection() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let registry = ParkingRegistry()
        let transport = AttemptRecordingTransport()
        let transcriber = makeTranscriber(
            routing: routing, transport: transport, session: session, registry: registry
        )
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [registry.gate]) {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        try await registry.gate.waitUntilParked(unlessFinished: recording)
        recording.cancel()
        await registry.gate.release()

        do {
            _ = try await recording.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(transport.attempts.isEmpty)
    }

    // MARK: - Replacement grant

    func testSessionChangeWhileAReplacementGrantIsIssuedDoesNotUseIt() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 2)
        let transport = AttemptRecordingTransport(handshakeFailures: [serverA.absoluteString])
        let registry = ParkingRegistry(parks: false)
        let transcriber = makeTranscriber(
            routing: routing, transport: transport, session: session, registry: registry
        )
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(accountB)
        await routing.gate.release()

        await assertStops(recording, with: .sessionChanged)
        // grant-2 was issued for account A but never used, and no grant was
        // requested with account B.
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1"])
        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString])
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a", "account-a"])
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testLogoutWhileAnLLMReplacementGrantIsIssuedDoesNotUseIt() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 2)
        let transport = AttemptRecordingTransport(handshakeFailures: [serverA.absoluteString])
        let transcriber = makeTranscriber(routing: routing, transport: transport, session: session)
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStreamWithLLMRewrite(
                audioFile: audio,
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { _ in }
            ).transcript
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(nil)
        await routing.gate.release()

        await assertStops(recording, with: .notLoggedIn)
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1"])
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a", "account-a"])
    }

    func testTokenRotationWithinTheSessionWhileAReplacementGrantIsIssuedContinues() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB], parkFetch: 2)
        let transport = AttemptRecordingTransport(handshakeFailures: [serverA.absoluteString])
        let transcriber = makeTranscriber(routing: routing, transport: transport, session: session)
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(TypefluxCloudSessionCredential(accessToken: "account-a-rotated", session: 7))
        await routing.gate.release()

        let text = try await recording.value
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString, serverB.absoluteString])
    }

    func testTokenRotationBeforeAReplacementGrantUsesTheFreshToken() async throws {
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [serverA, serverB])
        let transport = AttemptRecordingTransport(handshakeFailures: [serverA.absoluteString]) {
            await session.set(TypefluxCloudSessionCredential(accessToken: "account-a-rotated", session: 7))
        }
        let transcriber = makeTranscriber(routing: routing, transport: transport, session: session)

        let text = try await transcriber.transcribeStream(
            audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
        )

        XCTAssertEqual(text, "ok")
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a", "account-a-rotated"])
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
    }

    // MARK: - Local gateways

    func testSessionChangeDuringAReplacementGrantNeverReachesTheNextGateway() async throws {
        let (first, second) = try await LocalASRGateway.startPair(.rejectConnection, .succeed("hello"))
        defer {
            first.stop()
            second.stop()
        }
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [first.baseURL, second.baseURL], parkFetch: 2)
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            serverRegistry: RecordingRegistry(),
            credentialProvider: { await session.current() }
        )
        let audio = try makeSilentAudioFile()

        let recording = record(releasing: [routing.gate]) {
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
        }
        try await routing.gate.waitUntilParked(unlessFinished: recording)
        await session.set(accountB)
        await routing.gate.release()

        await assertStops(recording, with: .sessionChanged)
        // URL loading may retry the refused connection; only the first
        // gateway is ever contacted.
        XCTAssertGreaterThanOrEqual(first.connectionCount, 1)
        XCTAssertEqual(second.connectionCount, 0)
        XCTAssertTrue(second.authorizations.isEmpty)
        XCTAssertEqual(second.audioBytes, 0)
    }

    // MARK: - Realtime

    func testRealtimeSessionChangeWhileTheRouteIsFetchedOpensNoConnection() async throws {
        let gateway = try await LocalASRGateway.start(behavior: .succeed("hello"))
        defer { gateway.stop() }
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL], parkFetch: 1)
        let realtime = try await makeRealtimeSession(routing: routing, session: session, releasing: [routing.gate])

        await realtime.start()
        try await routing.gate.waitUntilParked()
        await session.set(accountB)
        await routing.gate.release()

        await assertConnectionFails(realtime, with: .sessionChanged)
        XCTAssertEqual(gateway.connectionCount, 0)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["account-a"])
    }

    func testRealtimeLogoutWhileServersAreSelectedOpensNoConnection() async throws {
        let gateway = try await LocalASRGateway.start(behavior: .succeed("hello"))
        defer { gateway.stop() }
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL])
        let registry = ParkingRegistry()
        let realtime = try await makeRealtimeSession(
            routing: routing, session: session, registry: registry, releasing: [registry.gate]
        )

        await realtime.start()
        try await registry.gate.waitUntilParked()
        await session.set(nil)
        await registry.gate.release()

        await assertConnectionFails(realtime, with: .notLoggedIn)
        XCTAssertEqual(gateway.connectionCount, 0)
    }

    func testRealtimeTokenRotationWithinTheSessionStillConnects() async throws {
        let gateway = try await LocalASRGateway.start(behavior: .succeed("hello"))
        defer { gateway.stop() }
        let session = SessionSource(accountA)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL], parkFetch: 1)
        let realtime = try await makeRealtimeSession(routing: routing, session: session, releasing: [routing.gate])

        await realtime.start()
        try await routing.gate.waitUntilParked()
        await session.set(TypefluxCloudSessionCredential(accessToken: "account-a-rotated", session: 7))
        await routing.gate.release()

        let awaiting = try XCTUnwrap(realtime as? any RealtimeTranscriptionConnectionAwaiting)
        try await awaiting.waitUntilConnectionReady()
        await realtime.cancel()
        XCTAssertEqual(gateway.connectionCount, 1)
        XCTAssertEqual(gateway.authorizations, ["Bearer grant-1"])
    }

    // MARK: - Helpers

    private func makeTranscriber(
        routing: RecordingRoutingClient,
        transport: AttemptRecordingTransport,
        session: SessionSource,
        registry: any TypefluxASRServerProviding = RecordingRegistry()
    ) -> TypefluxOfficialTranscriber {
        TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: registry,
            credentialProvider: { await session.current() }
        )
    }

    private func makeRealtimeSession(
        routing: RecordingRoutingClient,
        session: SessionSource,
        registry: any TypefluxASRServerProviding = RecordingRegistry(),
        releasing gates: [ParkingGate]
    ) async throws -> any RealtimeTranscriptionSession {
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            serverRegistry: registry,
            credentialProvider: { await session.current() }
        )
        let realtime = try await transcriber.makeRealtimeTranscriptionSession(
            scenario: .voiceInput, optimize: true, onUpdate: { _ in }
        )
        addTeardownBlock {
            // Cancel, open the gates the connection may be parked at, then
            // join the connection attempt.
            await realtime.cancel()
            for gate in gates {
                await gate.release()
            }
            try? await (realtime as? any RealtimeTranscriptionConnectionAwaiting)?.waitUntilConnectionReady()
        }
        return realtime
    }

    /// Starts a recording the test owns. On every exit the recording is
    /// cancelled, its gates are opened and it is joined.
    private func record(
        releasing gates: [ParkingGate],
        _ operation: @escaping @Sendable () async throws -> String
    ) -> OwnedWorker<String> {
        let recording = OwnedWorker(operation)
        addTeardownBlock { await recording.stop(releasing: gates) }
        return recording
    }

    private func assertStops(
        _ recording: OwnedWorker<String>,
        with expected: TypefluxOfficialASRError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await recording.value
            XCTFail("Expected the recording to stop", file: file, line: line)
        } catch let error as TypefluxOfficialASRError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertConnectionFails(
        _ realtime: any RealtimeTranscriptionSession,
        with expected: TypefluxOfficialASRError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let awaiting = realtime as? any RealtimeTranscriptionConnectionAwaiting else {
            return XCTFail("The realtime session cannot report its connection", file: file, line: line)
        }
        do {
            try await awaiting.waitUntilConnectionReady()
            XCTFail("Expected the connection to fail", file: file, line: line)
        } catch let error as TypefluxOfficialASRError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func makeSilentAudioFile() throws -> AudioFile {
        let url = try ASRTestAudio.writeSilentWAV()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioFile(fileURL: url, duration: 0.1)
    }
}

/// The signed-in session as the transcriber sees it; tests replace it while
/// a request is parked.
private actor SessionSource {
    private var credential: TypefluxCloudSessionCredential?

    init(_ credential: TypefluxCloudSessionCredential?) {
        self.credential = credential
    }

    func current() -> TypefluxCloudSessionCredential? {
        credential
    }

    func set(_ credential: TypefluxCloudSessionCredential?) {
        self.credential = credential
    }
}

/// A server registry whose first server selection parks at `gate` until
/// released.
private actor ParkingRegistry: TypefluxASRServerProviding {
    nonisolated let gate = ParkingGate()
    private let parks: Bool
    private(set) var failures: [URL] = []
    private var hasParked = false

    init(parks: Bool = true) {
        self.parks = parks
    }

    func refreshPublicConfig() async {}

    func orderedServers(preferred: [URL]) async -> [URL] {
        if parks, !hasParked {
            hasParked = true
            await gate.park()
        }
        return preferred
    }

    func reportFailure(_ url: URL, error _: Error) async {
        failures.append(url)
    }
}

/// Records every connection attempt; endpoints in `handshakeFailures` reject
/// the handshake before any audio is sent.
private final class AttemptRecordingTransport: TypefluxOfficialASRTransport, @unchecked Sendable {
    struct Attempt: Equatable {
        let baseURL: String
        let token: String
    }

    private let lock = NSLock()
    private let handshakeFailures: Set<String>
    private let afterFailure: @Sendable () async -> Void
    private var recorded: [Attempt] = []

    init(handshakeFailures: Set<String> = [], afterFailure: @escaping @Sendable () async -> Void = {}) {
        self.handshakeFailures = handshakeFailures
        self.afterFailure = afterFailure
    }

    var attempts: [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(baseURL: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Attempt(baseURL: baseURL, token: token))
    }

    private func attempt(baseURL: String, token: String) async throws {
        record(baseURL: baseURL, token: token)
        if handshakeFailures.contains(baseURL) {
            await afterFailure()
            throw TypefluxOfficialASRError.connectionFailed("ASR_GRANT_REJECTED")
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
        try await attempt(baseURL: apiBaseURL, token: token)
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
        try await attempt(baseURL: apiBaseURL, token: token)
        return ("ok", nil)
    }
}
