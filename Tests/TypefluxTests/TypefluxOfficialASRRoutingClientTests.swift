@testable import Typeflux
import XCTest

final class TypefluxOfficialASRRoutingClientTests: XCTestCase {
    func testFetchRouteReturnsWebSocketDecisionWithTemporaryTokenAndServers() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/asr/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cloud-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: TypefluxCloudRequestHeaders.scenarioField), "voice-input")
            XCTAssertNil(request.httpBody)
            return (
                Data(#"{"code":"OK","message":"","data":{"token":"asr-temp","token_type":"Bearer","expires_at":1893456000,"expires_in_seconds":300,"server":["https://asr-1.example.com","http://asr-2.example.com"]}}"#
                    .utf8),
                Self.httpResponse(url: request.url!, status: 200)
            )
        }
        let client = makeClient(session: session)

        let decision = try await client.fetchRoute(accessToken: "cloud-token", scenario: .voiceInput)

        XCTAssertEqual(decision, try .webSocket(
            token: "asr-temp",
            tokenType: "Bearer",
            expiresAt: 1_893_456_000,
            expiresInSeconds: 300,
            serverBaseURLs: [
                XCTUnwrap(URL(string: "https://asr-1.example.com")),
                XCTUnwrap(URL(string: "http://asr-2.example.com"))
            ]
        ))
    }

    func testFetchRouteAllowsEmptyServerListForCachedConfigFallback() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            (
                Data(#"{"code":"OK","message":"","data":{"token":"asr-temp","token_type":"Bearer","expires_in_seconds":300,"server":[]}}"#
                    .utf8),
                Self.httpResponse(url: request.url!, status: 200)
            )
        }
        let client = makeClient(session: session)

        let decision = try await client.fetchRoute(accessToken: "cloud-token", scenario: .askAnything)

        XCTAssertEqual(decision, .webSocket(
            token: "asr-temp",
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: []
        ))
    }

    func testFetchRouteMapsKnownServerErrorCodeForUserDescription() async throws {
        let originalLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(originalLanguage) }

        let session = RoutingStubSession()
        await session.setHandler { request in
            (
                Data(#"{"code":"ASR_QUOTA_EXCEEDED","message":"raw quota message","data":null}"#.utf8),
                Self.httpResponse(url: request.url!, status: 429)
            )
        }
        let client = makeClient(session: session)

        do {
            _ = try await client.fetchRoute(accessToken: "cloud-token", scenario: .voiceInput)
            XCTFail("Expected server error")
        } catch let error as TypefluxOfficialASRRoutingError {
            XCTAssertEqual(error, .serverError(code: "ASR_QUOTA_EXCEEDED", message: "raw quota message"))
            XCTAssertEqual(error.errorDescription, "Your Typeflux Cloud usage quota has been exhausted.")
        }
    }

    private func makeClient(session: RoutingStubSession) -> TypefluxOfficialASRRoutingHTTPClient {
        let selector = CloudEndpointSelector(
            baseURLs: [URL(string: "https://api.example")!],
            prober: RoutingNoOpProber()
        )
        let executor = CloudRequestExecutor(selector: selector, session: session)
        return TypefluxOfficialASRRoutingHTTPClient(executor: executor)
    }

    private static func httpResponse(url: URL, status: Int) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

final class TypefluxASRPublicConfigClientTests: XCTestCase {
    func testFetchPublicConfigReadsInfoAndNormalizesRealtimeServers() async throws {
        let session = RoutingStubSession()
        await session.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/v1/info")
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                Data(#"{"code":"OK","message":"","data":{"realtime_servers":["https://asr-1.example.com/","http://asr-2.example.com","ftp://ignored.example.com"]}}"#
                    .utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        let selector = try CloudEndpointSelector(
            baseURLs: [XCTUnwrap(URL(string: "https://api.example"))],
            prober: RoutingNoOpProber()
        )
        let executor = CloudRequestExecutor(selector: selector, session: session)
        let client = TypefluxASRPublicConfigHTTPClient(executor: executor)

        let config = try await client.fetchPublicConfig()

        XCTAssertEqual(config.realtimeServers, try [
            XCTUnwrap(URL(string: "https://asr-1.example.com")),
            XCTUnwrap(URL(string: "http://asr-2.example.com"))
        ])
    }
}

final class TypefluxOfficialTranscriberRoutingTests: XCTestCase {
    func testPlainWebSocketRouteForwardsOptimizeDecision() async throws {
        let asrServer = try XCTUnwrap(URL(string: "https://asr-1.example.com"))
        let routing = try MockTypefluxRoutingClient(route: .webSocket(
            token: makeUnsignedJWT(payload: ["asr_provider": "doubao"]),
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: [asrServer]
        ))
        let transport = MockTypefluxTransport()
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: MockASRServerRegistry(),
            accessTokenProvider: { "cloud-token" }
        )
        let audioFile = try makeSilentAudioFile(duration: 0.1)

