@testable import Typeflux
import Foundation
import XCTest

final class HTTPMCPClientTests: XCTestCase {
    override func tearDown() {
        MockMCPURLProtocol.requestHandler = nil
        MockMCPURLProtocol.observedRequests = []
        MockMCPURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testConnectSendsAcceptHeaderAndStoresSessionId() async throws {
        MockMCPURLProtocol.requestHandler = { request in
            let headers = [
                "Content-Type": "application/json",
                "MCP-Session-Id": "session-123",
            ]
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            let body = """
            {"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Mock MCP","version":"1.0.0"}}}
            """.data(using: .utf8)!
            return (response, body)
        }

        let client = HTTPMCPClient(config: MCPHTTPConfig(
            url: URL(string: "https://example.com/mcp")!,
            urlSession: makeMockSession(),
        ))

        try await client.connect()

        let request = try XCTUnwrap(MockMCPURLProtocol.observedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Session-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Protocol-Version"))
    }

    func testSubsequentRequestsIncludeNegotiatedProtocolVersionAndSessionId() async throws {
        MockMCPURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let body: Data

            if MockMCPURLProtocol.requestCount == 1 {
                response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "MCP-Session-Id": "session-456",
                    ]
                )!
                body = """
                {"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"Mock MCP","version":"1.0.0"}}}
                """.data(using: .utf8)!
            } else {
                response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                body = """
                {"jsonrpc":"2.0","id":"2","result":{"tools":[]}}
                """.data(using: .utf8)!
            }
            return (response, body)
        }

        let client = HTTPMCPClient(config: MCPHTTPConfig(
            url: URL(string: "https://example.com/mcp")!,
            urlSession: makeMockSession(),
        ))

        try await client.connect()
        _ = try await client.listTools()

        XCTAssertEqual(MockMCPURLProtocol.observedRequests.count, 2)
        let listRequest = MockMCPURLProtocol.observedRequests[1]
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "MCP-Session-Id"), "session-456")
        XCTAssertEqual(listRequest.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
    }

    func testConnectDecodesInitializeResponseFromSSEPayload() async throws {
        MockMCPURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/event-stream",
                    "MCP-Session-Id": "session-sse",
                ]
            )!
            let body = """
            event: message

            data: {"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"Mock SSE MCP","version":"1.0.0"}}}

            """.data(using: .utf8)!
            return (response, body)
        }

        let client = HTTPMCPClient(config: MCPHTTPConfig(
            url: URL(string: "https://example.com/mcp")!,
            urlSession: makeMockSession(),
        ))

        try await client.connect()

        let info = await client.serverInfo
        XCTAssertEqual(info?.name, "Mock SSE MCP")
        XCTAssertEqual(info?.protocolVersion, "2024-11-05")
    }

    func testDecodeMessageUsesSSEFramingWhenContentTypeIsEventStream() throws {
        let payload = """
        event: message
        data: {"jsonrpc":"2.0","id":"2","result":{"tools":[]}}

        """.data(using: .utf8)!

        let message = try HTTPMCPClient.decodeMessage(from: payload, contentType: "text/event-stream")

        XCTAssertEqual(message.id, .string("2"))
        XCTAssertEqual((message.result?["tools"]?.value as? [Any])?.count, 0)
    }

    func testRedactedDebugURLMasksSensitiveQueryItems() {
        let url = URL(string: "https://example.com/mcp?apiKey=secret&token=abc123&query=swift")!

        let result = HTTPMCPClient.redactedDebugURL(url)

        XCTAssertTrue(result.contains("apiKey=%3Credacted%3E"))
        XCTAssertTrue(result.contains("token=%3Credacted%3E"))
        XCTAssertTrue(result.contains("query=swift"))
        XCTAssertFalse(result.contains("secret"))
        XCTAssertFalse(result.contains("abc123"))
    }

    func testDebugPreviewTruncatesLargeUTF8Payloads() {
        let payload = String(repeating: "a", count: 2100)
        let result = HTTPMCPClient.debugPreview(for: Data(payload.utf8))

        XCTAssertTrue(result.contains("<truncated totalBytes=2100>"))
        XCTAssertEqual(String(result.prefix(16)), String(repeating: "a", count: 16))
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMCPURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockMCPURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static var observedRequests: [URLRequest] = []
    static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            Self.requestCount += 1
            Self.observedRequests.append(request)
            let (response, body) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
