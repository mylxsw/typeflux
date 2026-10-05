import Foundation
@testable import Typeflux
import XCTest

final class ModelProtocolHTTPTests: XCTestCase {
    private let completedResponse = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
    override func tearDown() {
        AskThinkingCaptureProtocol.bodies = []
        AskThinkingCaptureProtocol.requests = []
        AskThinkingCaptureProtocol.reasoningStatus = 200
        AskThinkingCaptureProtocol.reply = #"{"choices":[{"message":{"content":"OK"}}]}"#
        super.tearDown()
    }

    func testCustomProfilesRouteToSelectedProtocolAndAuthenticate() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        let replies: [(LLMRemoteAPIStyle, String, String)] = [
            (.openAICompatible, "chat/completions", #"{"choices":[{"message":{"content":"OK"}}]}"#),
            (.anthropic, "messages", #"{"content":[{"type":"text","text":"OK"}]}"#),
            (
                .responses,
                "responses",
                #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
            )
        ]
        for (style, path, reply) in replies {
            AskThinkingCaptureProtocol.reply = reply
            let result = try await adapter.complete(
                profile: .init(
                    name: "Gateway",
                    baseURL: "https://example.invalid/prefix/v1/chat/completions",
                    model: "selected",
                    apiStyle: style
                ),
                key: "test-key", payload: #"{"messages":[{"role":"user","content":"Hello"}],"max_tokens":512}"#
            )
            XCTAssertEqual(result.0, "OK")
            let request = try XCTUnwrap(AskThinkingCaptureProtocol.requests.last)
            XCTAssertEqual(request.url?.path, "/prefix/v1/" + path)
            XCTAssertEqual(request.value(forHTTPHeaderField: style == .anthropic ? "x-api-key" : "Authorization"),
                           style == .anthropic ? "test-key" : "Bearer test-key")
            XCTAssertEqual(AskThinkingCaptureProtocol.bodies.last?["model"] as? String, "selected")
            if style == .anthropic {
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            }
        }
    }

    func testCatalogUsesSelectedProtocolForCustomProvider() async throws {
        AskThinkingCaptureProtocol.reply = #"{"data":[{"id":"claude","display_name":"Claude"}],"has_more":false}"#
        let catalog = HTTPProviderModelCatalog(session: AskThinkingCaptureProtocol.session)
        for style in LLMRemoteAPIStyle.customChoices {
            let provider = RegisteredProvider(id: "endpoint:test", name: "Custom", apiStyle: style)
            let models = try await catalog.models(provider: provider, connection: .init(
                provider: .custom, baseURL: "https://example.invalid/v1/responses", model: "m", apiKey: "key",
                apiStyle: style
            ))
            XCTAssertEqual(models.map(\.id), ["claude"])
            let request = try XCTUnwrap(AskThinkingCaptureProtocol.requests.last)
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: style == .anthropic ? "x-api-key" : "Authorization"),
                           style == .anthropic ? "key" : "Bearer key")
        }
    }

    func testResponsesHTTPStreamingAndBudget() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        let profile = AskModelProfile(
            name: "Responses",
            baseURL: "https://example.invalid/v1",
            model: "m",
            apiStyle: .responses
        )
        let payload = #"{"messages":[{"role":"user","content":"Hi"}],"typeflux_budget":true,"max_tokens":512}"#
        AskThinkingCaptureProtocol.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}}\n\n"
        let result = try await adapter.complete(profile: profile, key: "", payload: payload, onProgress: { _ in })
        XCTAssertEqual(result.0, "OK")
        let body = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.last)
        XCTAssertNil(body["typeflux_budget"])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 512)
        XCTAssertEqual(body["stream"] as? Bool, true)
        AskThinkingCaptureProtocol.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        do {
            _ = try await adapter.complete(profile: profile, key: "", payload: payload, onProgress: { _ in })
            XCTFail("Truncated SSE must fail")
        } catch { XCTAssertTrue(error is AskStreamError) }
        let attempts = AskThinkingCaptureProtocol.requests.count
        do {
            _ = try await adapter.complete(
                profile: profile,
                key: "",
                payload: #"{"messages":[],"typeflux_budget":true,"typeflux_deadline":1}"#
            )
            XCTFail("Expired budget must fail before sending")
        } catch { XCTAssertTrue(error is AskBudgetError) }
        XCTAssertEqual(AskThinkingCaptureProtocol.requests.count, attempts)
    }

    func testOpenAIRequestDoesNotLeakNativeContinuationMetadata() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        _ = try await adapter.complete(
            profile: .init(name: "Custom", baseURL: "https://example.invalid/v1", model: "m"),
            key: "",
            payload: #"{"messages":[{"role":"assistant","tool_calls":[{"id":"a","type":"function","provider_context":"opaque","thought_signature":"signed","function":{"name":"f","arguments":"{}"}}]},{"role":"tool","tool_call_id":"a","content":"done"}]}"#
        )
        let messages = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.last?["messages"] as? [[String: Any]])
        let call = try XCTUnwrap((messages[0]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertNil(call["provider_context"])
        XCTAssertNil(call["thought_signature"])
        XCTAssertEqual(call["id"] as? String, "a")
    }

    func testResponsesRewriteTransportSupportsJSONAndStreaming() async throws {
        let session = AskThinkingCaptureProtocol.session
        let base = try XCTUnwrap(URL(string: "https://example.invalid/v1"))
        AskThinkingCaptureProtocol.reply = completedResponse
        let body = ResponsesLLMClient.textBody(system: "Rules", user: "Text")
        let result = try await ResponsesLLMClient.complete(baseURL: base, model: "m", apiKey: "key",
                                                           headers: ["X-Test": "rewrite"], body: body, session: session)
        XCTAssertEqual(result.0, "OK")
        XCTAssertEqual(AskThinkingCaptureProtocol.requests.last?.value(forHTTPHeaderField: "X-Test"), "rewrite")
        AskThinkingCaptureProtocol.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"O\"}\n\n" +
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"K\"}\n\n" +
            "data: {\"type\":\"response.completed\",\"response\":" + completedResponse + "}\n\n"
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let final = try await ResponsesLLMClient.stream(baseURL: base, model: "m", apiKey: "key", headers: [:],
                                                        system: "Rules", user: "Text", continuation: continuation,
                                                        session: session)
        continuation.finish()
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["O", "K"])
        XCTAssertEqual(final, "OK")
        AskThinkingCaptureProtocol.reply = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        let (_, incomplete) = AsyncThrowingStream<String, Error>.makeStream()
        defer { incomplete.finish() }
        do {
            _ = try await ResponsesLLMClient.stream(baseURL: base, model: "m", apiKey: "", headers: [:],
                                                    system: "Rules", user: "Text", continuation: incomplete,
                                                    session: session)
            XCTFail("Rewrite must reject interrupted streams")
        } catch { XCTAssertTrue(error is AskStreamError) }
    }
}
