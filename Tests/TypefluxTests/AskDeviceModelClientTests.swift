import Foundation
import Testing
@testable import Typeflux

private final class DeviceInferenceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var seen: [URLRequest] = []
    static func reset() {
        lock.withLock { seen = [] }
    }

    static var requests: [URLRequest] {
        lock.withLock { seen }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.seen.append(request) }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer lost" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let exhausted = request.value(forHTTPHeaderField: "Authorization") == "Bearer exhausted"
        let response = HTTPURLResponse(url: request.url!, statusCode: exhausted ? 402 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let wire = exhausted ? #"{"code":"CREDITS_EXHAUSTED"}"# : """
        data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}

        data: [DONE]


        """
        client?.urlProtocol(self, didLoad: Data(wire.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct DeviceModelTestProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        .init(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor struct AskDeviceModelClientTests {
    private func client() -> AskDeviceModelClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceInferenceURLProtocol.self]
        return .init(executor: CloudRequestExecutor(selector: CloudEndpointSelector(
            baseURLs: [URL(string: "https://first.example")!, URL(string: "https://second.example")!],
            prober: DeviceModelTestProber()
        )),
        session: URLSession(configuration: config, delegate: AskModelRedirectPolicy(), delegateQueue: nil))
    }

    private let provider = RegisteredProvider(id: "cloud", name: "Cloud", remote: .typefluxCloud)
    private let payload = #"{"model":"cloud:default","messages":[{"role":"user","content":"Hello"}]}"#

    @Test func `one inference uses the stateless endpoint and the captured account credential`() async throws {
        DeviceInferenceURLProtocol.reset()
        let result = try await client().complete(provider: provider,
                                                 connection: .init(
                                                     provider: .typefluxCloud,
                                                     baseURL: "",
                                                     model: "default",
                                                     apiKey: "account-a"
                                                 ),
                                                 payload: payload, onUsage: nil, onProgress: nil)
        #expect(result.0 == "Done")
        let requests = DeviceInferenceURLProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/api/v1/ask/device/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-a")
        #expect(request.value(forHTTPHeaderField: "X-Scenario") == "ask-anything")
    }

    @Test func `transport loss never retries a possibly billed invocation on another server`() async {
        DeviceInferenceURLProtocol.reset()
        await #expect(throws: (any Error).self) {
            try await client().complete(provider: provider,
                                        connection: .init(
                                            provider: .typefluxCloud,
                                            baseURL: "",
                                            model: "default",
                                            apiKey: "lost"
                                        ),
                                        payload: payload, onUsage: nil, onProgress: nil)
        }
        #expect(DeviceInferenceURLProtocol.requests.count == 1)
    }

    @Test func `exhausted credits preserve their explicit error type`() async {
        DeviceInferenceURLProtocol.reset()
        await #expect(throws: CloudCreditsExhaustedError.self) {
            try await client().complete(provider: provider,
                                        connection: .init(
                                            provider: .typefluxCloud,
                                            baseURL: "",
                                            model: "default",
                                            apiKey: "exhausted"
                                        ),
                                        payload: payload, onUsage: nil, onProgress: nil)
        }
        #expect(DeviceInferenceURLProtocol.requests.count == 1)
    }

    @Test func `unsigned requests never open a connection`() async {
        DeviceInferenceURLProtocol.reset()
        await #expect(throws: AuthError.self) {
            try await client().complete(provider: provider,
                                        connection: .init(
                                            provider: .typefluxCloud,
                                            baseURL: "",
                                            model: "default",
                                            apiKey: ""
                                        ),
                                        payload: payload, onUsage: nil, onProgress: nil)
        }
        #expect(DeviceInferenceURLProtocol.requests.isEmpty)
    }

    @Test func `custom credentials never receive the Cloud account token`() async throws {
        DeviceInferenceURLProtocol.reset()
        let fake = RecordingAskModelClient()
        var client = client()
        client.custom = fake
        let custom = RegisteredProvider(id: "custom", name: "Custom")
        let connection = AskDeviceModelClient.authenticated(
            .init(provider: .custom, baseURL: "https://custom.example", model: "test", apiKey: "provider-key"),
            token: "account-token"
        )
        #expect(connection.apiKey == "provider-key")
        let result = try await client.complete(
            provider: custom,
            connection: connection,
            payload: payload,
            onUsage: nil,
            onProgress: nil
        )
        #expect(result.0 == "Synthetic answer")
        #expect(await fake.invocations.count == 1)
        #expect(DeviceInferenceURLProtocol.requests.isEmpty)
        let cloud = AskDeviceModelClient.authenticated(
            .init(provider: .typefluxCloud, baseURL: "", model: "default", apiKey: ""),
            token: "account-token"
        )
        #expect(cloud.apiKey == "account-token")
    }

    @Test func `invalid or expired budgeted requests never reach the provider`() async throws {
        DeviceInferenceURLProtocol.reset()
        let connection = SettingsStore.TextLLMConfiguration(
            provider: .typefluxCloud,
            baseURL: "",
            model: "default",
            apiKey: "account-token"
        )
        await #expect(throws: AskStreamError.self) {
            try await client().complete(
                provider: provider,
                connection: connection,
                payload: "[]",
                onUsage: nil,
                onProgress: nil
            )
        }
        await #expect(throws: AskBudgetError.self) {
            try await client().complete(provider: provider,
                                        connection: connection,
                                        payload: #"{"model":"cloud:default","messages":[],"typeflux_budget":true,"typeflux_deadline":1}"#,
                                        onUsage: nil, onProgress: nil)
        }
        #expect(DeviceInferenceURLProtocol.requests.isEmpty)
        _ = try await client().complete(provider: provider,
                                        connection: connection,
                                        payload: "{\"model\":\"cloud:default\",\"messages\":[],\"typeflux_budget\":true,\"typeflux_deadline\":\(Date().timeIntervalSince1970 + 60)}",
                                        onUsage: nil, onProgress: nil)
        #expect(DeviceInferenceURLProtocol.requests.last?.timeoutInterval ?? 0 <= 60)
    }
}
