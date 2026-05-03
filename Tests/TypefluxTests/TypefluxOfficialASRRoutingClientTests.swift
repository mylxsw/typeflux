import AVFoundation
@testable import Typeflux
import XCTest

final class TypefluxOfficialASRRoutingClientTests: XCTestCase {
    func testFetchRouteReturnsWebSocketDecision() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/asr/aliyun/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cloud-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.scenarioField), "voice-input")
            return (
                Data(#"{"code":"OK","message":"","data":{"type":"websocket"}}"#.utf8),
                Self.httpResponse(url: request.url!, status: 200)
            )
        }
        let client = makeClient(session: session)

        let decision = try await client.fetchRoute(accessToken: "cloud-token", scenario: .voiceInput)

        XCTAssertEqual(decision, .webSocket)
    }

    func testFetchRouteReturnsAliyunDecision() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/asr/aliyun/token")
            return (
                Data(#"{"code":"OK","message":"","data":{"type":"aliyun","token":"st-temp","expires_at":1893456000,"usage_report_id":"report-1"}}"#.utf8),
                Self.httpResponse(url: request.url!, status: 200)
            )
        }
        let client = makeClient(session: session)

        let decision = try await client.fetchRoute(accessToken: "cloud-token", scenario: .askAnything)

        XCTAssertEqual(decision, .aliyun(token: "st-temp", expiresAt: 1_893_456_000, usageReportID: "report-1"))
    }

    func testReportAliyunUsageSendsExpectedPayload() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/asr/aliyun/usage")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cloud-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.scenarioField), "ask-anything")

            let body = try XCTUnwrap(request.httpBody)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["usage_report_id"] as? String, "report-1")
            XCTAssertEqual(json?["audio_duration_ms"] as? Int, 1200)
            XCTAssertEqual(json?["output_chars"] as? Int, 32)

            return (
                Data(#"{"code":"OK","message":"","data":{"updated":true}}"#.utf8),
                Self.httpResponse(url: request.url!, status: 200)
            )
        }
        let client = makeClient(session: session)

        try await client.reportAliyunUsage(
            accessToken: "cloud-token",
            usageReportID: "report-1",
            audioDurationMs: 1200,
            outputChars: 32,
            scenario: .askAnything
        )
    }

    func testAudioDurationMeterUsesPCM16MonoAt16K() {
        XCTAssertEqual(TypefluxOfficialASRUsageMeter.audioDurationMilliseconds(pcm16ByteCount: 0), 0)
        XCTAssertEqual(TypefluxOfficialASRUsageMeter.audioDurationMilliseconds(pcm16ByteCount: 3_200), 100)
        XCTAssertEqual(TypefluxOfficialASRUsageMeter.audioDurationMilliseconds(pcm16ByteCount: 32_000), 1_000)
    }

    private func makeClient(session: RoutingStubSession) -> TypefluxOfficialASRRoutingHTTPClient {
        let selector = CloudEndpointSelector(baseURLs: [URL(string: "https://api.example")!], prober: RoutingNoOpProber())
        let executor = CloudRequestExecutor(selector: selector, session: session)
        return TypefluxOfficialASRRoutingHTTPClient(executor: executor)
    }

    private static func httpResponse(url: URL, status: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

final class TypefluxOfficialTranscriberRoutingTests: XCTestCase {
    func testAliyunRouteBypassesMergedLLMAndReportsUsage() async throws {
        let routing = MockTypefluxRoutingClient(route: .aliyun(
            token: "st-temp",
            expiresAt: 1_893_456_000,
            usageReportID: "report-1"
        ))
        let transport = MockTypefluxTransport()
        transport.directTranscript = "hello"
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            accessTokenProvider: { "cloud-token" }
        )
        let audioFile = try makeSilentAudioFile(duration: 0.1)

        let result = try await transcriber.transcribeStreamWithLLMRewrite(
            audioFile: audioFile,
            llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )
        let report = await routing.waitForReport()

        XCTAssertEqual(result.transcript, "hello")
        XCTAssertNil(result.rewritten)
        XCTAssertEqual(transport.directAliyunCallCount, 1)
        XCTAssertEqual(transport.webSocketLLMCallCount, 0)
        XCTAssertEqual(transport.lastDirectAliyunToken, "st-temp")
        XCTAssertEqual(report.accessToken, "cloud-token")
        XCTAssertEqual(report.usageReportID, "report-1")
        XCTAssertEqual(report.audioDurationMs, 100)
        XCTAssertEqual(report.outputChars, 5)
        XCTAssertEqual(report.scenario, .voiceInput)
    }

    func testWebSocketRouteKeepsMergedLLMPath() async throws {
        let routing = MockTypefluxRoutingClient(route: .webSocket)
        let transport = MockTypefluxTransport()
        transport.webSocketLLMResult = (transcript: "raw", rewritten: "rewritten")
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            accessTokenProvider: { "cloud-token" }
        )
        let audioFile = try makeSilentAudioFile(duration: 0.1)

        let result = try await transcriber.transcribeStreamWithLLMRewrite(
            audioFile: audioFile,
            llmConfig: ASRLLMConfig(systemPrompt: "system", userPromptTemplate: "{{transcript}}"),
            scenario: .voiceInput,
            onASRUpdate: { _ in },
            onLLMStart: {},
            onLLMChunk: { _ in }
        )

        XCTAssertEqual(result.transcript, "raw")
        XCTAssertEqual(result.rewritten, "rewritten")
        XCTAssertEqual(transport.webSocketLLMCallCount, 1)
        XCTAssertEqual(transport.directAliyunCallCount, 0)
        let report = await routing.currentReport()
        XCTAssertNil(report)
    }

    func testRealtimeSessionCreationDoesNotWaitForRouteFetch() async throws {
        let routing = DelayedTypefluxRoutingClient()
        let stream = RecordingPCM16RealtimeTranscriptionSession(finalText: "realtime")
        let transport = MockTypefluxTransport()
        transport.directPCMStreamFactory = { stream }
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            accessTokenProvider: { "cloud-token" }
        )

        let session = try await transcriber.makeRealtimeTranscriptionSession(
            scenario: .voiceInput,
            onUpdate: { _ in }
        )

        await session.start()
        await routing.waitUntilFetchStarted()
        let startCountBeforeRoute = await stream.startCallCount()
        XCTAssertEqual(startCountBeforeRoute, 0)

        let buffer = try makeFloatBuffer(frameCount: 1_600)
        await session.append(buffer)
        await routing.release(route: .aliyun(
            token: "st-temp",
            expiresAt: nil,
            usageReportID: "report-1"
        ))

        let transcript = try await session.finish()

        let startCountAfterFinish = await stream.startCallCount()
        let sentByteCount = await stream.sentByteCount()
        XCTAssertEqual(transcript, "realtime")
        XCTAssertEqual(startCountAfterFinish, 1)
        XCTAssertEqual(sentByteCount, CloudASRAudioConverter.chunkSize)
    }

    private func makeFloatBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: CloudASRAudioConverter.targetSampleRate,
            channels: 1,
            interleaved: false,
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for index in 0 ..< Int(frameCount) {
            channel[index] = sinf(Float(index) / 20.0) * 0.2
        }
        return buffer
    }

    private func makeSilentAudioFile(duration: TimeInterval) throws -> AudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-routing-\(UUID().uuidString).wav")
        let sampleRate = 16_000
        let channelCount = 1
        let bitsPerSample = 16
        let frameCount = Int(duration * Double(sampleRate))
        let dataByteCount = frameCount * channelCount * bitsPerSample / 8

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndianUInt32(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndianUInt32(16)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(UInt16(channelCount))
        data.appendLittleEndianUInt32(UInt32(sampleRate))
        data.appendLittleEndianUInt32(UInt32(sampleRate * channelCount * bitsPerSample / 8))
        data.appendLittleEndianUInt16(UInt16(channelCount * bitsPerSample / 8))
        data.appendLittleEndianUInt16(UInt16(bitsPerSample))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndianUInt32(UInt32(dataByteCount))
        data.append(Data(count: dataByteCount))
        try data.write(to: url)
        return AudioFile(fileURL: url, duration: duration)
    }
}

