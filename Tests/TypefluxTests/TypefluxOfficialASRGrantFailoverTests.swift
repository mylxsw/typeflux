@testable import Typeflux
import XCTest

/// The gateway claims a one-time grant before upgrading the WebSocket, so a
/// failover attempt must never replay the grant used by the failed attempt.
final class TypefluxOfficialASRGrantFailoverTests: XCTestCase {
    private let serverA = URL(string: "https://asr-a.example.com")!
    private let serverB = URL(string: "https://asr-b.example.com")!

    func testFailoverFetchesAFreshGrantForTheNextServer() async throws {
        let routing = SequencedRoutingClient(servers: [serverA, serverB])
        let transport = GrantRecordingTransport(failingBaseURLs: [serverA.absoluteString])
        let registry = FailureRecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        let text = try await transcriber.transcribeStream(
            audioFile: makeSilentAudioFile(),
            scenario: .voiceInput,
            optimize: true,
            onUpdate: { _ in }
        )

        XCTAssertEqual(text, "ok")
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
        XCTAssertEqual(transport.attempts.map(\.baseURL), [serverA.absoluteString, serverB.absoluteString])
        let fetches = await routing.fetchCount
        XCTAssertEqual(fetches, 2)
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testLLMFailoverAlsoUsesOneGrantPerAttempt() async throws {
        let routing = SequencedRoutingClient(servers: [serverA, serverB])
        let transport = GrantRecordingTransport(failingBaseURLs: [serverA.absoluteString])
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: FailureRecordingRegistry())

        let result = try await transcriber.transcribeStreamWithLLMRewrite(
            audioFile: makeSilentAudioFile(),
            llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )

        XCTAssertEqual(result.transcript, "ok")
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
    }

    func testSuccessfulFirstServerConsumesExactlyOneGrant() async throws {
        let routing = SequencedRoutingClient(servers: [serverA, serverB])
        let transport = GrantRecordingTransport(failingBaseURLs: [])
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: FailureRecordingRegistry())

        _ = try await transcriber.transcribeStream(
            audioFile: makeSilentAudioFile(),
            scenario: .voiceInput,
            optimize: true,
            onUpdate: { _ in }
        )

        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1"])
        let fetches = await routing.fetchCount
        XCTAssertEqual(fetches, 1)
    }

    func testReplacementGrantFailureStopsFailoverWithoutBlamingTheServer() async throws {
        let routing = SequencedRoutingClient(
            servers: [serverA, serverB],
            failuresAfterFirst: TypefluxOfficialASRRoutingError.unauthorized
        )
        let transport = GrantRecordingTransport(failingBaseURLs: [serverA.absoluteString])
        let registry = FailureRecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: registry)

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(),
                scenario: .voiceInput,
                optimize: true,
                onUpdate: { _ in }
            )
            XCTFail("Expected the replacement grant failure")
        } catch let error as TypefluxOfficialASRRoutingError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertEqual(transport.attempts.count, 1)
        let failures = await registry.failures
        XCTAssertEqual(failures, [serverA])
    }

    func testAllServersFailingReportsTheLastConnectionError() async throws {
        let routing = SequencedRoutingClient(servers: [serverA, serverB])
        let transport = GrantRecordingTransport(failingBaseURLs: [serverA.absoluteString, serverB.absoluteString])
        let transcriber = makeTranscriber(routing: routing, transport: transport, registry: FailureRecordingRegistry())

        do {
            _ = try await transcriber.transcribeStream(
                audioFile: makeSilentAudioFile(),
                scenario: .voiceInput,
                optimize: true,
                onUpdate: { _ in }
            )
            XCTFail("Expected failure")
        } catch let error as TypefluxOfficialASRError {
            XCTAssertEqual(error.errorDescription, TypefluxOfficialASRError.connectionFailed("ASR_GRANT_REJECTED").errorDescription)
        }
        XCTAssertEqual(transport.attempts.map(\.token), ["grant-1", "grant-2"])
    }

    func testGrantSequenceReturnsTheInitialGrantThenFetches() async throws {
        let counter = FetchCounter()
        let sequence = TypefluxOfficialASRGrantSequence(
            initial: .webSocket(token: "first", tokenType: "Bearer", expiresAt: nil, expiresInSeconds: 60, serverBaseURLs: [])
        ) {
            let count = await counter.increment()
            return .webSocket(token: "next-\(count)", tokenType: "Bearer", expiresAt: nil, expiresInSeconds: 60, serverBaseURLs: [])
        }

        let first = try await sequence.next()
        let second = try await sequence.next()
        let third = try await sequence.next()
        XCTAssertEqual([first.token, second.token, third.token], ["first", "next-1", "next-2"])
        XCTAssertEqual(first.provider, "default")
    }

    func testGrantSequencePropagatesCancellationUnwrapped() async throws {
        let sequence = TypefluxOfficialASRGrantSequence(
            initial: .webSocket(token: "first", tokenType: "Bearer", expiresAt: nil, expiresInSeconds: 60, serverBaseURLs: [])
        ) {
            throw CancellationError()
        }
        _ = try await sequence.next()
        do {
            _ = try await sequence.next()
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    // MARK: - Helpers

    private func makeTranscriber(
        routing: SequencedRoutingClient,
        transport: GrantRecordingTransport,
        registry: FailureRecordingRegistry
    ) -> TypefluxOfficialTranscriber {
        TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: registry,
            accessTokenProvider: { "cloud-token" }
        )
    }

    private func makeSilentAudioFile() throws -> AudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-grant-\(UUID().uuidString).wav")
        let dataByteCount = 3200
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(dataByteCount))
        data.append(Data(count: dataByteCount))
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioFile(fileURL: url, duration: 0.1)
    }
}

private actor FetchCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

/// Issues a distinct one-time grant for every fetch, like the API does.
private actor SequencedRoutingClient: TypefluxOfficialASRRoutingClient {
    private let servers: [URL]
    private let failuresAfterFirst: Error?
    private(set) var fetchCount = 0

    init(servers: [URL], failuresAfterFirst: Error? = nil) {
        self.servers = servers
        self.failuresAfterFirst = failuresAfterFirst
    }

    func fetchRoute(
        accessToken _: String,
        scenario _: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        fetchCount += 1
        if fetchCount > 1, let failuresAfterFirst {
            throw failuresAfterFirst
        }
        return .webSocket(
            token: "grant-\(fetchCount)",
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: servers
        )
    }
}

private actor FailureRecordingRegistry: TypefluxASRServerProviding {
    private(set) var failures: [URL] = []

    func refreshPublicConfig() async {}

    func orderedServers(preferred: [URL]) async -> [URL] {
        preferred
    }

    func reportFailure(_ url: URL, error _: Error) async {
        failures.append(url)
    }
}

/// Simulates gateways that reject the handshake with `ASR_GRANT_REJECTED`.
private final class GrantRecordingTransport: TypefluxOfficialASRTransport, @unchecked Sendable {
    struct Attempt: Equatable {
        let baseURL: String
        let token: String
    }

    private let lock = NSLock()
    private let failingBaseURLs: Set<String>
    private var recorded: [Attempt] = []

    init(failingBaseURLs: Set<String>) {
        self.failingBaseURLs = failingBaseURLs
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
        if failingBaseURLs.contains(baseURL) {
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
