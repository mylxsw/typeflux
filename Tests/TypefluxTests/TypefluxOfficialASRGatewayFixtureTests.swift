import Network
@testable import Typeflux
import XCTest

/// Runs the production batch ASR session against two local WebSocket
/// gateways. Gateway A misbehaves at a scripted point; gateway B answers
/// normally, so any connection to B means the recording failed over.
final class TypefluxOfficialASRGatewayFixtureTests: XCTestCase {
    // MARK: - After audio: no failover

    func testPartialThenServerErrorDoesNotReplayOnAnotherGateway() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .partialThenError)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let updates = UpdateRecorder()

        do {
            _ = try await makeTranscriber(routing: routing).transcribeStream(
                audioFile: makeSilentAudioFile(),
                scenario: .voiceInput,
                optimize: true,
                onUpdate: { await updates.record($0.text) }
            )
            XCTFail("Expected the gateway error")
        } catch let error as TypefluxOfficialASRError {
            XCTAssertEqual(error.errorDescription, TypefluxOfficialASRError.serverError("PROVIDER_FAILED").errorDescription)
        }

        let texts = await updates.texts
        XCTAssertTrue(texts.contains("hello"))
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(gatewayA.connectionCount, 1)
        XCTAssertGreaterThan(gatewayA.audioBytes, 0)
        XCTAssertEqual(gatewayB.connectionCount, 0)
    }

    func testCloseAfterAudioWithoutOutputDoesNotReplayOnAnotherGateway() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .closeOnAudio)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])

        do {
            let text = try await makeTranscriber(routing: routing).transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail(
                "Expected the closed connection to fail the recording; got \"\(text)\", " +
                    "A connections=\(gatewayA.connectionCount) audio=\(gatewayA.audioBytes) stop=\(gatewayA.receivedStop) " +
                    "B connections=\(gatewayB.connectionCount)"
            )
        } catch is CancellationError {
            XCTFail("A closed connection is not a cancellation")
        } catch {}

        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(gatewayB.connectionCount, 0)
    }

    func testLLMErrorAfterOutputDoesNotReplayOnAnotherGateway() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .llmThenError)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let chunks = UpdateRecorder()

        do {
            _ = try await makeTranscriber(routing: routing).transcribeStreamWithLLMRewrite(
                audioFile: makeSilentAudioFile(),
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { await chunks.record($0) }
            )
            XCTFail("Expected the LLM error")
        } catch let error as TypefluxOfficialASRError {
            XCTAssertEqual(error.errorDescription, TypefluxOfficialASRError.serverError("LLM_FAILED").errorDescription)
        }

        let received = await chunks.texts
        XCTAssertEqual(received, ["Hel"])
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(gatewayB.connectionCount, 0)
    }

    // MARK: - Before audio: failover with a new grant

    func testHandshakeFailureFailsOverWithAFreshGrant() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .rejectConnection)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let registry = RecordingRegistry()

        let text = try await makeTranscriber(routing: routing, registry: registry).transcribeStream(
            audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
        )

        XCTAssertEqual(text, "ok")
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(gatewayB.connectionCount, 1)
        XCTAssertEqual(gatewayB.authorizations, ["Bearer grant-2"])
        let failures = await registry.failures
        XCTAssertEqual(failures, [gatewayA.baseURL])
    }

    // MARK: - Cancellation

    func testCancellingAnActiveStreamClosesItWithoutFailover() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .hold)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, registry: registry)
        let audio = try makeSilentAudioFile()

        let recording = Task {
            try await transcriber.transcribeStream(audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in })
        }
        try await waitUntil("gateway A received the stop message") { gatewayA.receivedStop }
        recording.cancel()

        do {
            _ = try await recording.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await waitUntil("gateway A saw the socket close") { gatewayA.disconnectCount == 1 }
        XCTAssertEqual(gatewayB.connectionCount, 0)
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    func testCancellingDuringTheHandshakeStopsWithoutFailover() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .silentTCP)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let registry = RecordingRegistry()
        let transcriber = makeTranscriber(routing: routing, registry: registry)
        let audio = try makeSilentAudioFile()

        let recording = Task {
            try await transcriber.transcribeStream(audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in })
        }
        try await waitUntil("gateway A accepted the TCP connection") { gatewayA.connectionCount == 1 }
        recording.cancel()

        do {
            _ = try await recording.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(gatewayB.connectionCount, 0)
        let fetches = await routing.accessTokens.count
        XCTAssertEqual(fetches, 1)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Helpers

    private func startGateways(a behavior: LocalASRGateway.Behavior) async throws -> (LocalASRGateway, LocalASRGateway) {
        let gatewayA = try await LocalASRGateway.start(behavior: behavior)
        let gatewayB = try await LocalASRGateway.start(behavior: .succeed("ok"))
        addTeardownBlock {
            gatewayA.stop()
            gatewayB.stop()
        }
        return (gatewayA, gatewayB)
    }

    private func makeTranscriber(
        routing: RecordingRoutingClient,
        registry: RecordingRegistry = RecordingRegistry()
    ) -> TypefluxOfficialTranscriber {
        TypefluxOfficialTranscriber(
            routingClient: routing,
            serverRegistry: registry,
            credentialProvider: { TypefluxCloudSessionCredential(accessToken: "cloud-token", session: 1) }
        )
    }

    private func makeSilentAudioFile() throws -> AudioFile {
        let url = try ASRTestAudio.writeSilentWAV()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AudioFile(fileURL: url, duration: 0.1)
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(description)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor UpdateRecorder {
    private(set) var texts: [String] = []

    func record(_ text: String) {
        texts.append(text)
    }
}

/// A WebSocket ASR gateway on 127.0.0.1 with scripted behavior.
final class LocalASRGateway: @unchecked Sendable {
    enum Behavior {
        /// Answers the stop message with a final transcript.
        case succeed(String)
        /// Sends a partial result for the first audio, then an error.
        case partialThenError
        /// Closes the connection when audio arrives, without any output.
        case closeOnAudio
        /// Sends a transcript and part of an LLM rewrite, then an error.
        case llmThenError
        /// Accepts the session and never answers.
        case hold
        /// Accepts TCP connections and closes them before the upgrade.
        case rejectConnection
        /// Accepts TCP connections and never answers the upgrade.
        case silentTCP
    }

    private let behavior: Behavior
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var state = (connections: 0, disconnects: 0, audioBytes: 0, stop: false)
    private let authorizationLog: AuthorizationLog

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
    }

    var connectionCount: Int { locked { state.connections } }
    var disconnectCount: Int { locked { state.disconnects } }
    var audioBytes: Int { locked { state.audioBytes } }
    var receivedStop: Bool { locked { state.stop } }
    var authorizations: [String] { authorizationLog.values }

    private init(behavior: Behavior) throws {
        self.behavior = behavior
        let queue = DispatchQueue(label: "LocalASRGateway")
        let authorizationLog = AuthorizationLog()
        self.queue = queue
        self.authorizationLog = authorizationLog
        let parameters = NWParameters.tcp
        switch behavior {
        case .rejectConnection, .silentTCP:
            break
        default:
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            webSocket.setClientRequestHandler(queue) { _, headers in
                authorizationLog.append(headers.first { $0.name.lowercased() == "authorization" }?.value ?? "")
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(behavior: Behavior) async throws -> LocalASRGateway {
        let gateway = try LocalASRGateway(behavior: behavior)
        try await gateway.listen()
        return gateway
    }

    func stop() {
        listener.cancel()
        locked { connections }.forEach { $0.cancel() }
    }

    private func listen() async throws {
        if case .rejectConnection = behavior {
            listener.newConnectionHandler = { [weak self] connection in
                self?.locked { self?.state.connections += 1 }
                connection.cancel()
            }
        } else {
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
        }
        let resumed = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case let .failed(error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        locked {
            state.connections += 1
            connections.append(connection)
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.locked { self?.state.disconnects += 1 }
            default:
                break
            }
        }
        connection.start(queue: queue)
        if case .silentTCP = behavior { return }
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                return
            }
            if metadata?.opcode == .binary {
                handleAudio(data ?? Data(), on: connection)
            } else if let data, let text = String(data: data, encoding: .utf8) {
                handleText(text, on: connection)
            }
            receive(on: connection)
        }
    }

    private func handleAudio(_ data: Data, on connection: NWConnection) {
        let first = locked { () -> Bool in
            let first = state.audioBytes == 0
            state.audioBytes += data.count
            return first
        }
        guard first else { return }
        switch behavior {
        case .partialThenError:
            send(["type": "partial", "text": "hello"], on: connection)
            send(["type": "error", "code": "PROVIDER_FAILED", "error": "provider failed"], on: connection)
        case .closeOnAudio:
            connection.cancel()
        default:
            break
        }
    }

    private func handleText(_ text: String, on connection: NWConnection) {
        guard text.contains("\"stop\"") else { return }
        locked { state.stop = true }
        switch behavior {
        case let .succeed(transcript):
            send(["type": "final", "text": transcript], on: connection)
            send(["type": "event", "text": "completed"], on: connection)
        case .llmThenError:
            send(["type": "final", "text": "hello"], on: connection)
            send(["type": "event", "text": "completed"], on: connection)
            send(["type": "llm_start"], on: connection)
            send(["type": "llm_chunk", "text": "Hel"], on: connection)
            send(["type": "error", "code": "LLM_FAILED", "error": "llm failed"], on: connection)
        default:
            break
        }
    }

    private func send(_ message: [String: String], on connection: NWConnection) {
        let data = try? JSONSerialization.data(withJSONObject: message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class AuthorizationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