private extension Data {
    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private actor RoutingStubSession: CloudHTTPSession {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private var handler: Handler = { _ in
        (Data(), URLResponse())
    }

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private struct RoutingNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        throw CloudEndpointProbeError.timedOut
    }
}

private actor MockTypefluxRoutingClient: TypefluxOfficialASRRoutingClient {
    struct Report: Equatable {
        let accessToken: String
        let usageReportID: String
        let audioDurationMs: Int64
        let outputChars: Int
        let scenario: TypefluxCloudScenario
    }

    private let route: TypefluxOfficialASRRouteDecision
    private(set) var report: Report?
    private var reportContinuation: CheckedContinuation<Report, Never>?

    init(route: TypefluxOfficialASRRouteDecision) {
        self.route = route
    }

    func fetchRoute(accessToken _: String, scenario _: TypefluxCloudScenario) async throws -> TypefluxOfficialASRRouteDecision {
        route
    }

    func reportAliyunUsage(
        accessToken: String,
        usageReportID: String,
        audioDurationMs: Int64,
        outputChars: Int,
        scenario: TypefluxCloudScenario
    ) async throws {
        let report = Report(
            accessToken: accessToken,
            usageReportID: usageReportID,
            audioDurationMs: audioDurationMs,
            outputChars: outputChars,
            scenario: scenario
        )
        self.report = report
        reportContinuation?.resume(returning: report)
        reportContinuation = nil
    }

    func waitForReport() async -> Report {
        if let report { return report }
        return await withCheckedContinuation { continuation in
            reportContinuation = continuation
        }
    }

    func currentReport() -> Report? {
        report
    }
}

