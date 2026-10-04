import Foundation
import XCTest
@testable import TypefluxChat

/// Every test uses a unique URL host so URLSession callbacks cannot read another
/// test's fixture. Synchronization is confined to this URLProtocol bridge.
private final class FixtureRegistry: @unchecked Sendable {
    typealias Handler = (URLRequest, URLProtocolClient, URLProtocol) throws -> Void
    let lock = NSLock()
    var handlers: [String: Handler] = [:]
    func set(_ host: String, _ handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handlers[host] = handler }
    func get(_ host: String) -> Handler? { lock.lock(); defer { lock.unlock() }; return handlers[host] }
    func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host) }
}

private final class FixtureProtocol: URLProtocol {
    static let registry = FixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let client, let handler = Self.registry.get(request.url!.host!) else { return }
        do { try handler(request, client, self) } catch { client.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ChatAPIClientTests: XCTestCase {
    private func fixture(_ handler: @escaping FixtureRegistry.Handler) -> (ChatAPIClient, URLSession, String) {
        let host = UUID().uuidString.lowercased() + ".test"
        FixtureProtocol.registry.set(host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        return (ChatAPIClient(baseURL: URL(string: "https://\(host)/proxy")!, session: session, deviceId: "phone"), session, host)
    }

    private func finish(_ request: URLRequest, _ client: URLProtocolClient, _ proto: URLProtocol,
                        body: String, status: Int = 200, contentType: String = "application/json") {
        client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(proto, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(proto)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return try JSONSerialization.jsonObject(with: result) as! [String: Any]
    }

    func testLoginRefreshLogoutWireContract() async throws {
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try self.body(request)
            if request.url!.path.hasSuffix("/login") {
                XCTAssertEqual(body["email"] as? String, "user@example.test")
                XCTAssertEqual(body["password"] as? String, "password")
            } else { XCTAssertEqual(body["refresh_token"] as? String, "refresh") }
            let payload = request.url!.path.hasSuffix("/logout") ? #"{"logged_out":true}"# : #"{"access_token":"access","expires_at":123,"refresh_token":"refresh"}"#
            self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(payload)}")
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let login = try await api.login(email: "user@example.test", password: "password")
        XCTAssertEqual(login.accessToken, "access")
        let refresh = try await api.refresh(refreshToken: "refresh")
        XCTAssertEqual(refresh.refreshToken, "refresh")
        try await api.logout(refreshToken: "refresh")
    }

    func testModelsListDetailSendAndCancelWireContracts() async throws {
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Scenario"), "ask-anything")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Typeflux-Model-Catalog"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-OS"), "iOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-ID"), "phone")
            let path = request.url!.path
            var payload = chatSnapshot
            if path.hasSuffix("/models") {
                payload = #"[{"id":"model","name":"Model","vision":true,"future":{}}]"#
            } else if path.hasSuffix("/conversations") {
                XCTAssertEqual(request.url!.query, "offset=0")
                payload = "[\(chatSnapshot)]"
            } else if path.hasSuffix("/messages") {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try self.body(request)
                XCTAssertEqual(body["id"] as? String, "message")
                XCTAssertEqual(body["device_id"] as? String, "phone")
                XCTAssertEqual(body["tools"] as? [String], [])
                XCTAssertEqual(body["platform"] as? String, "iOS")
                XCTAssertEqual(body["text"] as? String, "Hello")
            } else if path.hasSuffix("/cancel") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(try self.body(request)["run_id"] as? String, "run")
            } else { XCTAssertEqual(path, "/proxy/api/v1/ask/conversations/chat") }
            self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(payload)}")
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let models = try await api.models(token: "access")
        XCTAssertEqual(models.first?.reference, "cloud:model")
        let list = try await api.list(token: "access", offset: -1)
        XCTAssertEqual(list.first?.id, "chat")
        let detail = try await api.conversation(id: "chat", token: "access")
        XCTAssertEqual(detail.messages.first?.text, "hello")
        let sent = try await api.send(conversationId: "chat", request: .init(id: "message", deviceId: "phone", text: "Hello"), token: "access")
        XCTAssertEqual(sent.id, "chat")
        let cancelled = try await api.cancel(conversationId: "chat", runId: "run", token: "access")
        XCTAssertEqual(cancelled.id, "chat")
    }

    func testEveryConversationRouteUsesTheRealUUIDWithoutDoubleEncoding() async throws {
        let id = "550e8400-e29b-41d4-a716-446655440000"
        let snapshot = chatSnapshot.replacingOccurrences(of: "\"id\":\"chat\"", with: "\"id\":\"\(id)\"")
        let (api, session, host) = fixture { request, client, proto in
            let url = try XCTUnwrap(request.url)
            XCTAssertTrue(url.path.hasPrefix("/proxy/api/v1/ask/conversations/" + id))
            XCTAssertFalse(url.absoluteString.contains("%25"))
            XCTAssertFalse(url.absoluteString.contains("%2D"))
            if url.path.hasSuffix("/events") {
                self.finish(request, client, proto, body: "event: snapshot\ndata: \(snapshot)\n\n", contentType: "text/event-stream")
            } else {
                self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(snapshot)}")
            }
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let detail = try await api.conversation(id: id, token: "access")
        XCTAssertEqual(detail.id, id)
        let sent = try await api.send(conversationId: id, request: .init(deviceId: id, text: "Hello"), token: "access")
        XCTAssertEqual(sent.id, id)
        let cancelled = try await api.cancel(conversationId: id, runId: id, token: "access")
        XCTAssertEqual(cancelled.id, id)
        try await api.observe(id: id, token: "access") { value in XCTAssertEqual(value.id, id) }
    }

    func testSendCarriesChosenReasoningEffortAndOmitsAutoOnActualHTTPBody() async throws {
        for effort in [nil, "xhigh"] as [String?] {
            let (api, session, host) = fixture { request, client, proto in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(request.url!.path.hasSuffix("/messages"))
                let body = try self.body(request)
                XCTAssertEqual(body["reasoning_effort"] as? String, effort)
                XCTAssertEqual(body["model_ref"] as? String, "cloud:reasoner")
                if effort == nil { XCTAssertFalse(body.keys.contains("reasoning_effort")) }
                self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(chatSnapshot)}")
            }
            defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
            _ = try await api.send(conversationId: "chat", request: .init(deviceId: "phone", text: "Hello",
                modelRef: "cloud:reasoner", reasoningEffort: effort), token: "access")
        }
    }

