import Foundation
@testable import Typeflux
import XCTest

/// Answers web and model requests for local-mode tests by host.
private final class LocalStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, String))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, type, body) = Self.handler?(request) ?? (404, "text/plain", "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class AskLocalWebToolsTests: XCTestCase {
    override func tearDown() { LocalStubProtocol.handler = nil }

    func testAddressPolicy() throws {
        for blocked in ["127.0.0.1", "10.0.0.1", "172.20.1.1", "192.168.0.10", "169.254.169.254", "100.64.1.1", "0.0.0.0", "224.0.0.1",
                        "198.18.0.1", "192.0.2.5", "203.0.113.9", "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:10.0.0.1",
                        "64:ff9b::a00:1", "2001:db8::1", "not-an-ip"] {
            XCTAssertFalse(AskLocalWebTools.isPublic(blocked), blocked)
        }
        for allowed in ["8.8.8.8", "93.184.216.34", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            XCTAssertTrue(AskLocalWebTools.isPublic(allowed), allowed)
        }
        let tools = AskLocalWebTools(resolve: { $0 == "example.com" ? ["93.184.216.34"] : ["10.0.0.1"] })
        XCTAssertNoThrow(try tools.checkPublic(URL(string: "https://example.com/a")!))
        for bad in ["https://intranet.corp/a", "ftp://example.com", "https://user:pw@example.com", "http://localhost:8080", "http://printer.local"] {
            XCTAssertThrowsError(try tools.checkPublic(URL(string: bad)!), bad)
        }
        XCTAssertFalse(AskLocalWebTools.addresses(of: "localhost").isEmpty)
        XCTAssertTrue(AskLocalWebTools.addresses(of: "definitely-not-a-host.invalid").isEmpty)
    }

    func testHTMLExtractionAndEntities() {
        let (title, text) = AskLocalWebTools.htmlText("""
        <html><head><title> Notes &amp; News </title><style>.x{}</style></head><body><nav>Menu</nav>
        <script>alert(1)</script><h1>Version&nbsp;2</h1><p>Fast &lt;and&gt; safe &#26032;&#x529f;&#x80fd;</p>
        <ul><li>One</li><li>Two</li></ul><!-- hidden --><footer>©</footer></body></html>
        """)
        XCTAssertEqual(title, "Notes & News")
        XCTAssertEqual(text, "# Version 2\nFast <and> safe 新功能\n- One\n- Two")
        XCTAssertEqual(AskLocalWebTools.decodeEntities("&#xZZ; &quot;a&quot; &apos;b&#39;"), "&#xZZ; \"a\" 'b'")
    }

    func testSearchAndDefinitions() async throws {
        LocalStubProtocol.handler = { request in
            switch (request.url?.host, request.url?.path) {
            case ("api.tavily.com", _):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tv")
                return (200, "application/json", #"{"results":[{"title":"Go","url":"https://go.dev","content":"Release\nnotes"}]}"#)
            case ("api.search.brave.com", _):
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "br")
                return (200, "application/json", #"{"web":{"results":[]}}"#)
            default: return (404, "text/plain", "")
            }
        }
        var tools = AskLocalWebTools(session: LocalStubProtocol.session, resolve: { _ in ["93.184.216.34"] })
        XCTAssertTrue(tools.definitions().isEmpty)
        let (_, unknownFailed) = await tools.execute(name: "web_other", arguments: "{}")
        XCTAssertTrue(unknownFailed)
        let (_, noSearch) = await tools.execute(name: "web_search", arguments: #"{"query":"go"}"#)
        XCTAssertTrue(noSearch)

        tools.searchProvider = { .init(provider: .tavily, apiKey: "tv") }
        XCTAssertEqual(tools.definitions().map(\.name), ["web_search"])
        let found = try await tools.search("go release", count: 50)
        XCTAssertEqual(found, "1. Go\n   https://go.dev\n   Release notes")
        tools.searchProvider = { .init(provider: .brave, apiKey: "br") }
        let none = try await tools.search("nothing", count: 3)
        XCTAssertEqual(none, "No results.")
        do {
            _ = try await tools.search("   ", count: 1)
            XCTFail("Empty query")
        } catch {}
        tools.searchEndpoints[.brave] = "https://down.example/search"
        do {
            _ = try await tools.search("q", count: 1)
            XCTFail("Provider error")
        } catch {}
    }

    func testSearchSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "ask-search-\(UUID().uuidString)")!
        let settings = AskSearchSettings(defaults: defaults, keychainService: "com.typeflux.tests.search.\(UUID().uuidString)")
        XCTAssertEqual(settings.provider, .none)
        XCTAssertFalse(settings.isConfigured)
        settings.provider = .brave
        XCTAssertEqual(settings.provider, .brave)
        settings.setAPIKey("  secret ")
        // Some CI keychains are locked; only assert when the item was written.
        if !settings.apiKey.isEmpty {
            XCTAssertEqual(settings.apiKey, "secret")
            XCTAssertTrue(settings.isConfigured)
        }
        settings.setAPIKey("")
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertFalse(settings.isConfigured)
    }

    func testSearchResultsRemainUsableWithoutFetch() async throws {
        LocalStubProtocol.handler = { request in
            switch request.url?.host {
            case "api.tavily.com":
                return (200, "application/json", #"{"results":[{}, {"title":"Notes","url":"https://example.com/notes","content":"Read the snippet"}]}"#)
            case "api.search.brave.com":
                return (200, "application/json", #"{"web":{"results":[{}, {"title":"Docs","url":"https://example.com/docs","description":"Search\nsummary"}]}}"#)
            default: return (200, "application/json", "{}")
            }
        }
        var tools = AskLocalWebTools(session: LocalStubProtocol.session)
        defer { tools.session.invalidateAndCancel() }
        for provider in [AskSearchSettings.Provider.tavily, .brave] {
            tools.searchProvider = { .init(provider: provider, apiKey: "fixture-key") }
            let result = try await tools.search("query", count: 2)
            let expected = provider == .tavily
                ? "1. \n   \n2. Notes\n   https://example.com/notes\n   Read the snippet"
                : "1. \n   \n2. Docs\n   https://example.com/docs\n   Search summary"
            XCTAssertEqual(result, expected)
            let limited = try await tools.search("query", count: 0)
            XCTAssertEqual(limited, "1. \n   ")
            tools.searchEndpoints[provider] = "https://empty.invalid/search"
            let empty = try await tools.search("query", count: 2)
            XCTAssertEqual(empty, "No results.")
        }
    }
}

/// Records which backend each call reached.
private actor RecordingAPI: AskAPI {
    let name: String
    var calls: [String] = []
    init(name: String) { self.name = name }
    private func note(_ call: String) { calls.append(call) }
    private func value() -> AskConversation { AskConversation(id: name, title: name, revision: 1, updatedAt: Date(), messages: []) }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { note("list"); return [] }
    func conversation(id: String, token: String) async throws -> AskConversation { note("conversation"); return value() }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation { note("send"); return value() }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation { note("result"); return value() }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation { note("cancel"); return value() }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation { note("retry"); return value() }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation { note("regenerate"); return value() }
    func delete(conversationId: String, token: String) async throws { note("delete") }
    func purgeMemory(token: String) async throws { note("purge") }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation { note("inference"); return value() }
    func models(token: String) async throws -> [AskCloudModel] { note("models"); return [] }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage { note("usage"); return AskUsagePage(items: [], nextCursor: nil) }
}

final class AskRoutedAPITests: XCTestCase {
    func testCallsRouteByTokenAndPurgeClearsLocalCopies() async throws {
        let cloud = RecordingAPI(name: "cloud"), local = RecordingAPI(name: "local")
        let api = AskRoutedAPI(cloud: cloud, local: local)
        let send = AskSendRequest(id: "m", deviceId: "d", text: "q", tools: [])
        for token in ["", "token"] {
            _ = try await api.list(token: token, offset: 0)
            _ = try await api.conversation(id: "c", token: token)
            _ = try await api.send(conversationId: "c", request: send, token: token)
            _ = try await api.result(conversationId: "c", request: .init(runId: "r", deviceId: "d", toolCallId: "t", content: "", isError: false), token: token)
            _ = try await api.cancel(conversationId: "c", runId: "r", token: token)
            _ = try await api.cancel(conversationId: "c", runId: "r", partial: nil, token: token)
            _ = try await api.retry(conversationId: "c", runId: "r", deviceId: "d", modelRef: nil, token: token)
            _ = try await api.regenerate(conversationId: "c", request: .init(messageId: "m", deviceId: "d"), token: token)
            _ = try await api.inferenceResult(conversationId: "c", request: .init(runId: "r", deviceId: "d", inferenceId: "i", content: ""), token: token)
            _ = try await api.models(token: token)
            _ = try await api.models(token: token, scenario: "ask")
            _ = try await api.usage(id: "c", runId: nil, cursor: nil, token: token)
            try await api.delete(conversationId: "c", token: token)
            try? await api.observe(id: "c", token: token) { _ in throw CancellationError() }
        }
        let localCalls = await local.calls, cloudCalls = await cloud.calls
        XCTAssertEqual(localCalls, cloudCalls)
        XCTAssertEqual(localCalls.count, 14)
        try await api.purgeMemory(token: "")
        try await api.purgeMemory(token: "token")
        let localPurges = await local.calls.filter { $0 == "purge" }.count
        let cloudPurges = await cloud.calls.filter { $0 == "purge" }.count
        XCTAssertEqual(localPurges, 2)
        XCTAssertEqual(cloudPurges, 1)
    }

    func testSessionIsTheCloudAccountOnlyWhenSignedIn() {
        XCTAssertTrue(AskRoutedAPI.session(token: "t", owner: "u") == ("u", "t"))
        XCTAssertTrue(AskRoutedAPI.session(token: nil, owner: "u") == ("local", ""))
        XCTAssertTrue(AskRoutedAPI.session(token: "", owner: "u") == ("local", ""))
        XCTAssertTrue(AskRoutedAPI.session(token: "t", owner: "") == ("local", ""))
        XCTAssertTrue(AskRoutedAPI.session(token: "t", owner: nil) == ("local", ""))
    }

    func testPromptPiecesMatchTheServer() throws {
        let memory = try XCTUnwrap(AskLocalPrompt.memory(AskMemory(global: "a < b", app: .init(id: "com.app", name: "\"App\"", excerpts: ["x & y"]))))
        XCTAssertTrue(memory.contains("<global>\na &lt; b\n</global>"))
        XCTAssertTrue(memory.contains("<app name=\"\\\"App\\\"\">"))
        XCTAssertTrue(memory.contains("<excerpt>\nx &amp; y\n</excerpt>"))
        XCTAssertNil(AskLocalPrompt.memory(AskMemory()))
        let env = AskLocalPrompt.environment(localDate: "2026-10-02 (Friday)", timeZone: nil, locale: nil, webTools: [], plan: false)
        XCTAssertTrue(env.contains("2026-10-02 (Friday) (UTC)."))
        XCTAssertFalse(env.contains("Web tools"))
        let messages = AskLocalPrompt.messages([
            AskMessage(id: "1", role: "user", text: "Q", selection: "sel", source: "Safari", image: "data:image/jpeg;base64,YQ==", createdAt: Date(),
                       references: [AskReference(messageId: "m", text: "quoted", question: "why")]),
            AskMessage(id: "2", role: "assistant", text: "", toolCalls: [AskToolCall(id: "t", function: .init(name: "computer", arguments: "{}"), thoughtSignature: "sig")], createdAt: Date()),
            AskMessage(id: "3", role: "tool", text: "shot", image: "data:image/jpeg;base64,Yg==", toolCallId: "t", createdAt: Date()),
            AskMessage(id: "4", role: "tool", text: "denied", toolCallId: "u", isError: true, createdAt: Date())
        ])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
        let user = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let text = try XCTUnwrap(user.first?["text"] as? String)
        XCTAssertTrue(text.contains("<screen_context source=\"Safari\">\nsel\n</screen_context>") && text.contains("quoted"))
        XCTAssertEqual(((messages[1]["tool_calls"] as? [[String: Any]])?.first?["thought_signature"]) as? String, "sig")
        XCTAssertEqual(messages[3]["content"] as? String, "Tool failed or was denied: denied")
        XCTAssertEqual(messages[2]["content"] as? String, "shot")
        XCTAssertNotNil(messages[4]["content"] as? [[String: Any]])
        XCTAssertEqual(AskLocalPrompt.json(["a": 1]), #"{"a":1}"#)
    }
}

/// The whole local flow through the real conversation model: no sign-in, the user's
/// own model answers through the device inference path, and history stays on disk.
@MainActor
final class AskLocalModeIntegrationTests: XCTestCase {
    func testSignedOutAskRunsWithTheUsersModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-local-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ask-local-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AskModelProfile(name: "My model", baseURL: "https://models.example/v1", model: "my-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let firstLocal = try XCTUnwrap(library.firstLocalReference(hasImage: false))
        XCTAssertFalse(firstLocal.hasPrefix("cloud:"))

        let engine = AskLocalEngine(directory: root.appendingPathComponent("conversations"), webTools: AskLocalWebTools(resolve: { _ in [] }))
        let model = AskConversationModel(api: AskRoutedAPI(cloud: AskAPIClient(), local: engine),
                                         cache: try AskConversationCache(url: root.appendingPathComponent("cache.sqlite")),
                                         tools: AskTestTools(), capture: AskTestCapture(), deviceId: "device", modelLibrary: library,
                                         session: { AskRoutedAPI.session(token: nil, owner: nil) })
        XCTAssertFalse(model.cloudAvailable)
        // The Cloud default falls back to one of the user's own models.
        XCTAssertEqual(model.modelReference(launcher: true), firstLocal)
        XCTAssertEqual(model.localFallback("custom:x", hasImage: false, local: true), "custom:x")

        var requests: [[String: Any]] = []
        LocalStubProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            }
            requests.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Local answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            return (200, "text/event-stream", sse)
        }
        defer { LocalStubProtocol.handler = nil }
        model.customInference = AskCustomInference(session: LocalStubProtocol.session)

        model.launcherDraft.text = "What can you do?"
        model.launcherDraft.modelRef = profile.reference
        model.launcherDraft.includeScreenshot = false
        model.submitLauncher()
        for _ in 0 ..< 1500 where !(model.busyIds.isEmpty && model.selected?.run?.status == "completed") {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selected?.run?.status, "completed")
        XCTAssertEqual(model.selected?.messages.last?.text, "Local answer")
        XCTAssertEqual(requests.first?["model"] as? String, "my-model")
        let listed = try await engine.list(token: "", offset: 0)
        XCTAssertEqual(listed.count, 1)

        // A Cloud session never falls back.
        let signedIn = AskConversationModel(api: AskRoutedAPI(cloud: AskAPIClient(), local: engine),
                                            cache: try AskConversationCache(url: root.appendingPathComponent("cache2.sqlite")),
                                            tools: AskTestTools(), capture: AskTestCapture(), deviceId: "device", modelLibrary: library,
                                            session: { ("owner", "token") })
        XCTAssertTrue(signedIn.cloudAvailable)
        XCTAssertEqual(signedIn.localFallback("cloud:default", hasImage: false, local: false), "cloud:default")
    }
}
