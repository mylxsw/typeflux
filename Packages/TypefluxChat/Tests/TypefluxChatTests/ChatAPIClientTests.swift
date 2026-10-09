import Foundation
@testable import TypefluxChat
import XCTest

/// Every test uses a unique URL host so URLSession callbacks cannot read another
/// test's fixture. Synchronization is confined to this URLProtocol bridge.
private final class FixtureRegistry: @unchecked Sendable {
    typealias Handler = (URLRequest, URLProtocolClient, URLProtocol) throws -> Void
    let lock = NSLock()
    var handlers: [String: Handler] = [:]
    func set(_ host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }

    func get(_ host: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }; return handlers[host]
    }

    func remove(_ host: String) {
        lock.lock(); defer { lock.unlock() }; handlers.removeValue(forKey: host)
    }
}

private final class FixtureProtocol: URLProtocol {
    static let registry = FixtureRegistry()
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
        return (
            ChatAPIClient(baseURL: URL(string: "https://\(host)/proxy")!, session: session, deviceId: "phone"),
            session,
            host
        )
    }

    private func finish(_ request: URLRequest, _ client: URLProtocolClient, _ proto: URLProtocol,
                        body: String, status: Int = 200, contentType: String = "application/json") {
        client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                              headerFields: ["Content-Type": contentType])!,
                           cacheStoragePolicy: .notAllowed)
        client.urlProtocol(proto, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(proto)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody {
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
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
            } else {
                XCTAssertEqual(body["refresh_token"] as? String, "refresh")
            }
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

    func testGoogleLoginAndTokenExchangeWireContracts() async throws {
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.url?.path, "/proxy/api/v1/auth/oauth/google")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(try self.body(request)["id_token"] as? String, "google-token")
            self.finish(request, client, proto,
                        body: #"{"code":"OK","data":{"access_token":"access","expires_at":123,"refresh_token":"refresh"}}"#)
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let account = try await api.googleLogin(identityToken: "google-token")
        XCTAssertEqual(account.accessToken, "access")
        XCTAssertEqual(account.refreshToken, "refresh")
        FixtureProtocol.registry.set("oauth2.googleapis.com") { request, client, proto in
            XCTAssertEqual(request.url?.path, "/token")
            self.finish(request, client, proto, body: #"{"id_token":"google-token"}"#)
        }
        defer { FixtureProtocol.registry.remove("oauth2.googleapis.com") }
        let auth = try GoogleOAuthAuthorization.make(clientID: "123-ios.apps.googleusercontent.com")
        let token = try await auth.exchange(code: "authorization-code", session: session)
        XCTAssertEqual(token, "google-token")
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
            } else {
                XCTAssertEqual(path, "/proxy/api/v1/ask/conversations/chat")
            }
            self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(payload)}")
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let models = try await api.models(token: "access")
        XCTAssertEqual(models.first?.reference, "cloud:model")
        let list = try await api.list(token: "access", offset: -1)
        XCTAssertEqual(list.first?.id, "chat")
        let detail = try await api.conversation(id: "chat", token: "access")
        XCTAssertEqual(detail.messages.first?.text, "hello")
        let sent = try await api.send(
            conversationId: "chat",
            request: .init(id: "message", deviceId: "phone", text: "Hello"),
            token: "access"
        )
        XCTAssertEqual(sent.id, "chat")
        let cancelled = try await api.cancel(conversationId: "chat", runId: "run", token: "access")
        XCTAssertEqual(cancelled.id, "chat")
    }

    func testAccountAppleResetRegenerateAndDeleteWireContracts() async throws {
        let (api, session, host) = fixture { request, client, proto in
            let path = request.url!.path
            var payload = chatSnapshot
            switch path {
            case "/proxy/api/v1/auth/oauth/apple":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(try self.body(request)["id_token"] as? String, "apple-token")
                payload = #"{"access_token":"access","expires_at":123,"refresh_token":"refresh"}"#
            case "/proxy/api/v1/auth/forgot-password":
                XCTAssertEqual(try self.body(request)["email"] as? String, "me@example.test")
                payload = #"{"sent":true}"#
            case "/proxy/api/v1/auth/reset-password":
                let body = try self.body(request)
                XCTAssertEqual(body["code"] as? String, "123456")
                XCTAssertEqual(body["new_password"] as? String, "new-password")
                payload = #"{"reset":true}"#
            case "/proxy/api/v1/me":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
                payload = #"{"id":"u1","email":"me@example.test","name":"Me","status":1,"providers":["apple"]}"#
            case "/proxy/api/v1/usage/current-period/stats":
                payload = #"{"period_start":"2026-10-01T00:00:00Z","period_end":"2026-11-01T00:00:00Z","plan_code":"pro","paid":true,"period_source":"subscription","stats":{},"credits":{"limit":500,"used":200,"remaining":300,"unlimited":false,"total_remaining":1300,"addon":{"balance":1000,"used_this_period":0,"remaining":1000,"next_expiry":{"credits":1000,"expires_at":"2027-10-01T00:00:00Z"}}}}"#
            case "/proxy/api/v1/ask/conversations/chat/regenerate":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try self.body(request)
                XCTAssertEqual(body["message_id"] as? String, "answer")
                XCTAssertEqual(body["device_id"] as? String, "phone")
                XCTAssertEqual(body["model_ref"] as? String, "cloud:model")
                XCTAssertEqual(body["tools"] as? [String], [])
            case "/proxy/api/v1/ask/conversations/chat":
                XCTAssertEqual(request.httpMethod, "DELETE")
                payload = #"{"deleted":true}"#
            default:
                XCTFail("Unexpected path \(path)")
            }
            self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(payload)}")
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let apple = try await api.appleLogin(identityToken: "apple-token")
        XCTAssertEqual(apple.accessToken, "access")
        try await api.forgotPassword(email: "me@example.test")
        try await api.resetPassword(email: "me@example.test", code: "123456", newPassword: "new-password")
        let profile = try await api.profile(token: "access")
        XCTAssertEqual(profile, ChatProfile(id: "u1", email: "me@example.test", name: "Me", providers: ["apple"]))
        let usage = try await api.creditUsage(token: "access")
        XCTAssertEqual(usage.credits.remaining, 300)
        XCTAssertEqual(usage.addonRemaining, 1000)
        XCTAssertTrue(usage.paid)
        XCTAssertEqual(usage.usedFraction ?? 0, 0.4, accuracy: 0.0001)
        let regenerated = try await api.regenerate(
            conversationId: "chat",
            request: .init(messageId: "answer", deviceId: "phone", modelRef: "cloud:model"),
            token: "access"
        )
        XCTAssertEqual(regenerated.id, "chat")
        try await api.deleteConversation(id: "chat", token: "access")
    }

    func testAddonRemainingHidesEmptyOrMissingPools() {
        let end = Date(timeIntervalSince1970: 0)
        XCTAssertNil(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                     credits: .init(limit: 100, used: 0, remaining: 100)).addonRemaining)
        XCTAssertNil(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                     credits: .init(limit: 100, used: 0, remaining: 100,
                                                    addon: .init(remaining: 0))).addonRemaining)
        XCTAssertEqual(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                       credits: .init(limit: 100, used: 100, remaining: 0,
                                                      addon: .init(remaining: 42))).addonRemaining, 42)
    }

    func testCreditFractionClampsAndSkipsUnlimitedPlans() {
        let end = Date(timeIntervalSince1970: 0)
        XCTAssertNil(ChatCreditUsage(periodEnd: end, planCode: "max", paid: true,
                                     credits: .init(limit: 0, used: 0, remaining: 0, unlimited: true)).usedFraction)
        XCTAssertNil(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                     credits: .init(limit: 0, used: 5, remaining: 0)).usedFraction)
        XCTAssertEqual(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                       credits: .init(limit: 100, used: 150, remaining: 0)).usedFraction, 1)
        XCTAssertEqual(ChatCreditUsage(periodEnd: end, planCode: "free", paid: false,
                                       credits: .init(limit: 100, used: -5, remaining: 105)).usedFraction, 0)
    }

    func testOptionalEndpointsReportUnavailableOnMinimalImplementations() async {
        struct Minimal: ChatAPI {
            func login(email _: String,
                       password _: String) async throws -> ChatSession {
                throw ChatAPIError.unavailable
            }

            func refresh(refreshToken _: String) async throws -> ChatSession {
                throw ChatAPIError.unavailable
            }

            func logout(refreshToken _: String) async throws {}
            func models(token _: String) async throws -> [ChatModel] {
                []
            }

            func list(token _: String, offset _: Int) async throws -> [ChatConversationSummary] {
                []
            }

            func conversation(id _: String,
                              token _: String) async throws -> ChatConversation {
                throw ChatAPIError.unavailable
            }

            func send(conversationId _: String, request _: ChatSendRequest,
                      token _: String) async throws -> ChatConversation {
                throw ChatAPIError.unavailable
            }

            func cancel(conversationId _: String, runId _: String, token _: String) async throws -> ChatConversation {
                throw ChatAPIError.unavailable
            }

            func observe(
                id _: String,
                token _: String,
                onValue _: @Sendable (ChatConversation) async throws -> Void
            ) async throws {}
        }
        let api = Minimal()
        func expectUnavailable(_ operation: () async throws -> Void) async {
            do { try await operation(); XCTFail("Expected unavailable") } catch {
                XCTAssertEqual(error as? ChatAPIError, .unavailable)
            }
        }
        await expectUnavailable { _ = try await api.appleLogin(identityToken: "t") }
        await expectUnavailable { try await api.forgotPassword(email: "e") }
        await expectUnavailable { try await api.resetPassword(email: "e", code: "c", newPassword: "p") }
        await expectUnavailable { _ = try await api.profile(token: "t") }
        await expectUnavailable { _ = try await api.creditUsage(token: "t") }
        await expectUnavailable {
            _ = try await api.regenerate(conversationId: "c", request: .init(messageId: "m", deviceId: "d"), token: "t")
        }
        await expectUnavailable { try await api.deleteConversation(id: "c", token: "t") }
        await expectUnavailable { _ = try await api.appleCreditPacks(language: "en", token: "t") }
        await expectUnavailable { _ = try await api.submitAppleTransaction("jws", token: "t") }
        await expectUnavailable { _ = try await api.resume(conversationId: "c", runId: "r", token: "t") }
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
                self.finish(
                    request,
                    client,
                    proto,
                    body: "event: snapshot\ndata: \(snapshot)\n\n",
                    contentType: "text/event-stream"
                )
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
                if effort == nil {
                    XCTAssertFalse(body.keys.contains("reasoning_effort"))
                }
                self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(chatSnapshot)}")
            }
            defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
            _ = try await api.send(conversationId: "chat", request: .init(
                deviceId: "phone",
                text: "Hello",
                modelRef: "cloud:reasoner",
                reasoningEffort: effort
            ), token: "access")
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
            func append(_ value: ChatConversation) {
                values.append(value)
            }
        }
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.url!.path, "/proxy/api/v1/ask/conversations/chat/events")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            client.urlProtocol(proto, didReceive: HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
            )!, cacheStoragePolicy: .notAllowed)
            let wire = "event: snapshot\ndata: \(chatSnapshot)\n\nevent: progress\ndata: \(chatProgress)\n\n"
            for byte in wire.utf8 {
                client.urlProtocol(proto, didLoad: Data([byte]))
            }
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

    func testPhotoSendAndEventStreamPreserveImagesToolsReasoningAndTerminalError() async throws {
        actor Values {
            var snapshots: [ChatConversation] = []
            func append(_ value: ChatConversation) {
                snapshots.append(value)
            }
        }
        let initial = #"{"id":"chat","title":"Photos","revision":1,"updated_at":"2026-01-02T03:04:05Z","messages":[{"id":"photo","role":"user","text":"Compare","created_at":"2026-01-02T03:04:05Z","image":"data:image/jpeg;base64,mobile","attachments":[{"id":"desktop-photo","kind":"image","name":"reference.jpg","image":"data:image/jpeg;base64,desktop"}]}],"run":{"id":"run","device_id":"phone","status":"running","updated_at":"2026-01-02T03:04:05Z"}}"#
        let progress = #"{"id":"chat","revision":2,"updated_at":"2026-01-02T03:04:06Z","run":{"id":"run","device_id":"phone","status":"waiting_tool","updated_at":"2026-01-02T03:04:06Z","reasoning":"Checking references","reasoning_milliseconds":1300,"preview":"Partial answer","pending":[{"id":"tool","type":"function","function":{"name":"web_fetch","arguments":"{}"}}]}}"#
        let terminal = #"{"id":"chat","revision":3,"updated_at":"2026-01-02T03:04:07Z","run":{"id":"run","device_id":"phone","status":"failed","updated_at":"2026-01-02T03:04:07Z","preview":"Partial answer","error":"Tool unavailable"}}"#
        let (api, session, host) = fixture { request, client, proto in
            if request.url!.path.hasSuffix("/messages") {
                let body = try self.body(request)
                XCTAssertEqual(body["image"] as? String, "data:image/jpeg;base64,mobile")
                XCTAssertEqual(body["reasoning_effort"] as? String, "high")
                XCTAssertEqual(body["tools"] as? [String], [])
                self.finish(request, client, proto, body: "{\"code\":\"OK\",\"data\":\(initial)}")
            } else {
                XCTAssertTrue(request.url!.path.hasSuffix("/events"))
                let wire = "event: snapshot\ndata: \(initial)\n\nevent: progress\ndata: \(progress)\n\nevent: progress\ndata: \(terminal)\n\n"
                self.finish(request, client, proto, body: wire, contentType: "text/event-stream")
            }
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let sent = try await api.send(conversationId: "chat", request: .init(
            deviceId: "phone",
            text: "Compare",
            image: "data:image/jpeg;base64,mobile",
            modelRef: "cloud:vision",
            reasoningEffort: "high"
        ), token: "access")
        XCTAssertTrue(sent.run?.isActive == true)
        let values = Values()
        try await api.observe(id: "chat", token: "access") { await values.append($0) }
        let snapshots = await values.snapshots
        XCTAssertEqual(snapshots.map(\.revision), [1, 2, 3])
        XCTAssertEqual(snapshots[1].run?.pending.first?.function.name, "web_fetch")
        XCTAssertEqual(snapshots[1].run?.reasoning, "Checking references")
        XCTAssertEqual(snapshots[1].run?.reasoningMilliseconds, 1300)
        XCTAssertEqual(snapshots[1].run?.requiresDesktop, true)
        XCTAssertEqual(snapshots.last?.messages.first?.imageDataURLs,
                       ["data:image/jpeg;base64,mobile", "data:image/jpeg;base64,desktop"])
        XCTAssertEqual(snapshots.last?.run?.error, "Tool unavailable")
        XCTAssertEqual(snapshots.last?.run?.preview, "Partial answer")
        XCTAssertEqual(snapshots.last?.run?.isActive, false)
    }

    func testCancellationInterruptsAnOpenEventStream() async throws {
        let started = expectation(description: "Stream opened")
        let (api, session, host) = fixture { request, client, proto in
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                                  headerFields: ["Content-Type": "text/event-stream"])!,
                               cacheStoragePolicy: .notAllowed)
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

    func testCancelledRequestNeverStartsNetworkOperation() async {
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

extension ChatAPIClientTests {
    func testPrivacyDeletionAndPrivateReportWireContracts() async throws {
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            switch request.url!.path {
            case let path where path.hasSuffix("/privacy/ai"):
                XCTAssertEqual(request.httpMethod, "GET")
                self.finish(
                    request,
                    client,
                    proto,
                    body: #"{"code":"OK","data":{"version":"v1","providers":["Actual Gateway","Search Provider"]}}"#
                )
            case let path where path.hasSuffix("/me"):
                XCTAssertEqual(request.httpMethod, "DELETE")
                let body = try self.body(request)
                XCTAssertEqual(body["provider"] as? String, "apple")
                XCTAssertEqual(body["authorization_code"] as? String, "one-time-code")
                XCTAssertEqual(body["client_id"] as? String, "app.id")
                self.finish(request, client, proto, body: #"{"code":"OK","data":{"deleted":true}}"#)
            default:
                XCTAssertTrue(request.url!.path.hasSuffix("/feedback"))
                let body = try self.body(request)
                XCTAssertEqual(body["type"] as? String, "ai-report")
                XCTAssertEqual(body["content"] as? String, "Reported answer only")
                XCTAssertNil(body["image_urls"])
                self.finish(request, client, proto, body: #"{"code":"OK","data":{"id":"report"}}"#)
            }
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let disclosure = try await api.aiDisclosure(token: "access")
        XCTAssertTrue(disclosure.isValid)
        XCTAssertEqual(disclosure.providers.count, 2)
        try await api.deleteAccount(
            proof: .init(provider: "apple", idToken: "proof", authorizationCode: "one-time-code", clientId: "app.id"),
            token: "access"
        )
        try await api.reportAnswer(content: "Reported answer only", token: "access")
    }

    func testDeletionDoesNotTreatFalseAsSuccess() async throws {
        let (api, session, host) = fixture { request, client, proto in
            self.finish(request, client, proto, body: #"{"code":"OK","data":{"deleted":false}}"#)
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        do {
            try await api.deleteAccount(proof: .init(provider: "password", password: "proof"), token: "access")
            XCTFail("Deletion must be explicitly confirmed by the server")
        } catch { XCTAssertEqual(error as? ChatAPIError, .invalidResponse) }
    }

    func testAppleCreditPackPurchaseAndResumeWireContracts() async throws {
        let (api, session, host) = fixture { request, client, proto in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            let path = request.url!.path
            if path.hasSuffix("/me/billing/apple/products") {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url!.query, "lang=zh-CN")
                self.finish(request, client, proto, body: #"{"code":"OK","data":{"enabled":true,"packs":[{"code":"pack_m","product_id":"app.typeflux.ios.credits.medium","name":"中额包","description":"多送 10%","credits":220000,"valid_days":365,"sort_order":1,"highlight":true},{"code":"pack_s","product_id":"app.typeflux.ios.credits.small","credits":100000}],"credits":{"remaining":3}}}"#)
            } else if path.hasSuffix("/me/billing/apple/transactions") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(try self.body(request)["signed_transaction"] as? String, "header.payload.signature")
                self.finish(request, client, proto, body: #"{"code":"OK","data":{"status":"granted","transaction_id":"2000","pack_code":"pack_m","credits":220000,"expires_at":"2027-10-09T00:00:00Z"}}"#)
            } else {
                XCTAssertTrue(request.url!.absoluteString.hasSuffix(
                    "/proxy/api/v1/ask/conversations/conversation-1/runs/run%201/resume"
                ))
                XCTAssertEqual(request.httpMethod, "POST")
                self.finish(request, client, proto, body: #"{"code":"CREDITS_EXHAUSTED","message":"credits exhausted","details":{"purchasable":true}}"#, status: 402)
            }
        }
        defer { session.invalidateAndCancel(); FixtureProtocol.registry.remove(host) }
        let packs = try await api.appleCreditPacks(language: "zh-CN", token: "access")
        XCTAssertTrue(packs.enabled)
        XCTAssertEqual(packs.packs.map(\.productId), ["app.typeflux.ios.credits.medium", "app.typeflux.ios.credits.small"])
        XCTAssertEqual(packs.packs[0].name, "中额包")
        XCTAssertTrue(packs.packs[0].highlight)
        XCTAssertEqual(packs.packs[1].name, "pack_s", "A pack without a name falls back to its code")
        XCTAssertEqual(packs.packs[1].validDays, 365)
        let receipt = try await api.submitAppleTransaction("header.payload.signature", token: "access")
        XCTAssertEqual(receipt, ChatApplePurchaseReceipt(status: "granted", transactionId: "2000", packCode: "pack_m",
                                                         credits: 220000))
        XCTAssertTrue(receipt.isFinal)
        XCTAssertTrue(ChatApplePurchaseReceipt(status: "revoked", transactionId: "1").isFinal)
        XCTAssertFalse(ChatApplePurchaseReceipt(status: "pending", transactionId: "1").isFinal)
        do {
            _ = try await api.resume(conversationId: "conversation-1", runId: "run 1", token: "access")
            XCTFail("A run that is still short of credits stays paused")
        } catch {
            XCTAssertEqual(error as? ChatAPIError, .server(code: "CREDITS_EXHAUSTED", message: "credits exhausted"))
        }
    }

    func testPausedForCreditsRunIsActiveButNotDesktop() throws {
        let run = ChatRun(id: "r", deviceId: "d", status: "paused_credits")
        XCTAssertTrue(run.isActive)
        XCTAssertTrue(run.isPausedForCredits)
        XCTAssertFalse(run.requiresDesktop)
        XCTAssertFalse(ChatRun(id: "r", deviceId: "d", status: "running").isPausedForCredits)
    }
}
