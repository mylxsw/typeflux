import Foundation
@testable import Typeflux
import XCTest

final class HTTPMCPClientTests: XCTestCase {
    func testRegistryDefaultHTTPFactoryRetainsTransportFailure() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mcp.http.registry.\(UUID())"))
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults))
        let config = MCPServerConfig(
            name: "HTTP",
            transport: .http(MCPHTTPTransportConfig(url: "unsupported-mcp://server"))
        )
        do { try await registry.addServer(config); XCTFail("Expected unsupported URL") }
        catch let error as URLError { XCTAssertEqual(error.code, .unsupportedURL) }
        let reason = await registry.lastConnectionError(for: config.id)
        let count = await registry.connectedServerCount
        XCTAssertNotNil(reason)
        XCTAssertEqual(count, 0)
    }

    func testServerPingAndUnsupportedRequestHaveSeparateResponses() async throws {
        let server = MCPHTTPStub()
        let replies = expectation(description: "server requests answered")
        replies.expectedFulfillmentCount = 2
        server.handler = { _, message in
            if message.method == nil {
                if message.id == .number(41) {
                    XCTAssertNotNil(message.result)
                } else {
                    XCTAssertEqual(message.error?.code, -32601)
                }
                replies.fulfill()
                return .accepted
            }
            if message.method == "tools/list" {
                let frames = [
                    MCPJsonRPCMessage(id: .number(41), method: "ping"),
                    MCPJsonRPCMessage(id: .number(42), method: "sampling/createMessage"),
                    MCPJsonRPCMessage(id: message.id, result: ["tools": AnyCodable([])])
                ].map { Data("data: ".utf8) + (try! JSONEncoder().encode($0)) + Data("\n\n".utf8) }
                return .init(chunks: frames, contentType: "Text/Event-Stream; charset=utf-8", finish: false)
            }
            return .handshake(message)
        }
        let client = server.client()
        try await client.connect()
        let tools = try await client.listTools()
        XCTAssertTrue(tools.isEmpty)
        await fulfillment(of: [replies], timeout: 2)
        await client.disconnect()
    }

    func testCancellationBeforeExchangeStartsDoesNotSendRequest() async throws {
        let exchange = MCPHTTPExchange(expectedID: .string("1"), maximumResponseBytes: 1024) { _ in }
        exchange.cancel()
        do {
            _ = try await exchange.run(
                session: .shared,
                request: URLRequest(url: XCTUnwrap(URL(string: "https://unused.invalid"))),
                timeout: 1
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testStrictHandshakeAndNegotiatedHeaders() async throws {
        let server = MCPHTTPStub()
        server.handler = { request, message in
            switch message.method {
            case "initialize":
                XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Session-Id"))
                XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Protocol-Version"))
                XCTAssertEqual(message.params?["protocolVersion"]?.value as? String, "2025-06-18")
                XCTAssertEqual((message.params?["capabilities"]?.value as? [String: Any])?.count, 0)
                return .initialize(message, version: "2025-03-26", session: "session-123")
            case "notifications/initialized":
                XCTAssertNil(message.id)
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Session-Id"), "session-123")
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
                return .accepted
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Session-Id"), "session-123")
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-03-26")
                return .result(message, ["tools": []])
            }
        }
        let client = server.client(headers: [
            "MCP-Session-Id": "stale",
            "MCP-Protocol-Version": "invalid",
            "Accept": "wrong"
        ])
        try await client.connect()
        try await client.connect()
        _ = try await client.listTools()
        XCTAssertEqual(server.methods, ["initialize", "notifications/initialized", "tools/list"])
        XCTAssertTrue(server.requests
            .allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream" })
        let info = await client.serverInfo
        XCTAssertEqual(info?.protocolVersion, "2025-03-26")
        XCTAssertEqual(info?.name, "Strict MCP")
        await client.disconnect()
    }

    func testSSEIncrementalMatchingNotificationsUnicodeAndOpenStream() async throws {
        let server = MCPHTTPStub()
        let changed = expectation(description: "tools changed")
        let progress = expectation(description: "progress")
        let stopped = expectation(description: "stream released")
        server.onStop = {
            if $0 == "tools/call" {
                stopped.fulfill()
            }
        }
        server.handler = { _, message in
            guard message.method == "tools/call" else { return .handshake(message) }
            let payload = "\u{FEFF}: heartbeat\r\n\r\nevent: message\r\nid: ignored\r\n"
                + "data:\r\n\r\n"
                + "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\r\n\r\n"
                + "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"p\",\"progress\":1}}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":\"wrong\",\"error\":{\"code\":-1,\"message\":\"unrelated\"}}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":\"\(message.id!.stringValue)\",\n"
                + "data: \"result\":{\"content\":[{\"type\":\"text\",\"text\":\"你好🌍\"}]}}\n\n"
                + "data: deliberately invalid trailing frame\n\n"
            return MCPHTTPStub.Reply(
                chunks: Data(payload.utf8).map { Data([$0]) },
                contentType: "text/event-stream",
                finish: false
            )
        }
        let client = server.client()
        await client.setToolsChangedHandler { changed.fulfill() }
        await client.setNotificationHandler { message in
            if message.method == "notifications/progress" {
                XCTAssertEqual(message.params?["progress"]?.value as? Int, 1)
                progress.fulfill()
            }
        }
        try await client.connect()
        let result = try await client.callTool(name: "read", arguments: [:])
        XCTAssertEqual(result.textContent, "你好🌍")
        await fulfillment(of: [changed, progress, stopped], timeout: 2)
        let pending = await client.pendingRequestCount
        XCTAssertEqual(pending, 0)
        await client.disconnect()
    }

    func testInitializeCanUseSSEWithoutWaitingForEOF() async throws {
        let server = MCPHTTPStub()
        server.handler = { _, message in
            if message.method == "initialize" {
                let reply = MCPHTTPStub.Reply.initialize(message)
                return .init(chunks: [Data("data: ".utf8) + reply.chunks[0] + Data("\n\n".utf8)],
                             contentType: "text/event-stream", finish: false)
            }
            return .accepted
        }
        let client = server.client()
        try await client.connect()
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        await client.disconnect()
    }

    func testUnsupportedVersionAndInvalidSessionFailHandshake() async throws {
        for (version, session) in [
            ("2024-11-05", "s"),
            ("2099-01-01", "s"),
            ("2025-06-18", ""),
            ("2025-06-18", "has space")
        ] {
            let server = MCPHTTPStub()
            server.handler = { _, message in .initialize(message, version: version, session: session) }
            let client = server.client()
            do { try await client.connect(); XCTFail("Handshake should fail") }
            catch let MCPClientError.invalidResponse(reason) { XCTAssertFalse(reason.isEmpty) }
            let connected = await client.isConnected
            let pending = await client.pendingRequestCount
            XCTAssertFalse(connected)
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(server.methods, ["initialize"])
        }
    }

    func testInitializedMustBeAcceptedBeforeConnected() async throws {
        let server = MCPHTTPStub()
        server.handler = { _, message in
            message.method == "initialize" ? .initialize(message) : .init(status: 200)
        }
        let client = server.client()
        do { try await client.connect(); XCTFail("Expected rejected initialized") }
        catch let MCPClientError.invalidResponse(reason) { XCTAssertTrue(reason.contains("202")) }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testListToolsPaginatesAndPingChecksRPCError() async throws {
        let server = MCPHTTPStub()
        server.handler = { _, message in
            switch message.method {
            case "tools/list":
                let next = message.params?["cursor"]?.value as? String
                let tools: [[String: Any]] = [[
                    "name": next == nil ? "first" : "second",
                    "inputSchema": ["type": "object"]
                ]]
                return .result(message, next == nil ? ["tools": tools, "nextCursor": "next"] : ["tools": tools])
            case "ping":
                return .json(MCPJsonRPCMessage(
                    id: message.id,
                    error: MCPErrorDetail(code: -32001, message: "diagnostic reason", data: nil)
                ))
            default: return .handshake(message)
            }
        }
        let client = server.client()
        try await client.connect()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
        do { try await client.ping(); XCTFail("Expected RPC error") }
        catch let MCPClientError.serverError(code, reason) {
            XCTAssertEqual(code, -32001)
            XCTAssertEqual(reason, "diagnostic reason")
        }
        await client.disconnect()
    }

    func testMalformedMismatchedAndTruncatedResponsesFail() async throws {
        let replies: [MCPHTTPStub.Reply] = [
            .json(MCPJsonRPCMessage(id: .string("wrong"), result: [:])),
            .init(
                chunks: [Data("data: {\"jsonrpc\":\"2.0\",\"id\":\"2\",\"result\":{}}\n".utf8)],
                contentType: "text/event-stream"
            ),
            .init(chunks: [Data("data: invalid\n\n".utf8)], contentType: "text/event-stream"),
            .init(chunks: [Data([100, 97, 116, 97, 58, 0xFF, 10, 10])], contentType: "text/event-stream"),
            .json(MCPJsonRPCMessage(jsonrpc: "1.0", id: .string("2"), result: [:])),
            .json(MCPJsonRPCMessage(id: .string("2"))),
            .json(MCPJsonRPCMessage(id: .string("2"), result: [:], error: .init(code: -1, message: "both", data: nil))),
            .json(MCPJsonRPCMessage(method: "notifications/progress", result: [:])),
            .init(contentType: "text/html"),
            .init(status: 202),
            .init(status: 503)
        ]
        for reply in replies {
            let server = MCPHTTPStub()
            server.handler = { _, message in message.method == "ping" ? reply : .handshake(message) }
            let client = server.client()
            try await client.connect()
            do { try await client.ping(); XCTFail("Expected invalid response") } catch {}
            let pending = await client.pendingRequestCount
            XCTAssertEqual(pending, 0)
            await client.disconnect()
        }
    }

    func testTimeoutIsBoundedBeforeHeadersAndDuringBody() async throws {
        for sendHeaders in [false, true] {
            let server = MCPHTTPStub()
            server.handler = { _, message in
                message.method == "ping" ? .init(
                    contentType: "text/event-stream",
                    finish: false,
                    sendHeaders: sendHeaders
                ) : .handshake(message)
            }
            let client = server.client(timeout: 0.1)
            try await client.connect()
            let start = Date()
            do { try await client.ping(); XCTFail("Expected timeout") }
            catch MCPClientError.timedOut {}
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            XCTAssertEqual(server.methods.suffix(2), ["ping", "notifications/cancelled"])
            let pending = await client.pendingRequestCount
            XCTAssertEqual(pending, 0)
            await client.disconnect()
        }
    }

    func testCancelReleasesPendingAndDoesNotReplayCall() async throws {
        let server = MCPHTTPStub()
        let sent = expectation(description: "call sent")
        server.handler = { _, message in
            if message.method == "tools/call" {
                sent.fulfill()
                return .init(contentType: "text/event-stream", finish: false)
            }
            return .handshake(message)
        }
        let client = server.client()
        try await client.connect()
        let call = Task { try await client.callTool(name: "write", arguments: ["value": "x"]) }
        await fulfillment(of: [sent], timeout: 2)
        call.cancel()
        do { _ = try await call.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let pending = await client.pendingRequestCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(server.methods.filter { $0 == "tools/call" }.count, 1)
        XCTAssertTrue(server.methods.contains("notifications/cancelled"))
        await client.disconnect()
    }

    func testDisconnectCancelsConcurrentRequestsAndInjectedSessionCanReconnect() async throws {
        let server = MCPHTTPStub()
        let sent = expectation(description: "two requests")
        sent.expectedFulfillmentCount = 2
        server.handler = { _, message in
            if message.method == "ping" {
                sent.fulfill()
                return .init(finish: false, sendHeaders: false)
            }
            return .handshake(message)
        }
        let client = server.client()
        try await client.connect()
        let first = Task { try await client.ping() }
        let second = Task { try await client.ping() }
        await fulfillment(of: [sent], timeout: 2)
        await client.disconnect()
        for call in [first, second] {
            do { try await call.value; XCTFail("Expected disconnect") } catch MCPClientError.notConnected {}
        }
        let pending = await client.pendingRequestCount
        XCTAssertEqual(pending, 0)
        try await client.connect()
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        await client.disconnect()
    }

    func testSession404AndNetworkLossRehandshakeOnlyOnNextRequest() async throws {
        for networkFailure in [false, true] {
            let server = MCPHTTPStub()
            server.handler = { request, message in
                switch message.method {
                case "initialize":
                    XCTAssertNil(request.value(forHTTPHeaderField: "MCP-Session-Id"))
                    return .initialize(message, session: UUID().uuidString)
                case "tools/call": return networkFailure ? .init(failure: URLError(.networkConnectionLost)) :
                    .init(status: 404)
                case "ping": return .result(message, [:])
                default: return .accepted
                }
            }
            let client = server.client()
            try await client.connect()
            do { _ = try await client.callTool(name: "write", arguments: [:]); XCTFail("Expected failure") }
            catch { XCTAssertTrue(error is URLError || error is MCPClientError) }
            XCTAssertEqual(server.methods, ["initialize", "notifications/initialized", "tools/call"])
            let connected = await client.isConnected
            XCTAssertFalse(connected)
            try await client.ping()
            XCTAssertEqual(
                server.methods,
                [
                    "initialize",
                    "notifications/initialized",
                    "tools/call",
                    "initialize",
                    "notifications/initialized",
                    "ping"
                ]
            )
            await client.disconnect()
        }
    }

    func testConcurrentConnectsShareHandshakeAndCancelledConnectCanRetry() async throws {
        let server = MCPHTTPStub()
        let sent = expectation(description: "initialize sent")
        server.handler = { _, _ in sent.fulfill(); return .init(finish: false, sendHeaders: false) }
        let client = server.client()
        let connect = Task { try await client.connect() }
        await fulfillment(of: [sent], timeout: 2)
        connect.cancel()
        do { try await connect.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        server.handler = { _, message in .handshake(message) }
        async let first: Void = client.connect()
        async let second: Void = client.connect()
        _ = try await (first, second)
        XCTAssertEqual(server.methods, ["initialize", "initialize", "notifications/initialized"])
        await client.disconnect()
    }

    func testDisconnectDuringHandshakeCannotResurrectConnection() async throws {
        let server = MCPHTTPStub()
        let sent = expectation(description: "initialized sent")
        server.handler = { _, message in
            if message.method == "initialize" {
                return .initialize(message)
            }
            sent.fulfill()
            return .init(finish: false, sendHeaders: false)
        }
        let client = server.client()
        let connect = Task { try await client.connect() }
        await fulfillment(of: [sent], timeout: 2)
        await client.disconnect()
        do { try await connect.value; XCTFail("Expected disconnect") } catch {}
        let connected = await client.isConnected
        let info = await client.serverInfo
        XCTAssertFalse(connected)
        XCTAssertNil(info)
    }

    func testRequestsBeforeConnectionFailAndDebugURLRedactsCredentials() async throws {
        let server = MCPHTTPStub()
        let client = server.client()
        do { try await client.ping(); XCTFail("Expected disconnected") } catch MCPClientError.notConnected {}
        let url =
            try XCTUnwrap(URL(string: "https://user:pass@example.com/mcp?apiKey=secret&custom=credential#fragment"))
        let redacted = HTTPMCPClient.redactedDebugURL(url)
        for secret in ["user", "pass", "secret", "credential", "fragment"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertEqual(HTTPMCPClient.redactedDebugURL(nil), "<nil>")
    }

    func testResponseSizeLimitsForJSONAndSSE() async throws {
        for sse in [false, true] {
            let server = MCPHTTPStub()
            server.handler = { _, message in
                if message.method == "ping" {
                    return .init(chunks: [Data((sse ? "data: " : "").utf8) + Data(repeating: 65, count: 1024)],
                                 contentType: sse ? "text/event-stream" : "application/json")
                }
                return .handshake(message)
            }
            let client = server.client(maximumBytes: 512)
            try await client.connect()
            do { try await client.ping(); XCTFail("Expected size limit") }
            catch let MCPClientError.invalidResponse(reason) { XCTAssertTrue(reason.contains("size limit")) }
            await client.disconnect()
        }
    }
}

/// A per-test URLProtocol server; headers, chunks and EOF are independent events.
private final class MCPHTTPStub: @unchecked Sendable {
    struct Reply {
        var status = 200
        var chunks: [Data] = []
        var contentType = "application/json"
        var headers: [String: String] = [:]
        var finish = true
        var sendHeaders = true
        var failure: Error?

        static var accepted: Reply {
            Reply(status: 202)
        }

        static func json(_ message: MCPJsonRPCMessage) -> Reply {
            Reply(chunks: [try! JSONEncoder().encode(message)])
        }

        static func result(_ request: MCPJsonRPCMessage, _ result: [String: Any]) -> Reply {
            .json(MCPJsonRPCMessage(id: request.id, result: result.mapValues(AnyCodable.init)))
        }

        static func initialize(_ request: MCPJsonRPCMessage, version: String = "2025-06-18",
                               session: String? = nil) -> Reply {
            var reply = result(
                request,
                [
                    "protocolVersion": version,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "Strict MCP", "version": "1"]
                ]
            )
            if let session {
                reply.headers["MCP-Session-Id"] = session
            }
            return reply
        }

        static func handshake(_ message: MCPJsonRPCMessage) -> Reply {
            message.method == "initialize" ? .initialize(message) : .accepted
        }
    }

    private let lock = NSLock()
    let url = URL(string: "https://\(UUID().uuidString.lowercased()).example/mcp")!
    private var handlerValue: (URLRequest, MCPJsonRPCMessage) -> Reply = { _, message in .handshake(message) }
    private var records: [(URLRequest, MCPJsonRPCMessage)] = []
    var onStop: ((String?) -> Void)?
    var handler: (URLRequest, MCPJsonRPCMessage) -> Reply {
        get { lock.lock(); defer { lock.unlock() }; return handlerValue }
        set { lock.lock(); defer { lock.unlock() }; handlerValue = newValue }
    }

    var methods: [String] {
        lock.lock(); defer { lock.unlock() }; return records.compactMap(\.1.method)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return records.map(\.0)
    }

    init() {
        MCPHTTPStubProtocol.register(self)
    }

    deinit { MCPHTTPStubProtocol.unregister(url) }

    func client(headers: [String: String] = [:], timeout: TimeInterval = 2,
                maximumBytes: Int = 8 * 1024 * 1024) -> HTTPMCPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPHTTPStubProtocol.self]
        return HTTPMCPClient(config: MCPHTTPConfig(
            url: url,
            headers: headers,
            urlSession: URLSession(configuration: configuration),
            requestTimeout: timeout,
            maximumResponseBytes: maximumBytes
        ))
    }

    func respond(_ request: URLRequest, message: MCPJsonRPCMessage) -> Reply {
        lock.lock(); defer { lock.unlock() }
        records.append((request, message))
        return handlerValue(request, message)
    }
}

private final class MCPHTTPStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var servers: [URL: () -> MCPHTTPStub?] = [:]
    private var server: MCPHTTPStub?
    private var method: String?

    static func register(_ server: MCPHTTPStub) {
        lock.lock(); defer { lock.unlock() }
        servers[server.url] = { [weak server] in server }
    }

    static func unregister(_ url: URL) {
        lock.lock(); defer { lock.unlock() }; servers[url] = nil
    }

    private static func find(_ url: URL) -> MCPHTTPStub? {
        lock.lock(); defer { lock.unlock() }; return servers[url]?()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.flatMap(find) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let server = Self.find(url) else { return }
        self.server = server
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                body.append(buffer, count: count)
            }
        }
        do {
            let message = try JSONDecoder().decode(MCPJsonRPCMessage.self, from: body)
            method = message.method
            let reply = server.respond(request, message: message)
            if let failure = reply.failure {
                client?.urlProtocol(self, didFailWithError: failure); return
            }
            if reply.sendHeaders {
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                               headerFields: ["Content-Type": reply.contentType]
                                                   .merging(reply.headers) { $1 })!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for chunk in reply.chunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
            }
            if reply.finish {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {
        server?.onStop?(method); server = nil
    }
}
