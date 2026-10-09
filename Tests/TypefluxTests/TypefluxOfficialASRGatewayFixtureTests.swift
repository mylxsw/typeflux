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
            let expected = TypefluxOfficialASRError.serverError("PROVIDER_FAILED")
            XCTAssertEqual(error.errorDescription, expected.errorDescription)
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
                    "A connections=\(gatewayA.connectionCount) audio=\(gatewayA.audioBytes) " +
                    "stop=\(gatewayA.receivedStop) " +
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

    func testBillingStopBeforeAudioIsReportedWithoutFailover() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .billingStopOnStart)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let registry = RecordingRegistry()

        do {
            _ = try await makeTranscriber(routing: routing, registry: registry).transcribeStream(
                audioFile: makeSilentAudioFile(), scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
            XCTFail("Expected the billing stop")
        } catch {
            XCTAssertNotNil(TypefluxCloudBillingError.fromError(error), "\(error)")
        }
        XCTAssertEqual(gatewayB.connectionCount, 0)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
    }

    func testLLMBillingStopAfterTranscriptKeepsTheTranscriptWithoutFailover() async throws {
        let (gatewayA, gatewayB) = try await startGateways(a: .transcriptThenBillingStop)
        let routing = RecordingRoutingClient(servers: [gatewayA.baseURL, gatewayB.baseURL])
        let registry = RecordingRegistry()

        do {
            _ = try await makeTranscriber(routing: routing, registry: registry).transcribeStreamWithLLMRewrite(
                audioFile: makeSilentAudioFile(),
                llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
                scenario: .voiceInput,
                onASRUpdate: { _ in },
                onLLMStart: {},
                onLLMChunk: { _ in }
            )
            XCTFail("Expected the billing stop")
        } catch let error as TypefluxCloudIntegratedRewriteError {
            XCTAssertEqual(error.transcript, "hello")
            XCTAssertNotNil(TypefluxCloudBillingError.fromError(error.underlyingError))
        }
        XCTAssertEqual(gatewayB.connectionCount, 0)
        let failures = await registry.failures
        XCTAssertTrue(failures.isEmpty)
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
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
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
            try await transcriber.transcribeStream(
                audioFile: audio, scenario: .voiceInput, optimize: true, onUpdate: { _ in }
            )
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

    private func startGateways(
        a behavior: LocalASRGateway.Behavior
    ) async throws -> (LocalASRGateway, LocalASRGateway) {
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