private actor DelayedTypefluxRoutingClient: TypefluxOfficialASRRoutingClient {
    private var fetchStartedContinuation: CheckedContinuation<Void, Never>?
    private var routeContinuation: CheckedContinuation<TypefluxOfficialASRRouteDecision, Never>?
    private var didStartFetch = false

    func fetchRoute(
        accessToken _: String,
        scenario _: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        didStartFetch = true
        fetchStartedContinuation?.resume()
        fetchStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            routeContinuation = continuation
        }
    }

    func reportAliyunUsage(
        accessToken _: String,
        usageReportID _: String,
        audioDurationMs _: Int64,
        outputChars _: Int,
        scenario _: TypefluxCloudScenario
    ) async throws {}

    func waitUntilFetchStarted() async {
        if didStartFetch { return }
        await withCheckedContinuation { continuation in
            fetchStartedContinuation = continuation
        }
    }

    func release(route: TypefluxOfficialASRRouteDecision) {
        routeContinuation?.resume(returning: route)
        routeContinuation = nil
    }
}

private final class MockTypefluxTransport: TypefluxOfficialASRTransport, @unchecked Sendable {
    var directTranscript = "direct"
    var webSocketTranscript = "websocket"
    var webSocketLLMResult: (transcript: String, rewritten: String?) = ("websocket", "merged")
    var directAliyunCallCount = 0
    var webSocketCallCount = 0
    var webSocketLLMCallCount = 0
    var lastDirectAliyunToken: String?
    var directPCMStreamFactory: @Sendable () -> any PCM16RealtimeTranscriptionSession = {
        MockPCM16RealtimeTranscriptionSession()
    }

    func transcribeViaWebSocket(
        pcmData _: Data,
        apiBaseURL _: String,
        token _: String,
        scenario _: TypefluxCloudScenario,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        webSocketCallCount += 1
        return webSocketTranscript
    }

    func transcribeViaWebSocketWithLLM(
        pcmData _: Data,
        apiBaseURL _: String,
        token _: String,
        scenario _: TypefluxCloudScenario,
        llmConfig _: ASRLLMConfig,
        onASRUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart _: @escaping @Sendable () async -> Void,
        onLLMChunk _: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        webSocketLLMCallCount += 1
        return webSocketLLMResult
    }

    func transcribeViaDirectAliyun(
        pcmData _: Data,
        token: String,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        directAliyunCallCount += 1
        lastDirectAliyunToken = token
        return directTranscript
    }

    func makeDirectAliyunPCMStream(
        token: String,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) -> any PCM16RealtimeTranscriptionSession {
        lastDirectAliyunToken = token
        return directPCMStreamFactory()
    }
}

private actor MockPCM16RealtimeTranscriptionSession: PCM16RealtimeTranscriptionSession {
    func start() async throws {}
    func appendPCM16(_: Data) async throws {}
    func finish() async throws -> String { "realtime" }
    func cancel() async {}
}

private actor RecordingPCM16RealtimeTranscriptionSession: PCM16RealtimeTranscriptionSession {
    private let finalText: String
    private var starts = 0
    private var chunks: [Data] = []

    init(finalText: String) {
        self.finalText = finalText
    }

    func start() async throws {
        starts += 1
    }

    func appendPCM16(_ data: Data) async throws {
        chunks.append(data)
    }

    func finish() async throws -> String {
        finalText
    }

    func cancel() async {}

    func startCallCount() -> Int {
        starts
    }

    func sentByteCount() -> Int {
        chunks.reduce(0) { $0 + $1.count }
    }
}
