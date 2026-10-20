import Foundation
import Testing
@testable import Typeflux

@Suite("Auxiliary model transport", .exclusiveUIState)
@MainActor struct AskAuxiliaryInferenceTests {
    @Test func summariesUseExistingConnectionsAndReportUsageTruncationAndFailure() async throws {
        KeychainTokenStore.useInMemoryStoreForTesting = true
        defer { KeychainTokenStore.useInMemoryStoreForTesting = false }
        let suite = "auxiliary-transport-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let profile = AskModelProfile(name: "Helper", baseURL: "https://example.invalid/v1", model: "helper-upstream")
        try library.save(profile, key: "synthetic-helper-key")
        defer { KeychainTokenStore.deleteKeychainItem(account: "ask-model-" + profile.id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuxiliaryTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AskCustomInference(session: session)
        let inference = AskInference(id: "summary", payload: AskLocalPrompt.json([
            "model": profile.reference, "typeflux_semantic_context": true, "max_tokens": 256,
            "messages": [["role": "user", "content": "Summarize this synthetic task."]]
        ]), summaryThrough: 2)
        for mode in ["stop", "length", "error"] {
            AuxiliaryTransportProtocol.configure(mode)
            let result = await AskAuxiliaryInference.complete(inference, run: "run", device: "device", library: library, client: client)
            #expect(result.inferenceId == "summary")
            if mode == "error" { #expect(result.failed) }
            else {
                #expect(!result.failed)
                #expect(result.content == "Preserve requirements.")
                #expect(result.usage?.totalTokens == 25)
                #expect(result.finishReason == (mode == "length" ? "length" : nil))
            }
            #expect(AuxiliaryTransportProtocol.callCount() == 1)
        }
        let missing = AskInference(id: "missing", payload: #"{"model":"cloud:default","messages":[]}"#, summaryThrough: 1)
        let result = await AskAuxiliaryInference.complete(missing, run: "run", device: "device", library: library, client: client)
        #expect(result.failed)
    }
}

private final class AuxiliaryTransportProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = "stop"
    nonisolated(unsafe) private static var calls = 0
    static func configure(_ value: String) { lock.withLock { mode = value; calls = 0 } }
    static func callCount() -> Int { lock.withLock { calls } }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.lock.withLock { Self.calls += 1; return Self.mode }
        let response = HTTPURLResponse(url: request.url!, statusCode: value == "error" ? 500 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let delta = #"{"choices":[{"index":0,"delta":{"content":"Preserve requirements."}}]}"#
        let end = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(value)\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":5,\"total_tokens\":25}}"
        let body = value == "error" ? "error" : "data: \(delta)\n\ndata: \(end)\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
