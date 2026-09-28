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

    @Test(arguments: [401, 409, 413])
    func httpErrorsAreNotAcceptedAsConversation(status: Int) async throws {
        let stub = AskHTTPStub(); await stub.configure(status: status, payload: Data(#"{"code":"ASK_CONFLICT","message":"Reload"}"#.utf8))
        await #expect(throws: (any Error).self) { try await client(stub).conversation(id: "c", token: "t") }
    }
}
