@testable import Typeflux
import XCTest

extension AskBuiltinToolHostTests {
    func testDefaultDefinitionsAndPlanParity() async throws {
        var web = AskLocalWebTools(searchProvider: { .init() })
        defer { web.session.invalidateAndCancel() }
        XCTAssertEqual(DefaultAskBuiltinToolHost(webTools: web).definitions(), [AskLocalEngine.planTool])
        web.searchProvider = { .init(provider: .tavily, apiKey: "fixture") }
        let host = DefaultAskBuiltinToolHost(webTools: web)
        XCTAssertEqual(host.definitions(), [AskLocalEngine.planTool] + web.definitions())
        XCTAssertEqual(host.definitions().map(\.name), ["update_plan", "web_search"])
        let conversation = AskConversation(id: "snapshot", title: "", revision: 0, updatedAt: Date(), messages: [])
        let valid = #"""
        {"items":[{"step":" Read ","status":"pending"},{"step":"Write","status":"in_progress"},{"step":"Done","status":"completed"}]}
        """#
        let output = await host.execute(.init(
            call: call(arguments: valid),
            conversation: conversation,
            budgeted: false
        ))
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.text, "Plan updated.")
        XCTAssertEqual(output.plan, try AskLocalEngine.parsePlan(valid))
        XCTAssertEqual(output.plan?.first?.step, "Read")
        for arguments in ["not json", "{}", #"{"items":[]}"#,
                          #"{"items":[{"step":" ","status":"pending"}]}"#,
                          #"{"items":[{"step":"x","status":"unknown"}]}"#,
                          #"{"items":[{"step":"x","status":"in_progress"},{"step":"y","status":"in_progress"}]}"#,
                          "{\"items\":[{\"step\":\"\(String(repeating: "x", count: 301))\",\"status\":\"pending\"}]}"] {
            let failed = await host.execute(.init(
                call: call(arguments: arguments),
                conversation: conversation,
                budgeted: true
            ))
            XCTAssertTrue(failed.isError, arguments)
            XCTAssertNil(failed.plan)
            do { _ = try AskLocalEngine.parsePlan(arguments); XCTFail("Expected invalid plan") } catch { XCTAssertEqual(
                failed.text,
                error.localizedDescription
            ) }
        }
    }

    func testDefaultHistoryUnavailableAndWebFailureParity() async throws {
        let web = AskLocalWebTools(searchProvider: { .init() })
        defer { web.session.invalidateAndCancel() }
        let host = DefaultAskBuiltinToolHost(webTools: web)
        let conversation = AskConversation(id: "snapshot", title: "", revision: 0, updatedAt: Date(),
                                           messages: [.init(
                                               id: "message",
                                               role: "user",
                                               text: "Original evidence",
                                               createdAt: Date()
                                           )])
        for arguments in [#"{"index":0}"#, #"{"index":0,"offset":2,"limit":3}"#] {
            let output = await host.execute(.init(
                call: call("read_conversation_history", arguments: arguments),
                conversation: conversation,
                budgeted: true
            ))
            XCTAssertFalse(output.isError)
            XCTAssertNil(output.plan)
            XCTAssertEqual(output.text, try AskSemanticCompaction.readHistory(conversation, arguments: arguments))
        }
        for arguments in ["{}", #"{"index":-1}"#, #"{"index":0,"offset":-1}"#, #"{"index":0,"limit":0}"#] {
            let output = await host.execute(.init(
                call: call("read_conversation_history", arguments: arguments),
                conversation: conversation,
                budgeted: false
            ))
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.text, "Invalid original message index, offset or limit.")
        }
        for name in ["unknown", "web_search", "web_fetch"] {
            let arguments = #"{"query":"fixture","url":"https://example.com"}"#
            let output = await host.execute(.init(
                call: call(name, arguments: arguments),
                conversation: conversation,
                budgeted: false
            ))
            let expected = await web.execute(name: name, arguments: arguments)
            XCTAssertEqual(output.text, expected.0)
            XCTAssertEqual(output.isError, expected.1)
            XCTAssertNil(output.plan)
        }
    }
}

extension AskBuiltinToolHostTests {
    func testBudgetedSessionCopiesMockTransportAndCleansUpOnSuccessAndFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BuiltinHostURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Host-Fixture": "copied"]
        let sourcePolicy = BuiltinHostSessionDelegate()
        let session = URLSession(configuration: config, delegate: sourcePolicy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let conversation = AskConversation(id: "snapshot", title: "", revision: 0, updatedAt: Date(), messages: [])
        for path in ["success", "failure"] {
            let web = AskLocalWebTools(
                session: session,
                searchProvider: { .init(provider: .tavily, apiKey: "fixture") },
                searchEndpoints: [.tavily: "https://builtin-host.invalid/\(path)"]
            )
            let host = DefaultAskBuiltinToolHost(webTools: web)
            let input = AskBuiltinToolInput(
                call: call("web_search", arguments: #"{"query":"fixture"}"#),
                conversation: conversation,
                budgeted: true
            )
            let output = await host.execute(input)
            XCTAssertEqual(output.isError, path == "failure")
            XCTAssertTrue(output.text
                .contains(path == "failure" ? "Search is temporarily unavailable." : "Fixture evidence"))
            // The copied session's deferred invalidation must leave the caller's
            // ordinary transport alive, including when a search fails.
            let ordinary = await host.execute(.init(call: input.call, conversation: conversation, budgeted: false))
            XCTAssertEqual(ordinary.text, output.text)
            XCTAssertEqual(ordinary.isError, output.isError)
            XCTAssertFalse(sourcePolicy.invalidated)
        }
        // The clone uses this same existing policy. Mock redirects exercise the
        // delegate without allowing URLProtocol to issue a real follow-up.
        let policy = AskModelRedirectPolicy()
        let task = try session.dataTask(with: XCTUnwrap(URL(string: "https://builtin-host.invalid/success")))
        defer { task.cancel() }
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(task.originalRequest?.url),
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        try policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: XCTUnwrap(URL(string: "https://another.invalid/")))) {
            XCTAssertNil($0)
        }
    }
}

private final class BuiltinHostSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didInvalidate = false
    var invalidated: Bool {
        lock.withLock { didInvalidate }
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError _: Error?) {
        lock.withLock { didInvalidate = true }
    }
}

private final class BuiltinHostURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.host == "builtin-host.invalid",
              request.value(forHTTPHeaderField: "X-Host-Fixture") == "copied" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.path == "/failure" ? 500 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"results":[{"title":"Fixture","url":"https://example.com","content":"Fixture evidence"}]}"#
                .utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
