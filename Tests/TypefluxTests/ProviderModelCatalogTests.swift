@testable import Typeflux
import XCTest

final class ProviderModelCatalogTests: XCTestCase {
    func testParsesNativeAndCompatibleCatalogsWithoutHidingExcludedModels() throws {
        let openAI = RegisteredProvider(id: "openAI", name: "OpenAI", remote: .openAI)
        let page = try HTTPProviderModelCatalog.parse(
            Data(#"{"data":[{"id":"chat"},{"id":"text-embedding-3-large"}]}"#.utf8),
            provider: openAI
        )
        XCTAssertEqual(page.models.count, 2)
        XCTAssertNil(page.models[0].exclusionReason)
        XCTAssertNotNil(page.models[1].exclusionReason)
        let anthropic = RegisteredProvider(id: "anthropic", name: "Anthropic", remote: .anthropic)
        let native = try HTTPProviderModelCatalog.parse(
            Data(#"{"data":[{"id":"claude","display_name":"Claude"}],"has_more":true,"last_id":"claude"}"#.utf8),
            provider: anthropic
        )
        XCTAssertEqual(native.cursor, "claude")
        XCTAssertEqual(native.models.first?.name, "Claude")
        let gemini = RegisteredProvider(id: "gemini", name: "Gemini", remote: .gemini)
        let google = try HTTPProviderModelCatalog.parse(
            Data(#"{"models":[{"name":"models/gemini","displayName":"Gemini"}],"nextPageToken":"next"}"#.utf8),
            provider: gemini
        )
        XCTAssertEqual(google.models.first?.id, "gemini")
        XCTAssertEqual(google.cursor, "next")
        let ollama = RegisteredProvider(id: "ollama", name: "Ollama")
        let local = try HTTPProviderModelCatalog.parse(
            Data(#"{"models":[{"name":"local","capabilities":["vision"]}]}"#.utf8),
            provider: ollama
        )
        XCTAssertEqual(local.models.first?.vision, true)
        let router = try HTTPProviderModelCatalog.parse(
            Data(#"{"data":[{"id":"vision","architecture":{"input_modalities":["text","image"]}}]}"#.utf8),
            provider: openAI
        )
        XCTAssertEqual(router.models.first?.vision, true)
        for invalid in ["[]", "{}", #"{"data":[{}]}"#, #"{"data":[],"has_more":true}"#, "bad"] {
            XCTAssertThrowsError(try HTTPProviderModelCatalog.parse(Data(invalid.utf8), provider: openAI))
        }
    }

    func testCatalogRequestsAllPagesAndUsesProviderAuthentication() async throws {
        let session = catalogSession()
        for remote in [LLMRemoteProvider.openAI, .anthropic, .gemini] {
            CatalogURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/v1/models")
                switch remote {
                case .anthropic:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                    return (
                        200,
                        request.url?.query == nil ? #"{"data":[{"id":"one"}],"has_more":true,"last_id":"one"}"# : #"{"data":[{"id":"two"}],"has_more":false}"#
                    )
                case .gemini:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture")
                    return (
                        200,
                        request.url?.query == nil ? #"{"models":[{"name":"models/one"}],"nextPageToken":"one"}"# : #"{"models":[{"name":"models/two"}]}"#
                    )
                default:
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                    return (200, #"{"data":[{"id":"two"},{"id":"one"},{"id":"one"}]}"#)
                }
            }
            let models = try await HTTPProviderModelCatalog(session: session).models(
                provider: .init(id: remote.rawValue, name: "Test", remote: remote),
                connection: .init(provider: remote, baseURL: "https://example.invalid/v1", model: "", apiKey: "fixture")
            )
            XCTAssertEqual(models.map(\.id), ["one", "two"])
        }
    }

    func testRequestErrorsAndRepeatedPaginationAreExplicit() async throws {
        let client = HTTPProviderModelCatalog(session: catalogSession())
        let provider = RegisteredProvider(id: "anthropic", name: "Anthropic", remote: .anthropic)
        let connection = SettingsStore.TextLLMConfiguration(
            provider: .anthropic,
            baseURL: "https://example.invalid/v1",
            model: "",
            apiKey: "fixture"
        )
        for (code, body) in [
            (401, "unauthorized"),
            (200, "{}"),
            (200, #"{"data":[],"has_more":true,"last_id":"same"}"#)
        ] {
            CatalogURLProtocol.handler = { _ in (code, body) }
            do { _ = try await client.models(provider: provider, connection: connection); XCTFail("Expected error") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        CatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"models":[{"name":"local"}]}"#)
        }
        let local = try await client.models(
            provider: .init(id: "ollama", name: "Ollama"),
            connection: .init(provider: .custom, baseURL: "http://localhost:11434", model: "", apiKey: "")
        )
        XCTAssertEqual(local.first?.id, "local")
    }

    func testNativeInferencePreservesImagesToolsAndGeminiSignatures() throws {
        let body: [String: Any] = ["messages": [
            ["role": "system", "content": "Follow instructions"],
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": "Look"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]
                ]
            ],
            [
                "role": "assistant",
                "tool_calls": [["id": "call1", "function": ["name": "search", "arguments": "{\"query\":\"test\"}"]]]
            ],
            ["role": "tool", "tool_call_id": "call1", "content": "Found"],
            ["role": "tool", "tool_call_id": "call1", "content": "Another result"]
        ], "tools": [["type": "function", "function": ["name": "search", "parameters": ["type": "object"]]]]]
        for anthropic in [true, false] {
            let native = try AskCustomInference.nativeBody(body, model: "chosen", anthropic: anthropic)
            let json = try String(decoding: JSONSerialization.data(withJSONObject: native), as: UTF8.self)
            XCTAssertTrue(json.contains("AAAA"))
            XCTAssertTrue(json.contains("png"))
            XCTAssertTrue(json.contains("Follow instructions"))
            XCTAssertTrue(json.contains("search"))
            XCTAssertTrue(json.contains("Another result"))
            XCTAssertEqual((native[anthropic ? "messages" : "contents"] as? [[String: Any]])?.count, 3)
        }
        let anthropic = try AskCustomInference.nativeReply(
            Data(#"{"content":[{"type":"text","text":"Answer"},{"type":"tool_use","id":"call","name":"search","input":{"q":"test"}}]}"#
                .utf8),
            anthropic: true
        )
        XCTAssertEqual(anthropic.0, "Answer")
        XCTAssertEqual(anthropic.1.first?.id, "call")
        let gemini = try AskCustomInference.nativeReply(
            Data(#"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"Visible"},{"functionCall":{"name":"search","args":{}},"thoughtSignature":"signature"}]}}]}"#
                .utf8),
            anthropic: false
        )
        XCTAssertEqual(gemini.0, "Visible")
        let call = try XCTUnwrap(gemini.1.first)
        let replay: [String: Any] = ["messages": [[
            "role": "assistant",
            "tool_calls": [[
                "id": call.id,
                "thought_signature": call.thoughtSignature ?? "",
                "function": ["name": call.function.name, "arguments": call.function.arguments]
            ]]
        ]]]
        let restored = try AskCustomInference.nativeBody(replay, model: "gemini", anthropic: false)
        XCTAssertTrue(try String(decoding: JSONSerialization.data(withJSONObject: restored), as: UTF8.self)
            .contains("signature"))
        for invalid in ["{}", "[]"] {
            XCTAssertThrowsError(try AskCustomInference.nativeReply(
                Data(invalid.utf8),
                anthropic: true
            ))
        }
        XCTAssertThrowsError(try AskCustomInference.nativeBody([:], model: "m", anthropic: true))
        XCTAssertThrowsError(try AskCustomInference.nativeBody(
            ["messages": [["role": "user", "content": [["type": "audio"]]]]],
            model: "m",
            anthropic: true
        ))
    }

    func testNativeAndOllamaInferenceSendTheChosenModel() async throws {
        let inference = AskCustomInference(session: catalogSession())
        for remote in [LLMRemoteProvider.anthropic, .gemini, .custom] {
            CatalogURLProtocol.handler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                if remote == .anthropic {
                    XCTAssertEqual(body?["model"] as? String, "selected")
                    XCTAssertEqual(request.url?.path, "/v1/messages")
                    return (200, #"{"content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":10,"output_tokens":4}}"#)
                }
                if remote == .gemini {
                    XCTAssertEqual(request.url?.path, "/v1/models/selected:generateContent")
                    return (200, #"{"candidates":[{"content":{"parts":[{"text":"OK"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4,"totalTokenCount":14}}"#)
                }
                XCTAssertEqual(body?["model"] as? String, "selected")
                XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                return (200, #"{"choices":[{"message":{"content":"OK"}}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#)
            }
            let provider = RegisteredProvider(
                id: remote == .custom ? "ollama" : remote.rawValue,
                name: "Test",
                remote: remote == .custom ? nil : remote
            )
            let recorder = CatalogUsageRecorder()
            let result = try await inference.complete(
                provider: provider,
                connection: .init(provider: remote, baseURL: "https://example.invalid/v1", model: "selected",
                                  apiKey: "fixture"),
                payload: #"{"messages":[{"role":"user","content":"Hello"}]}"#,
                onUsage: { await recorder.append($0) }
            )
            XCTAssertEqual(result.0, "OK")
            let usage = await recorder.value
            XCTAssertEqual(usage?.totalTokens, 14)
        }
    }

    private func catalogSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 {
                        break
                    }
                    data.append(buffer, count: count)
                }
                captured.httpBody = data
            }
            let (code, body) = try Self.handler!(captured)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}

private actor CatalogUsageRecorder {
    var value: AskTokenUsage?
    func append(_ value: AskTokenUsage) { self.value = value }
}
