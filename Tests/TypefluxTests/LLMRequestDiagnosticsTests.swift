import Foundation
@testable import Typeflux
import XCTest

final class LLMRequestDiagnosticsTests: XCTestCase {
    func testAttemptDerivesDetailedNetworkDurations() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let attempt = LLMRequestAttemptDiagnostics(
            id: UUID(),
            provider: "custom",
            endpoint: "https://example.com/v1/chat/completions",
            model: "test-model",
            requestStartedAt: origin,
            responseHeadersAt: origin.addingTimeInterval(0.410),
            firstSSEEventAt: origin.addingTimeInterval(0.430),
            firstParsedOutputAt: origin.addingTimeInterval(0.435),
            responseCompletedAt: origin.addingTimeInterval(0.900),
            taskCompletedAt: origin.addingTimeInterval(0.910),
            domainLookupStartedAt: origin.addingTimeInterval(0.010),
            domainLookupCompletedAt: origin.addingTimeInterval(0.030),
            connectionStartedAt: origin.addingTimeInterval(0.030),
            secureConnectionStartedAt: origin.addingTimeInterval(0.080),
            secureConnectionCompletedAt: origin.addingTimeInterval(0.180),
            connectionCompletedAt: origin.addingTimeInterval(0.180),
            requestUploadStartedAt: origin.addingTimeInterval(0.190),
            requestUploadCompletedAt: origin.addingTimeInterval(0.210),
            firstResponseByteAt: origin.addingTimeInterval(0.400),
            networkResponseCompletedAt: origin.addingTimeInterval(0.900),
            statusCode: 200,
            networkProtocolName: "h2",
            reusedConnection: false,
            requestBodyBytes: 100,
            responseBodyBytes: 200,
            sseEventCount: 4,
            jsonParseCount: 4,
            sseParsingMilliseconds: 3,
            jsonParsingMilliseconds: 5
        )

        XCTAssertEqual(attempt.dnsLookupMilliseconds, 20)
        XCTAssertEqual(attempt.tcpConnectionMilliseconds, 50)
        XCTAssertEqual(attempt.tlsHandshakeMilliseconds, 100)
        XCTAssertEqual(attempt.connectionMilliseconds, 150)
        XCTAssertEqual(attempt.requestUploadMilliseconds, 20)
        XCTAssertEqual(attempt.serverWaitMilliseconds, 190)
        XCTAssertEqual(attempt.responseDownloadMilliseconds, 500)
        XCTAssertEqual(attempt.firstSSEEventDelayMilliseconds, 30)
        XCTAssertEqual(attempt.firstParsedOutputDelayMilliseconds, 5)
        XCTAssertEqual(attempt.totalRequestMilliseconds, 910)
        XCTAssertEqual(attempt.unaccountedClientMilliseconds, 30)
    }

    func testRecorderPersistsAttemptsInOrder() {
        let recorder = LLMRequestDiagnosticsRecorder()
        let first = recorder.beginAttempt(
            provider: "openai",
            endpoint: URL(string: "https://one.example")!,
            model: "model-a"
        )
        let second = recorder.beginAttempt(
            provider: "openai",
            endpoint: URL(string: "https://two.example")!,
            model: "model-b"
        )

        recorder.markResponseHeaders(id: first, statusCode: 200)
        recorder.recordSSEParsing(id: first, duration: 0.002, yieldedEvent: true)
        recorder.recordJSONParsing(id: first, duration: 0.003, producedOutput: true)
        recorder.markResponseCompleted(id: first)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.map(\.id), [first, second])
        XCTAssertEqual(snapshot[0].statusCode, 200)
        XCTAssertEqual(snapshot[0].sseEventCount, 1)
        XCTAssertEqual(snapshot[0].jsonParseCount, 1)
        XCTAssertNotNil(snapshot[0].firstSSEEventAt)
        XCTAssertNotNil(snapshot[0].firstParsedOutputAt)
    }

    func testPipelineStatsRetainLLMRequestAttempts() {
        let recorder = LLMRequestDiagnosticsRecorder()
        _ = recorder.beginAttempt(
            provider: "openai",
            endpoint: URL(string: "https://example.com")!,
            model: "model"
        )
        var timing = HistoryPipelineTiming()
        timing.llmRequestAttempts = recorder.snapshot()

        XCTAssertEqual(timing.generatedStats().llmRequestAttempts?.count, 1)
        XCTAssertTrue(timing.hasData)
    }

    func testRealtimeTransportDerivesConnectionDurationsAndPersists() {
        let origin = Date(timeIntervalSince1970: 2_000)
        let transport = NetworkTransportDiagnosticsSnapshot(
            endpoint: "wss://asr.example.com/realtime",
            domainLookupStartedAt: origin,
            domainLookupCompletedAt: origin.addingTimeInterval(0.010),
            connectionStartedAt: origin.addingTimeInterval(0.010),
            secureConnectionStartedAt: origin.addingTimeInterval(0.040),
            secureConnectionCompletedAt: origin.addingTimeInterval(0.100),
            connectionCompletedAt: origin.addingTimeInterval(0.100),
            requestStartedAt: origin.addingTimeInterval(0.110),
            requestCompletedAt: origin.addingTimeInterval(0.120),
            firstResponseByteAt: origin.addingTimeInterval(0.180),
            responseCompletedAt: nil,
            networkProtocolName: "http/1.1",
            reusedConnection: false,
            messageParsingMilliseconds: 4,
            parsedMessageCount: 5
        )
        var timing = HistoryPipelineTiming()
        timing.realtimeTransport = transport

        XCTAssertEqual(transport.dnsLookupMilliseconds, 10)
        XCTAssertEqual(transport.tcpConnectionMilliseconds, 30)
        XCTAssertEqual(transport.tlsHandshakeMilliseconds, 60)
        XCTAssertEqual(transport.requestToUpgradeResponseMilliseconds, 60)
        XCTAssertEqual(timing.generatedStats().realtimeTransport, transport)
    }

    func testRealtimeTransportRecorderCapturesClientPreparationMilestones() {
        let recorder = NetworkTransportDiagnosticsRecorder(endpoint: nil)

        recorder.markCredentialLookupStarted()
        recorder.markCredentialLookupCompleted()
        recorder.markRouteLookupStarted()
        recorder.markRouteLookupCompleted()
        recorder.markServerSelectionStarted()
        recorder.markServerSelectionCompleted()
        recorder.updateEndpoint(URL(string: "wss://asr.example.com/realtime"))
        recorder.markWebSocketTaskResumed()
        recorder.markStartMessageSent()

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.endpoint, "wss://asr.example.com/realtime")
        XCTAssertNotNil(snapshot.credentialLookupStartedAt)
        XCTAssertNotNil(snapshot.credentialLookupCompletedAt)
        XCTAssertNotNil(snapshot.routeLookupStartedAt)
        XCTAssertNotNil(snapshot.routeLookupCompletedAt)
        XCTAssertNotNil(snapshot.serverSelectionStartedAt)
        XCTAssertNotNil(snapshot.serverSelectionCompletedAt)
        XCTAssertNotNil(snapshot.webSocketTaskResumedAt)
        XCTAssertNotNil(snapshot.startMessageSentAt)
    }
}
