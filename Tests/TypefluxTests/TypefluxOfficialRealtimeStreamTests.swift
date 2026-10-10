import AVFoundation
@testable import Typeflux
import XCTest

/// Runs the production realtime Typeflux Cloud session against a local
/// WebSocket gateway: transcripts arrive, failures after audio end the
/// recording without another grant, and cancellation closes the connection.
final class TypefluxOfficialRealtimeStreamTests: XCTestCase {
    func testRealtimeSessionReturnsTheGatewayTranscript() async throws {
        let gateway = try await startGateway(.succeed("hello world"))
        let routing = RecordingRoutingClient(servers: [gateway.baseURL])
        let updates = SnapshotRecorder()
        let realtime = try await makeRealtimeSession(routing: routing, updates: updates)

        await realtime.append(try makeSilentBuffer())
        let transcript = try await realtime.finish()

        XCTAssertEqual(transcript, "hello world")
        let snapshots = await updates.snapshots
        XCTAssertEqual(snapshots.last?.text, "hello world")
        XCTAssertEqual(snapshots.last?.isFinal, true)
        XCTAssertGreaterThan(gateway.audioBytes, 0)
        XCTAssertTrue(gateway.receivedStop)
        XCTAssertEqual(gateway.authorizations, ["Bearer grant-1"])
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens, ["cloud-token"])
        try await waitUntil("the gateway saw the socket close") { gateway.disconnectCount >= 1 }
    }

    func testServerErrorAfterAPartialEndsTheRecordingWithoutAnotherGrant() async throws {
        let gateway = try await startGateway(.partialThenError)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL])
        let updates = SnapshotRecorder()
        let realtime = try await makeRealtimeSession(routing: routing, updates: updates)

        await realtime.append(try makeSilentBuffer())
        try await waitUntil("the partial result arrived") { await updates.texts.contains("hello") }

        do {
            let text = try await realtime.finish()
            XCTFail("Expected the gateway error, got \"\(text)\"")
        } catch let error as TypefluxOfficialASRError {
            let expected = TypefluxOfficialASRError.serverError("PROVIDER_FAILED")
            XCTAssertEqual(error.errorDescription, expected.errorDescription)
        }
        XCTAssertEqual(gateway.connectionCount, 1)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens.count, 1)
    }

    func testConnectionClosedAfterAudioFailsInsteadOfReturningAnEmptyTranscript() async throws {
        let gateway = try await startGateway(.closeOnAudio)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL])
        let realtime = try await makeRealtimeSession(routing: routing, updates: SnapshotRecorder())

        await realtime.append(try makeSilentBuffer())
        try await waitUntil("the gateway closed the connection") { gateway.disconnectCount >= 1 }

        do {
            let text = try await realtime.finish()
            XCTFail("Expected the closed connection to fail the recording, got \"\(text)\"")
        } catch is CancellationError {
            XCTFail("A closed connection is not a cancellation")
        } catch {}
        XCTAssertEqual(gateway.connectionCount, 1)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens.count, 1)
    }

    func testCancellingAnActiveRealtimeSessionClosesTheConnection() async throws {
        let gateway = try await startGateway(.hold)
        let routing = RecordingRoutingClient(servers: [gateway.baseURL])
        let realtime = try await makeRealtimeSession(routing: routing, updates: SnapshotRecorder())

        await realtime.append(try makeSilentBuffer())
        try await waitUntil("the gateway received audio", gateway) { gateway.audioBytes > 0 }
        await realtime.cancel()
        try await waitUntil("the gateway saw the socket close", gateway) { gateway.disconnectCount >= 1 }

        do {
            let text = try await realtime.finish()
            XCTFail("Expected cancellation, got \"\(text)\"")
        } catch is CancellationError {}
        XCTAssertFalse(gateway.receivedStop)
        XCTAssertEqual(gateway.connectionCount, 1)
        let tokens = await routing.accessTokens
        XCTAssertEqual(tokens.count, 1)
    }

    // MARK: - Helpers

    // `disconnectCount` counts state changes: one closed connection can
    // report both `.failed` and `.cancelled`, so waits accept any count.
    private func startGateway(_ behavior: LocalASRGateway.Behavior) async throws -> LocalASRGateway {
        let gateway = try await LocalASRGateway.start(behavior: behavior)
        addTeardownBlock { gateway.stop() }
        return gateway
    }

    /// A realtime session the test owns. On every exit it is cancelled and
    /// its connection attempt is joined.
    private func makeRealtimeSession(
        routing: RecordingRoutingClient,
        updates: SnapshotRecorder
    ) async throws -> any RealtimeTranscriptionSession {
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            serverRegistry: RecordingRegistry(),
            credentialProvider: { TypefluxCloudSessionCredential(accessToken: "cloud-token", session: 1) }
        )
        let realtime = try await transcriber.makeRealtimeTranscriptionSession(
            scenario: .voiceInput,
            onUpdate: { await updates.record($0) }
        )
        addTeardownBlock {
            await realtime.cancel()
            try? await (realtime as? any RealtimeTranscriptionConnectionAwaiting)?.waitUntilConnectionReady()
        }
        return realtime
    }

    /// 100 ms of 16 kHz mono silence.
    private func makeSilentBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        return buffer
    }

    private func waitUntil(
        _ description: String,
        _ gateway: LocalASRGateway? = nil,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            guard Date() < deadline else {
                let state = gateway.map {
                    " (connections=\($0.connectionCount) disconnects=\($0.disconnectCount) " +
                        "audio=\($0.audioBytes) stop=\($0.receivedStop))"
                } ?? ""
                XCTFail("Timed out waiting until \(description)\(state)")
                throw GateWaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor SnapshotRecorder {
    private(set) var snapshots: [TranscriptionSnapshot] = []

    var texts: [String] { snapshots.map(\.text) }

    func record(_ snapshot: TranscriptionSnapshot) {
        snapshots.append(snapshot)
    }
}
