import Foundation
@testable import Typeflux
import XCTest

final class ModelProtocolTests: XCTestCase {
    func testLegacyAndUnknownProtocolDecodeWithoutLosingRegistry() throws {
        let old = Data(#"{"version":2,"providers":[{"id":"custom","name":"Legacy","remote":"custom","baseURL":"https://example.test/v1","models":[]}]}"#
            .utf8)
        let registry = try JSONDecoder().decode(ModelRegistry.self, from: old)
        XCTAssertEqual(registry.providers[0].effectiveAPIStyle, .openAICompatible)
        XCTAssertTrue(registry.providers[0].supportsProtocolSelection)
        let native = RegisteredProvider(id: "anthropic", name: "Claude", remote: .anthropic)
        XCTAssertEqual(native.effectiveAPIStyle, .anthropic)
        XCTAssertFalse(native.supportsProtocolSelection)
        let unknown = try JSONDecoder().decode(LLMRemoteAPIStyle.self, from: Data(#""future""#.utf8))
        XCTAssertEqual(unknown, .unsupported)
        for style in LLMRemoteAPIStyle.customChoices {
            let value = RegisteredProvider(id: "endpoint:test", name: "Test", apiStyle: style)
            XCTAssertEqual(try JSONDecoder().decode(RegisteredProvider.self, from: JSONEncoder().encode(value)), value)
            XCTAssertFalse(style.displayName.isEmpty)
            let config = SettingsStore.TextLLMConfiguration(
                provider: .custom,
                baseURL: "https://example.test/v1",
                model: "m",
                apiKey: "k",
                apiStyle: style
            )
            let resolved = try LLMConnectionResolver.resolve(
                provider: config.provider,
                baseURL: config.baseURL,
                model: config.model,
                apiKey: config.apiKey,
                apiStyle: config.effectiveAPIStyle
            )
            XCTAssertEqual(resolved.effectiveAPIStyle, style)
        }
    }

    @MainActor
    func testProtocolPersistsThroughMigrationAndRewriteSelection() throws {
        let suite = "protocol-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AskModelProfile(
            name: "Native",
            baseURL: "https://example.test/v1",
            model: "m",
            apiStyle: .responses
        )
        try defaults.set(JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.rewriteReference = profile.reference
        XCTAssertEqual(library.profiles.first?.apiStyle, .responses)
        XCTAssertEqual(SettingsStore(defaults: defaults).textLLMConfiguration().effectiveAPIStyle, .responses)
        let custom = try XCTUnwrap(library.providers.first { $0.remote == .custom })
        try library.updateConnection(custom, baseURL: "https://example.test/v1", key: "", apiStyle: .anthropic)
        XCTAssertEqual(
            ModelRegistry.read(defaults)?.providers.first { $0.id == custom.id }?.effectiveAPIStyle,
            .anthropic
        )
        XCTAssertTrue(ModelSettingsPresentation.connectionChanged(
            savedBaseURL: "x",
            savedKey: "",
            baseURL: "x",
            key: "",
            savedAPIStyle: .openAICompatible,
            apiStyle: .responses
        ))
    }

    func testProtocolEndpointsAndCatalogDoNotAppendToFullEndpoint() throws {
        for source in ["chat/completions", "messages", "responses", "models"] {
            let url = try XCTUnwrap(URL(string: "https://example.test/prefix/v1/" + source))
            for target in ["chat/completions", "messages", "responses", "models"] {
                XCTAssertEqual(OpenAIEndpointResolver.resolve(from: url, path: target).path, "/prefix/v1/" + target)
            }
        }
        let url = try XCTUnwrap(URL(string: "https://example.test/somemessages"))
        XCTAssertEqual(OpenAIEndpointResolver.resolve(from: url, path: "messages").path, "/somemessages/messages")
    }

    func testResponsesMapsImagesToolsSchemaAndTokenBudget() throws {
        let source: [String: Any] = [
            "messages": [["role": "system", "content": "rules"],
                         [
                             "role": "user",
                             "content": [
                                 ["type": "text", "text": "look"],
                                 ["type": "image_url", "image_url": ["url": "data:image/png;base64,eA=="]]
                             ]
                         ],
                         [
                             "role": "assistant",
                             "tool_calls": [["id": "call1", "function": ["name": "f", "arguments": "{}"]]]
                         ],
                         ["role": "tool", "tool_call_id": "call1", "content": "result"]],
            "tools": [["type": "function", "function": ["name": "f", "parameters": ["type": "object"]]]],
            "tool_choice": ["type": "function", "function": ["name": "f"]],
            "max_tokens": 2048, "reasoning_effort": "high", "stream_options": ["include_usage": true],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "answer", "schema": ["type": "object"], "strict": true]
            ]
        ]
        let body = try ResponsesAPI.body(source, model: "selected")
        XCTAssertEqual(body["model"] as? String, "selected")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertNil(body["messages"]); XCTAssertNil(body["stream_options"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["call_id"] as? String, "call1")
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["strict"] as? Bool, false)
        XCTAssertNotNil((body["text"] as? [String: Any])?["format"])
        let request = try ResponsesLLMClient.request(
            baseURL: XCTUnwrap(URL(string: "https://example.test/v1")),
            model: "m",
            apiKey: "key",
            body: source
        )
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertThrowsError(try ResponsesAPI.body([:], model: "m"))
    }

