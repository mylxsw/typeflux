import Foundation
@testable import TypefluxChat
import XCTest

/// URLProtocol fixtures keyed by host, so concurrent tests never share responses.
private final class ProviderFixtures: @unchecked Sendable {
    struct Response {
        var status = 200
        var body: String
        var contentType = "application/json"
    }

    typealias Handler = (URLRequest) -> Response
    let lock = NSLock()
    var handlers: [String: Handler] = [:]
    var requests: [String: [URLRequest]] = [:]

    func set(_ host: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }

    func handle(_ request: URLRequest) -> Response? {
        lock.lock(); defer { lock.unlock() }
        guard let host = request.url?.host, let handler = handlers[host] else { return nil }
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
        requests[host, default: []].append(recorded)
        return handler(recorded)
    }

    func recorded(_ host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests[host] ?? []
    }
}

private final class ProviderFixtureProtocol: URLProtocol {
    static let fixtures = ProviderFixtures()
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        guard let response = Self.fixtures.handle(request) else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
                                                             httpVersion: nil,
                                                             headerFields: ["Content-Type": response.contentType])!,
                           cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(response.body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ChatProviderTests: XCTestCase {
    private func client(_ handler: @escaping ProviderFixtures.Handler) -> (ChatProviderClient, String) {
        let host = UUID().uuidString.lowercased() + ".example.com"
        ProviderFixtureProtocol.fixtures.set(host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        return (ChatProviderClient(session: URLSession(configuration: configuration)), host)
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func collect(_ stream: AsyncThrowingStream<ChatProviderEvent, Error>) async throws -> [ChatProviderEvent] {
        var events: [ChatProviderEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: Configuration

    func testEndpointPolicyAllowsHTTPSAndPrivateHTTPOnly() {
        XCTAssertNotNil(ChatEndpointPolicy.validate("https://api.example.com/v1"))
        XCTAssertNotNil(ChatEndpointPolicy.validate(" http://192.168.1.20:11434 "))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://10.0.0.2"))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://172.20.1.1"))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://localhost:1234"))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://studio.local:1234"))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://[::1]:11434"))
        XCTAssertNotNil(ChatEndpointPolicy.validate("http://[fd00::1]"))
        XCTAssertNil(ChatEndpointPolicy.validate("http://api.example.com"))
        XCTAssertNil(ChatEndpointPolicy.validate("http://8.8.8.8"))
        XCTAssertNil(ChatEndpointPolicy.validate("ftp://192.168.1.2"))
        XCTAssertNil(ChatEndpointPolicy.validate("https://user:pass@api.example.com"))
        XCTAssertNil(ChatEndpointPolicy.validate("https://api.example.com?key=1"))
        XCTAssertNil(ChatEndpointPolicy.validate("https://api example.com"))
        XCTAssertNil(ChatEndpointPolicy.validate(""))
    }

    func testReferencesRoundTripIncludingSlashesInModelIDs() {
        let provider = ChatProvider(id: "p1", kind: .openRouter, models: [
            ChatProviderModel(id: "openai/gpt-5", vision: true),
            ChatProviderModel(id: "hidden", enabled: false),
        ])
        let reference = provider.reference(for: "openai/gpt-5")
        XCTAssertEqual(reference, "local:p1/openai/gpt-5")
        XCTAssertEqual(ChatProvider.parse(reference: reference)?.provider, "p1")
        XCTAssertEqual(ChatProvider.parse(reference: reference)?.model, "openai/gpt-5")
        XCTAssertNil(ChatProvider.parse(reference: "cloud:fast"))
        XCTAssertNil(ChatProvider.parse(reference: "local:p1"))
        XCTAssertNil(ChatProvider.parse(reference: "local:/model"))
        let models = provider.chatModels
        XCTAssertEqual(models.map(\.reference), [reference])
        XCTAssertEqual(models.first?.isLocal, true)
        XCTAssertEqual(models.first?.providerName, "OpenRouter")
        XCTAssertEqual(models.first?.vision, true)
        XCTAssertFalse(ChatModel(id: "fast", name: "Fast").isLocal)
        XCTAssertEqual(ChatModel(id: "fast", name: "Fast").reference, "cloud:fast")
    }

    func testKindsDescribeTheirProtocolAndAddress() {
        for kind in ChatProviderKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertEqual(kind.id, kind.rawValue)
            if kind.hasEditableAddress {
                XCTAssertEqual(kind.defaultBaseURL, "")
            } else {
                XCTAssertNotNil(ChatEndpointPolicy.validate(kind.defaultBaseURL), kind.rawValue)
            }
        }
        XCTAssertEqual(ChatProviderKind.anthropic.api, .anthropic)
        XCTAssertEqual(ChatProviderKind.gemini.api, .gemini)
        XCTAssertEqual(ChatProviderKind.ollama.api, .ollama)
        XCTAssertEqual(ChatProviderKind.deepSeek.api, .openAICompatible)
        XCTAssertFalse(ChatProviderKind.ollama.requiresKey)
        XCTAssertTrue(ChatProviderKind.openAI.requiresKey)
        XCTAssertNil(ChatProvider(kind: .ollama).endpoint)
    }

    // MARK: Requests

    func testOpenAICompatibleRequestCarriesSystemImageAndKey() throws {
        let provider = ChatProvider(kind: .deepSeek)
        let request = try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: provider, apiKey: " sk-test ", model: "deepseek-chat", system: "Be brief",
            messages: [ChatProviderMessage(role: "user", text: "What is this?", image: "data:image/png;base64,AAA"),
                       ChatProviderMessage(role: "assistant", text: "A cat.")]
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try json(request)
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        XCTAssertEqual(messages[2]["content"] as? String, "A cat.")
    }

    func testAnthropicRequestUsesNativeMessages() throws {
        let request = try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: ChatProvider(kind: .anthropic), apiKey: "key", model: "claude", system: "System",
            messages: [ChatProviderMessage(role: "user", text: "Look", image: "data:image/jpeg;base64,BBB")],
            maxOutputTokens: 512
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ChatProviderWire.anthropicVersion)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        XCTAssertEqual(body["system"] as? String, "System")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content.first?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "BBB")
    }

    func testGeminiRequestUsesModelRolesAndInlineData() throws {
        let request = try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: ChatProvider(kind: .gemini), apiKey: "g", model: "gemini-pro", system: "S",
            messages: [ChatProviderMessage(role: "user", text: "Hi", image: "data:image/png;base64,CCC"),
                       ChatProviderMessage(role: "assistant", text: "Hello")]
        ))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g")
        let body = try json(request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model"])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertNotNil(parts.first?["inline_data"])
        XCTAssertNotNil(body["systemInstruction"])
    }

    func testOllamaUsesItsCompatibleEndpointWithoutAKey() throws {
        let provider = ChatProvider(kind: .ollama, baseURL: "http://192.168.1.20:11434")
        let request = try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: provider, apiKey: nil, model: "qwen3", messages: [ChatProviderMessage(role: "user", text: "Hi")]
        ))
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let models = try ChatProviderWire.modelsRequest(provider: provider, apiKey: nil, cursor: nil)
        XCTAssertEqual(models.url?.absoluteString, "http://192.168.1.20:11434/api/tags")
    }

    func testRequestsRefuseMissingKeysAndDisallowedAddresses() {
        XCTAssertThrowsError(try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: ChatProvider(kind: .openAI), apiKey: "  ", model: "m", messages: []
        ))) { XCTAssertEqual($0 as? ChatProviderError, .missingKey) }
        XCTAssertThrowsError(try ChatProviderWire.chatRequest(ChatProviderRequest(
            provider: ChatProvider(kind: .custom, baseURL: "http://public.example.com"), apiKey: nil, model: "m",
            messages: []
        ))) { XCTAssertEqual($0 as? ChatProviderError, .invalidEndpoint) }
    }

    func testImagePartsRejectNonBase64URLs() {
        XCTAssertEqual(ChatProviderWire.imageParts("data:image/png;base64,QQ==")?.mediaType, "image/png")
        XCTAssertNil(ChatProviderWire.imageParts("data:image/png,raw"))
        XCTAssertNil(ChatProviderWire.imageParts("https://example.com/a.png"))
    }

    // MARK: Responses

    func testStreamLinesForEachProtocol() throws {
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(
            #"data: {"choices":[{"delta":{"reasoning_content":"Hmm","content":"Hi"}}]}"#, api: .openAICompatible),
                       [.reasoning("Hmm"), .text("Hi")])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(
            #"data: {"choices":[{"delta":{"reasoning":"R"}}]}"#, api: .ollama), [.reasoning("R")])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine("data: [DONE]", api: .openAICompatible), [])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(": keep-alive", api: .openAICompatible), [])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine("data: not json", api: .openAICompatible), [])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(#"data: {"choices":[]}"#, api: .openAICompatible), [])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"A"}}"#, api: .anthropic),
                       [.text("A")])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"T"}}"#,
            api: .anthropic), [.reasoning("T")])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(#"data: {"type":"message_stop"}"#, api: .anthropic), [])
        XCTAssertEqual(try ChatProviderWire.parseStreamLine(
            #"data: {"candidates":[{"content":{"parts":[{"text":"think","thought":true},{"text":"G"}]}}]}"#,
            api: .gemini), [.reasoning("think"), .text("G")])
        XCTAssertThrowsError(try ChatProviderWire.parseStreamLine(#"data: {"error":{"message":"x"}}"#,
                                                                  api: .openAICompatible))
        XCTAssertThrowsError(try ChatProviderWire.parseStreamLine(#"data: {"type":"error"}"#, api: .anthropic))
    }

    func testModelCatalogsForEachProtocol() throws {
        let openAI = try ChatProviderWire.parseModels(Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8),
                                                      provider: ChatProvider(kind: .openAI))
        XCTAssertEqual(openAI.models.map(\.id), ["a", "b"])
        XCTAssertEqual(openAI.models.map(\.vision), [false, false])
        XCTAssertNil(openAI.cursor)
        let ollama = try ChatProviderWire.parseModels(Data(#"{"models":[{"name":"qwen3:14b"}]}"#.utf8),
                                                      provider: ChatProvider(kind: .ollama))
        XCTAssertEqual(ollama.models.map(\.id), ["qwen3:14b"])
        let anthropic = try ChatProviderWire.parseModels(
            Data(#"{"data":[{"id":"claude","display_name":"Claude"}],"has_more":true,"last_id":"claude"}"#.utf8),
            provider: ChatProvider(kind: .anthropic))
        XCTAssertEqual(anthropic.models.first?.name, "Claude")
        XCTAssertEqual(anthropic.models.first?.vision, true)
        XCTAssertEqual(anthropic.cursor, "claude")
        let gemini = try ChatProviderWire.parseModels(Data(#"""
        {"models":[{"name":"models/gemini-pro","displayName":"Gemini Pro","supportedGenerationMethods":["generateContent"]},
                   {"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"p2"}
        """#.utf8), provider: ChatProvider(kind: .gemini))
        XCTAssertEqual(gemini.models.map(\.id), ["gemini-pro"])
        XCTAssertEqual(gemini.cursor, "p2")
        XCTAssertThrowsError(try ChatProviderWire.parseModels(Data("[]".utf8), provider: ChatProvider(kind: .openAI)))
    }

    func testStatusCodesMapToProviderErrors() {
        let url = URL(string: "https://example.com")!
        func status(_ code: Int) -> ChatProviderError? {
            do {
                try ChatProviderWire.check(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                                           headerFields: nil)!, data: Data())
                return nil
            } catch { return error as? ChatProviderError }
        }
        XCTAssertNil(status(200))
        XCTAssertEqual(status(302), .redirected)
        XCTAssertEqual(status(401), .invalidKey)
        XCTAssertEqual(status(403), .invalidKey)
        XCTAssertEqual(status(404), .notFound)
        XCTAssertEqual(status(429), .rateLimited)
        XCTAssertEqual(status(503), .server(status: 503))
        XCTAssertThrowsError(try ChatProviderWire.check(URLResponse(), data: Data()))
    }

    // MARK: Client

    func testClientFollowsCatalogPagesAndRemovesDuplicates() async throws {
        let (client, host) = client { request in
            if request.url?.query?.contains("after_id=b") == true {
                return .init(body: #"{"data":[{"id":"b"},{"id":"c"}],"has_more":false}"#)
            }
            return .init(body: #"{"data":[{"id":"a"},{"id":"b"}],"has_more":true,"last_id":"b"}"#)
        }
        let provider = ChatProvider(kind: .custom, baseURL: "https://\(host)", models: [])
        var anthropic = provider
        anthropic.kind = .anthropic
        let models = try await client.models(provider: anthropic, apiKey: "k")
        XCTAssertEqual(models.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ProviderFixtureProtocol.fixtures.recorded(host).count, 2)
    }

    func testClientStreamsAnswerAndReportsFailures() async throws {
        let (client, host) = client { request in
            if request.url?.path.hasSuffix("chat/completions") == true, (try? JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()) as? [String: Any])?["model"] as? String == "bad" {
                return .init(status: 401, body: #"{"error":{"message":"bad key"}}"#)
            }
            return .init(body: """
            data: {"choices":[{"delta":{"content":"Hel"}}]}

            data: {"choices":[{"delta":{"content":"lo"}}]}

            data: [DONE]

            """, contentType: "text/event-stream")
        }
        let provider = ChatProvider(kind: .custom, baseURL: "https://\(host)/v1")
        let events = try await collect(client.stream(ChatProviderRequest(
            provider: provider, apiKey: "k", model: "good", messages: [ChatProviderMessage(role: "user", text: "Hi")]
        )))
        XCTAssertEqual(events, [.text("Hel"), .text("lo")])
        do {
            _ = try await collect(client.stream(ChatProviderRequest(
                provider: provider, apiKey: "k", model: "bad", messages: []
            )))
            XCTFail("Expected a rejected key")
        } catch {
            XCTAssertEqual(error as? ChatProviderError, .invalidKey)
        }
    }

    func testClientSurfacesConnectionFailures() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        let client = ChatProviderClient(session: URLSession(configuration: configuration))
        let provider = ChatProvider(kind: .custom, baseURL: "https://unregistered.example.com")
        do {
            _ = try await client.models(provider: provider, apiKey: nil)
            XCTFail("Expected a connection error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testTypefluxGatewayFailureIsReportedAsAnOutage() async {
        let host = UUID().uuidString.lowercased() + ".example.com"
        ProviderFixtureProtocol.fixtures.set(host) { request in
            request.url?.path.hasSuffix("/models") == true
                ? .init(status: 502, body: "<html>Bad gateway</html>", contentType: "text/html")
                : .init(status: 500, body: #"{"code":"INTERNAL_ERROR","message":"boom"}"#)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        let api = ChatAPIClient(baseURL: URL(string: "https://\(host)")!,
                                session: URLSession(configuration: configuration))
        do {
            _ = try await api.models(token: "t")
            XCTFail("Expected an outage")
        } catch {
            XCTAssertEqual(error as? ChatAPIError, .server(code: "HTTP_502", message: nil))
            XCTAssertEqual(ChatConnectivity.classify(error), .serviceUnavailable)
        }
        do {
            _ = try await api.list(token: "t", offset: 0)
            XCTFail("Expected a server error")
        } catch {
            XCTAssertEqual(error as? ChatAPIError, .server(code: "INTERNAL_ERROR", message: "boom"))
        }
    }

    func testDefaultClientRefusesRedirects() {
        let policy = ChatProviderRedirectPolicy()
        let expectation = expectation(description: "redirect decision")
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com")!)
        policy.urlSession(session, task: task,
                          willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://example.com")!,
                                                                      statusCode: 302, httpVersion: nil,
                                                                      headerFields: nil)!,
                          newRequest: URLRequest(url: URL(string: "https://elsewhere.example.com")!)) { request in
            XCTAssertNil(request)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        _ = ChatProviderClient()
    }
}
