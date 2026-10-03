import Foundation
import Testing
@testable import Typeflux

private actor AskHTTPStub: CloudHTTPSession {
    var requests: [URLRequest] = []
    var status = 200
    var payload: Data = Data()
    func configure(status: Int = 200, payload: Data) { self.status = status; self.payload = payload }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct AskHTTPProber: CloudEndpointProbing {
    func probe(baseURL: URL, nonce: String, timeout: TimeInterval) async throws -> CloudEndpointProbeResult {
        .init(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

@Suite("Ask HTTP contract")
struct AskAPIClientTests {
    @Test func streamingTransportDecodesSnapshotsAndCompactUpdates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskEventsURLProtocol.self]
        let selector = CloudEndpointSelector(baseURLs: [URL(string: "https://ask.example")!], prober: AskHTTPProber())
        let api = AskAPIClient(executor: CloudRequestExecutor(selector: selector), streamSession: URLSession(configuration: configuration))
        let collector = AskEventsCollector()
        try await api.observe(id: "fixture", token: "fixture-token") { value in await collector.append(value) }
        let values = await collector.values
        #expect(values.map(\.revision) == [1, 2, 3])
        #expect(values[1].messages.first?.text == "Question")
        #expect(values.last?.messages.last?.text == "你好")
        await #expect(throws: (any Error).self) {
            try await api.observe(id: "fixture", token: "invalid") { _ in }
        }
    }
    private func client(_ stub: AskHTTPStub) -> AskAPIClient {
        let selector = CloudEndpointSelector(baseURLs: [URL(string: "https://ask.example")!], prober: AskHTTPProber())
        return AskAPIClient(executor: CloudRequestExecutor(selector: selector, session: stub))
    }

    @Test func historyPaginationIsAQueryAndAuthenticationIsAttached() async throws {
        let stub = AskHTTPStub(); await stub.configure(payload: Data(#"{"code":"OK","data":[]}"#.utf8))
        let api = client(stub)
        let values = try await api.list(token: "secret", offset: 50)
        #expect(values.isEmpty)
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path == "/api/v1/ask/conversations")
        #expect(request.url?.query == "offset=50")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-Scenario") == "ask-anything")
        #expect(request.httpMethod == "GET")
    }

    @Test func mutationContractsAndResponseDecoding() async throws {
        let stub = AskHTTPStub(), api = client(stub)
        let conversation = AskConversation(id: "c", title: "Question", revision: 2, updatedAt: Date(), messages: [])
        let encoded = try AskCoding.encoder().encode(conversation)
        let envelope = Data("{\"code\":\"OK\",\"data\":".utf8) + encoded + Data("}".utf8)
        await stub.configure(payload: envelope)
        #expect(try await api.conversation(id: "c", token: "t").id == "c")
        let send = AskSendRequest(id: "m", deviceId: "device", text: "Question", tools: [])
        #expect(try await api.send(conversationId: "c", request: send, token: "t").revision == 2)
        let result = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "call", content: "observed", isError: false)
        _ = try await api.result(conversationId: "c", request: result, token: "t")
        _ = try await api.cancel(conversationId: "c", runId: "run", token: "t")
        _ = try await api.retry(conversationId: "c", runId: "run", deviceId: "device", token: "t")
        await stub.configure(payload: Data(#"{"code":"OK","data":{"deleted":true}}"#.utf8))
        try await api.delete(conversationId: "c", token: "t")
        let requests = await stub.requests
        #expect(requests.map { $0.url!.lastPathComponent } == ["c", "messages", "tool-results", "cancel", "retry", "c"])
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "POST", "POST", "POST", "DELETE"])
        let body = try #require(requests[1].httpBody)
        #expect(try AskCoding.decoder().decode(AskSendRequest.self, from: body) == send)
        #expect(try AskCoding.decoder().decode(AskToolResultRequest.self, from: requests[2].httpBody!) == result)
    }

    @Test func typedResultUsesTrustedOptInAndRetainsLegacyReceipt() async throws {
        for enabled in [false, true] {
            let stub = AskHTTPStub()
            let selector = CloudEndpointSelector(baseURLs: [URL(string: "https://ask.example")!], prober: AskHTTPProber())
            let api = AskAPIClient(executor: CloudRequestExecutor(selector: selector, session: stub),
                                   trustedPeer: enabled ? AskTypedContent.advertisement : nil, enabledCapabilities: enabled ? [.typedContent] : [])
            var receipt = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "call", content: "", isError: false)
            receipt.record(AskTypedContent.output(from: try AskTypedContentTests.result()))
            let oldMessage = AskMessage(id: "stored", role: "tool", text: receipt.content, image: receipt.image, toolCallId: "call", isError: true, createdAt: Date())
            let c = AskConversation(id: "c", title: "t", revision: 2, updatedAt: Date(), messages: [oldMessage])
            await stub.configure(payload: Data("{\"code\":\"OK\",\"data\":".utf8) + (try AskCoding.encoder().encode(c)) + Data("}".utf8))
            let response = try await api.result(conversationId: "c", request: receipt, token: "t")
            let wire = try #require(await stub.requests.last?.httpBody)
            let decoded = try AskCoding.decoder().decode(AskToolResultRequest.self, from: wire)
            #expect((decoded.harness != nil) == enabled)
            #expect(decoded.isError)
            #expect(response.messages[0].harness?.outcome?.content?.count == 7)
            #expect(response.messages[0].resultImages.count == 2)
        }
    }

    @Test func memoryPurgeDeletesPinnedMemoryForTheSignedInUser() async throws {
        let stub = AskHTTPStub(); await stub.configure(payload: Data(#"{"code":"OK","data":{"purged":3}}"#.utf8))
        try await client(stub).purgeMemory(token: "secret")
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path == "/api/v1/ask/conversations/memory")
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        await stub.configure(status: 409, payload: Data(#"{"code":"ASK_CONFLICT","message":"Failed"}"#.utf8))
        await #expect(throws: (any Error).self) { try await client(stub).purgeMemory(token: "secret") }
    }

    @Test(arguments: [nil, "cloud:vision", "custom:fixture"] as [String?])
    func retryEncodesOptionalModelReference(reference: String?) async throws {
        let stub = AskHTTPStub()
        let value = AskConversation(id: "c", title: "Screen", revision: 2, updatedAt: Date(), messages: [])
        await stub.configure(payload: Data("{\"code\":\"OK\",\"data\":".utf8) + (try AskCoding.encoder().encode(value)) + Data("}".utf8))
        let api: any AskAPI = client(stub)
        _ = try await api.retry(conversationId: "c", runId: "run", deviceId: "device", modelRef: reference, token: "t")
        let request = try #require(await stub.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(request.url?.path == "/api/v1/ask/conversations/c/retry")
        #expect(body["run_id"] == "run")
        #expect(body["device_id"] == "device")
        #expect(body["model_ref"] == reference)
    }

    @Test(arguments: [401, 409, 413])
    func httpErrorsAreNotAcceptedAsConversation(status: Int) async throws {
        let stub = AskHTTPStub(); await stub.configure(status: status, payload: Data(#"{"code":"ASK_CONFLICT","message":"Reload"}"#.utf8))
        await #expect(throws: (any Error).self) { try await client(stub).conversation(id: "c", token: "t") }
    }
}

private actor AskEventsCollector {
    var values: [AskConversation] = []
    func append(_ value: AskConversation) { values.append(value) }
}

private final class AskEventsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" &&
            request.url?.path == "/api/v1/ask/conversations/fixture/events" &&
            request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
        let response = HTTPURLResponse(url: request.url!, statusCode: authorized ? 200 : 401, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if authorized {
            let date = Date(timeIntervalSince1970: 0)
            var value = AskConversation(id: "fixture", title: "Fixture", revision: 1, updatedAt: date,
                                        messages: [.init(id: "question", role: "user", text: "Question", createdAt: date)])
            let first = String(decoding: try! AskCoding.encoder().encode(value), as: UTF8.self)
            value.revision = 3
            value.messages.append(.init(id: "answer", role: "assistant", text: "你好", createdAt: date))
            let last = String(decoding: try! AskCoding.encoder().encode(value), as: UTF8.self)
            let progress = #"{"id":"fixture","revision":2,"updated_at":"1970-01-01T00:00:00Z","run":null}"#
            let wire = "event: snapshot\ndata: \(first)\n\n: heartbeat\n\nevent: progress\ndata: \(progress)\n\nevent: progress\ndata: \(progress)\n\nevent: snapshot\ndata: \(last)\n\n"
            let data = Array(wire.utf8)
            for offset in stride(from: 0, to: data.count, by: 7) {
                client?.urlProtocol(self, didLoad: Data(data[offset..<min(data.count, offset + 7)]))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