    func testResponsesToolContextRoundTripAndUsage() throws {
        let output: [[String: Any]] = [["type": "reasoning", "id": "rs1", "encrypted_content": "opaque", "summary": []],
                                       [
                                           "type": "function_call",
                                           "call_id": "call1",
                                           "id": "fc1",
                                           "name": "f",
                                           "arguments": "{}"
                                       ]]
        let (_, calls) = try ResponsesAPI.reply(["status": "completed", "output": output])
        let context = try XCTUnwrap(calls.first?.providerContext)
        let source: [String: Any] = ["messages": [["role": "assistant", "tool_calls": [["provider_context": context]]]]]
        let body = try ResponsesAPI.body(source, model: "m")
        XCTAssertEqual(try XCTUnwrap(body["input"] as? NSArray), output as NSArray)
        let usage = AskTokenUsage.parse(["usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15,
                                                   "input_tokens_details": ["cached_tokens": 3]]], style: .responses)
        XCTAssertEqual(usage?.cachedTokens, 3); XCTAssertEqual(usage?.totalTokens, 15)
        XCTAssertThrowsError(try ResponsesAPI.reply(["status": "failed", "output": output]))
        XCTAssertThrowsError(try ResponsesAPI.reply(["status": "incomplete", "output": output], allowIncomplete: true))
    }

    func testResponsesStreamRequiresTerminalEventAndPreservesFinalItems() throws {
        var stream = AskProviderStream(style: .responses)
        try stream.consume(#"{"type":"response.created"}"#)
        try stream.consume(#"{"type":"response.reasoning_summary_text.delta","delta":"thinking"}"#)
        try stream.consume(#"{"type":"response.output_text.delta","delta":"Hi"}"#)
        XCTAssertThrowsError(try stream.result())
        try stream
            .consume(
                #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hi"}]}],"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#
            )
        XCTAssertEqual(try stream.result().0, "Hi")
        XCTAssertEqual(stream.progress.reasoning, "thinking")
        XCTAssertEqual(stream.progress.usage?.totalTokens, 3)
        var tools = ResponsesStream()
        try tools
            .consume(
                #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"a","name":"f","arguments":""}}"#
            )
        try tools.consume(#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{}"}"#)
        XCTAssertEqual(tools.progress.toolCalls.first?.function.arguments, "{}")
        XCTAssertThrowsError(try tools.consume(#"{"type":"response.failed"}"#))
        var truncated = ResponsesStream()
        try truncated
            .consume(
                #"{"type":"response.incomplete","response":{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}}"#
            )
        XCTAssertTrue(truncated.progress.truncated)
        XCTAssertEqual(try truncated.result().0, "Partial")
    }

    func testAnthropicStreamingPreservesSignedToolContext() throws {
        var stream = AskProviderStream(style: .anthropic)
        for event in [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"plan","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"a","name":"f","input":{}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_stop"}"#
        ] {
            try stream.consume(event)
        }
        let context = try XCTUnwrap(try stream.result().1.first?.providerContext)
        let source: [String: Any] = ["messages": [["role": "assistant", "tool_calls": [["provider_context": context]]],
                                                  ["role": "tool", "tool_call_id": "a", "content": "OK"]]]
        var native = try AskCustomInference.nativeBody(source, model: "m", anthropic: true)
        let messages = try XCTUnwrap(native["messages"] as? [[String: Any]])
        XCTAssertEqual((messages.first?["content"] as? [[String: Any]])?.first?["signature"] as? String, "signed")
        AskReasoningRequest.applyAnthropic(effort: "low", to: &native, totalOutputLimit: 4096)
        XCTAssertNotNil(native["thinking"])
    }
}