        _ = try await transcriber.transcribeStream(
            audioFile: audioFile,
            scenario: .voiceInput,
            optimize: false,
            onUpdate: { _ in }
        )

        XCTAssertEqual(transport.webSocketCallCount, 1)
        XCTAssertEqual(transport.lastWebSocketOptimize, false)
    }

    func testWebSocketRouteUsesTemporaryTokenAndReturnedASRServer() async throws {
        let asrServer = try XCTUnwrap(URL(string: "https://asr-1.example.com"))
        let routing = try MockTypefluxRoutingClient(route: .webSocket(
            token: makeUnsignedJWT(payload: ["asr_provider": "doubao"]),
            tokenType: "Bearer",
            expiresAt: 1_893_456_000,
            expiresInSeconds: 300,
            serverBaseURLs: [asrServer]
        ))
        let transport = MockTypefluxTransport()
        transport.webSocketLLMResult = (transcript: "raw", rewritten: "rewritten")
        let serverRegistry = MockASRServerRegistry()
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: serverRegistry,
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
        XCTAssertEqual(TypefluxOfficialASRTokenScope.provider(from: transport.lastWebSocketToken ?? ""), "doubao")
        XCTAssertEqual(transport.lastWebSocketProvider, "doubao")
        XCTAssertEqual(transport.lastWebSocketBaseURL, "https://asr-1.example.com")
        let preferredServers = await serverRegistry.lastPreferredServers()
        XCTAssertEqual(preferredServers, [asrServer])
    }

    func testWebSocketRouteFallsBackToCachedASRServerWhenTokenResponseHasNoServers() async throws {
        let cachedServer = try XCTUnwrap(URL(string: "https://cached-asr.example.com"))
        let routing = MockTypefluxRoutingClient(route: .webSocket(
            token: "asr-temp",
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: []
        ))
        let transport = MockTypefluxTransport()
        transport.webSocketLLMResult = (transcript: "raw", rewritten: "rewritten")
        let serverRegistry = MockASRServerRegistry(cachedServers: [cachedServer])
        let transcriber = TypefluxOfficialTranscriber(
            routingClient: routing,
            transport: transport,
            serverRegistry: serverRegistry,
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
        XCTAssertEqual(transport.lastWebSocketToken, "asr-temp")
        XCTAssertEqual(transport.lastWebSocketBaseURL, "https://cached-asr.example.com")
    }

    private func makeSilentAudioFile(duration: TimeInterval) throws -> AudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-routing-\(UUID().uuidString).wav")
        let sampleRate = 16000
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
    private let route: TypefluxOfficialASRRouteDecision

    init(route: TypefluxOfficialASRRouteDecision) {
        self.route = route
    }

    func fetchRoute(accessToken _: String,
                    scenario _: TypefluxCloudScenario) async throws -> TypefluxOfficialASRRouteDecision {
        route
    }
}

private actor MockASRServerRegistry: TypefluxASRServerProviding {
    private let cachedServers: [URL]
    private var preferredServers: [URL] = []
    private var failures: [URL] = []

    init(cachedServers: [URL] = []) {
        self.cachedServers = cachedServers
    }

    func refreshPublicConfig() async {}

    func orderedServers(preferred: [URL]) async -> [URL] {
        preferredServers = preferred
        return preferred.isEmpty ? cachedServers : preferred
    }

    func reportFailure(_ url: URL, error _: Error) async {
        failures.append(url)
    }

    func lastPreferredServers() -> [URL] {
        preferredServers
    }
}

private final class MockTypefluxTransport: TypefluxOfficialASRTransport, @unchecked Sendable {
    var webSocketTranscript = "websocket"
    var webSocketLLMResult: (transcript: String, rewritten: String?) = ("websocket", "merged")
    var webSocketCallCount = 0
    var webSocketLLMCallCount = 0
    var lastWebSocketBaseURL: String?
    var lastWebSocketToken: String?
    var lastWebSocketProvider: String?
    var lastWebSocketOptimize: Bool?

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocket(
        pcmData _: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario _: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        webSocketCallCount += 1
        lastWebSocketBaseURL = apiBaseURL
        lastWebSocketToken = token
        lastWebSocketProvider = provider
        lastWebSocketOptimize = optimize
        return webSocketTranscript
    }

    // swiftlint:disable:next function_parameter_count
    func transcribeViaWebSocketWithLLM(
        pcmData _: Data,
        apiBaseURL: String,
        token: String,
        provider: String,
        scenario _: TypefluxCloudScenario,
        llmConfig _: ASRLLMConfig,
        onASRUpdate _: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart _: @escaping @Sendable () async -> Void,
        onLLMChunk _: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        webSocketLLMCallCount += 1
        lastWebSocketBaseURL = apiBaseURL
        lastWebSocketToken = token
        lastWebSocketProvider = provider
        return webSocketLLMResult
    }
}

private func makeUnsignedJWT(payload: [String: String]) throws -> String {
    let header = base64URLEncoded(Data(#"{"alg":"none"}"#.utf8))
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(header).\(base64URLEncoded(payloadData))."
}

private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