    func testUnauthorizedDoesNotRequireJSONOrRetryMutation() async throws {
        let (api, session, host) = fixture { request, client, proto in
            self.finish(request, client, proto, body: "Unauthorized", status: 401)
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        do { _ = try await api.login(email: "e", password: "p"); XCTFail("Expected unauthorized") }
        catch { XCTAssertEqual(error as? ChatAPIError, .unauthorized) }
    }

    func testObserveConsumesChunkedSnapshotsAndProgress() async throws {
        actor Values {
            var values: [ChatConversation] = []
            func append(_ value: ChatConversation) { values.append(value) }
        }
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.url!.path, "/proxy/api/v1/ask/conversations/chat/events")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
            let wire = "event: snapshot\ndata: \(chatSnapshot)\n\nevent: progress\ndata: \(chatProgress)\n\n"
            for byte in wire.utf8 { client.urlProtocol(proto, didLoad: Data([byte])) }
            client.urlProtocolDidFinishLoading(proto)
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let collected = Values()
        try await api.observe(id: "chat", token: "access") { await collected.append($0) }
        let values = await collected.values
        XCTAssertEqual(values.map(\.revision), [1, 2])
        XCTAssertEqual(values.last?.run?.preview, "Hi")
    }

    func testObserveRejectsHTTPFailuresAndWrongContentType() async throws {
        for status in [401, 503, 200] {
            let (api, session, host) = fixture { request, client, proto in
                self.finish(request, client, proto, body: "{}", status: status)
            }
            defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
            do { try await api.observe(id: "chat", token: "access") { _ in }; XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ChatAPIError, status == 401 ? .unauthorized : .unavailable) }
        }
    }

    func testCancellationInterruptsAnOpenEventStream() async throws {
        let started = expectation(description: "Stream opened")
        let (api, session, host) = fixture { request, client, proto in
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: Data(": keepalive\n\n".utf8))
            started.fulfill()
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let task = Task { try await api.observe(id: "chat", token: "access") { _ in } }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testCancelledRequestNeverStartsNetworkOperation() async throws {
        let (api, session, host) = fixture { _, _, _ in XCTFail("Cancelled task started a network request") }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await api.models(token: "access"); XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            do { try await api.observe(id: "chat", token: "access") { _ in }; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
}
