import Foundation
@testable import TypefluxChat
import XCTest

/// Records each request and answers with a fixed envelope, per host.
private final class TitleFixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static let lock = NSLock()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.lock.lock(); Self.requests.append(recorded); Self.lock.unlock()
        let body = """
        {"code":"OK","data":{"id":"c1","title":"Named","revision":4,"updated_at":"2026-10-18T00:00:00Z",
         "title_source":"manual","messages":[{"id":"a","role":"assistant","text":"Hi",
         "created_at":"2026-10-18T00:00:00Z","model_alias":"fast","model_name":"Fast"}],
         "run":{"id":"r","device_id":"d","status":"completed","updated_at":"2026-10-18T00:00:00Z",
                "model_ref":"cloud:default","model_alias":"fast","model_name":"Fast"}}}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ChatTitleTests: XCTestCase {
    private func client() -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TitleFixtureProtocol.self]
        return ChatAPIClient(baseURL: URL(string: "https://titles.example.com")!,
                             session: URLSession(configuration: configuration))
    }

    private func lastRequest() -> URLRequest? {
        TitleFixtureProtocol.lock.lock(); defer { TitleFixtureProtocol.lock.unlock() }
        return TitleFixtureProtocol.requests.last
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    func testRenameAndGenerateUseTheTitleRoute() async throws {
        let api = client()
        let renamed = try await api.updateTitle(conversationId: "c1", request: .rename("Named"), token: "t")
        XCTAssertEqual(renamed.title, "Named")
        XCTAssertEqual(renamed.titleSource, "manual")
        var request = lastRequest()
        XCTAssertEqual(request?.url?.path, "/api/v1/ask/conversations/c1/title")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(try body(request)["action"] as? String, "rename")
        XCTAssertEqual(try body(request)["title"] as? String, "Named")

        _ = try await api.updateTitle(conversationId: "c1", request: .generate(task: "task-1"), token: "t")
        request = lastRequest()
        XCTAssertEqual(try body(request)["action"] as? String, "generate")
        XCTAssertEqual(try body(request)["id"] as? String, "task-1")
        XCTAssertNil(try body(request)["title"])
        XCTAssertNotNil(UUID(uuidString: ChatTitleRequest.generate().id ?? ""))
    }

    func testKeepUsesTheKeepRouteAndServedModelDecodes() async throws {
        let value = try await client().keep(conversationId: "c1", token: "t")
        XCTAssertEqual(lastRequest()?.url?.path, "/api/v1/ask/conversations/c1/keep")
        XCTAssertEqual(value.run?.modelName, "Fast")
        XCTAssertEqual(value.run?.modelAlias, "fast")
        XCTAssertEqual(value.messages.first?.modelName, "Fast")
        XCTAssertEqual(value.messages.first?.modelAlias, "fast")
    }

    func testReadsFailFastWhileModelStepsMayTakeMinutes() async throws {
        XCTAssertEqual(ChatAPIClient.timeout(method: "GET", path: "/api/v1/ask/conversations"), 20)
        XCTAssertEqual(ChatAPIClient.timeout(method: "POST", path: "/api/v1/auth/refresh"), 30)
        XCTAssertEqual(ChatAPIClient.timeout(method: "POST", path: "/api/v1/ask/conversations/c/messages"), 200)
        _ = try await client().conversation(id: "c1", token: "t")
        XCTAssertEqual(lastRequest()?.timeoutInterval, 20)
        _ = try await client().updateTitle(conversationId: "c1", request: .rename("x"), token: "t")
        XCTAssertEqual(lastRequest()?.timeoutInterval, 200)
    }

    func testTemporaryIsSentOnlyWhenRequested() throws {
        let plain = try JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(
            ChatSendRequest(deviceId: "d", text: "Hi"))) as? [String: Any]
        XCTAssertNil(plain?["temporary"])
        let temporary = try JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(
            ChatSendRequest(deviceId: "d", text: "Hi", temporary: true))) as? [String: Any]
        XCTAssertEqual(temporary?["temporary"] as? Bool, true)
    }

    func testOlderServicesWithoutTitlesOrKeepRefuseClearly() async {
        struct Minimal: ChatAPI {
            func login(email _: String, password _: String) async throws -> ChatSession { throw ChatAPIError.unavailable }
            func refresh(refreshToken _: String) async throws -> ChatSession { throw ChatAPIError.unavailable }
            func logout(refreshToken _: String) async throws {}
            func models(token _: String) async throws -> [ChatModel] { [] }
            func list(token _: String, offset _: Int) async throws -> [ChatConversationSummary] { [] }
            func conversation(id: String, token _: String) async throws -> ChatConversation { .init(id: id, title: "") }
            func send(conversationId: String, request _: ChatSendRequest, token _: String) async throws
                -> ChatConversation { .init(id: conversationId, title: "") }
            func cancel(conversationId: String, runId _: String, token _: String) async throws
                -> ChatConversation { .init(id: conversationId, title: "") }
            func observe(id _: String, token _: String,
                         onValue _: @Sendable (ChatConversation) async throws -> Void) async throws {}
        }
        do {
            _ = try await Minimal().updateTitle(conversationId: "c", request: .rename("x"), token: "t")
            XCTFail("Expected unavailable")
        } catch { XCTAssertEqual(error as? ChatAPIError, .unavailable) }
        do {
            _ = try await Minimal().keep(conversationId: "c", token: "t")
            XCTFail("Expected unavailable")
        } catch { XCTAssertEqual(error as? ChatAPIError, .unavailable) }
    }

    // MARK: Titles

    private func pair(_ question: String, _ answer: String, error: Bool = false) -> [ChatMessage] {
        [ChatMessage(id: UUID().uuidString, role: "user", text: question),
         ChatMessage(id: UUID().uuidString, role: "assistant", text: answer, isError: error ? true : nil)]
    }

    func testTranscriptNeedsTwoCompletedPairs() {
        var value = ChatConversation(id: "c", title: "t", messages: pair("Q1", "A1"))
        XCTAssertNil(ChatConversationTitle.transcript(value))
        XCTAssertFalse(ChatConversationTitle.needsTitle(value))
        value.messages += pair("Q2", "broken", error: true)
        XCTAssertNil(ChatConversationTitle.transcript(value), "failed answers do not count")
        value.messages += pair("Q3", "A3")
        let transcript = ChatConversationTitle.transcript(value)
        XCTAssertEqual(transcript, "User: Q1\nAssistant: A1\n\nUser: Q3\nAssistant: A3")
        XCTAssertTrue(ChatConversationTitle.needsTitle(value))
        value.titleSource = "manual"
        XCTAssertFalse(ChatConversationTitle.needsTitle(value))
        value.titleSource = nil
        value.run = ChatRun(id: "r", deviceId: "d", status: "running")
        XCTAssertFalse(ChatConversationTitle.needsTitle(value))
    }

    func testTranscriptBoundsEachTurnAndSkipsToolSteps() {
        let long = String(repeating: "x", count: 2000)
        let tool = ChatMessage(id: "t", role: "assistant", text: "calling",
                               toolCalls: [ChatToolCall(id: "c", function: .init(name: "f", arguments: "{}"))])
        let value = ChatConversation(id: "c", title: "t", messages: [
            ChatMessage(id: "q", role: "user", text: long), tool,
            ChatMessage(id: "a", role: "assistant", text: "A"),
            ChatMessage(id: "a2", role: "assistant", text: "second answer to the same question"),
        ] + pair("Q2", "A2"))
        let transcript = ChatConversationTitle.transcript(value) ?? ""
        XCTAssertFalse(transcript.contains("calling"))
        XCTAssertFalse(transcript.contains("second answer"))
        XCTAssertTrue(transcript.hasPrefix("User: " + String(repeating: "x", count: 1500) + "\nAssistant: A"))
    }

    func testCleanAcceptsOneShortLine() {
        XCTAssertEqual(ChatConversationTitle.clean("  \u{201C}Trip planning\u{201D} "), "Trip planning")
        XCTAssertEqual(ChatConversationTitle.clean("「旅行计划」"), "旅行计划")
        XCTAssertNil(ChatConversationTitle.clean("   "))
        XCTAssertNil(ChatConversationTitle.clean("one\ntwo"))
        XCTAssertNil(ChatConversationTitle.clean(String(repeating: "a", count: 61)))
        XCTAssertEqual(ChatConversationTitle.clean(String(repeating: "a", count: 60))?.count, 60)
    }

    func testTitleSourceRoundTripsForPrivateConversations() throws {
        let value = ChatConversation(id: "c", title: "Named", titleSource: "auto")
        let decoded = try ChatCoding.decoder().decode(ChatConversation.self, from: ChatCoding.encoder().encode(value))
        XCTAssertEqual(decoded.titleSource, "auto")
    }
}
