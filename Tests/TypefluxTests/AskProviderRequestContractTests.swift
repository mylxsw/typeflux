import Foundation
@testable import Typeflux
import XCTest

/// Exercises the serialized bridge payload at the provider HTTP boundary.
final class AskProviderRequestContractTests: XCTestCase {
    override func tearDown() {
        AskThinkingCaptureProtocol.bodies = []
        AskThinkingCaptureProtocol.requests = []
        AskThinkingCaptureProtocol.reasoningStatus = 200
        AskThinkingCaptureProtocol.reply = #"{"choices":[{"message":{"content":"OK"}}]}"#
        super.tearDown()
    }

    func testGeminiDefaultsAndExplicitOutputLimits() throws {
        for limit in [nil, 1, 1500, 4096, 16384, Int(Int32.max)] as [Int?] {
            var body: [String: Any] = ["messages": [["role": "user", "content": "Hello"]]]
            body["max_tokens"] = limit
            let native = try AskCustomInference.nativeBody(body, model: "gemini", anthropic: false)
            let config = try XCTUnwrap(native["generationConfig"] as? [String: Any])
            XCTAssertEqual(config["maxOutputTokens"] as? Int, limit ?? AskLocalPrompt.maxAnswerTokens)
            XCTAssertNil(config["thinkingConfig"])
            XCTAssertNil(native["max_tokens"])
        }
    }

    func testGeminiRejectsInvalidOutputLimitsBeforeSending() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        for value in ["0", "-1", "1.5", "null", "true", "false", "\"4096\"", "[]", "{}",
                      "2147483648", "9223372036854775808"] {
            let payload = "{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":\(value)}"
            do {
                _ = try await adapter.complete(provider: .init(id: "gemini", name: "Gemini", remote: .gemini),
                                               connection: connection(.gemini), payload: payload)
                XCTFail("Accepted invalid max_tokens: \(value)")
            } catch {
                XCTAssertEqual(error.localizedDescription, L("models.invalidResponse"), value)
            }
        }
        XCTAssertTrue(AskThinkingCaptureProtocol.requests.isEmpty)
    }

    func testThinkingMergeAndOneTimeFallbackNeverChangeGeminiOutputLimit() async throws {
        for limit in [1, 1500, 4096, 16384] {
            for effort in [nil, "unknown", "low", "medium", "high"] as [String?] {
                var native = try AskCustomInference.nativeBody(
                    ["messages": [], "max_tokens": limit], model: "gemini", anthropic: false)
                // Other generation options must survive both merging and stripping thinking.
                var config = try XCTUnwrap(native["generationConfig"] as? [String: Any])
                config["temperature"] = 0.25
                native["generationConfig"] = config
                AskReasoningRequest.applyGemini(effort: effort, to: &native)
                let merged = try XCTUnwrap(native["generationConfig"] as? [String: Any])
                XCTAssertEqual(merged["maxOutputTokens"] as? Int, limit)
                let budget = effort.flatMap { AskReasoningRequest.geminiBudgets[$0] }
                XCTAssertEqual((merged["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, budget)
                var attempts: [[String: Any]] = []
                let result = try await AskReasoningRequest.send(native) { body in
                    attempts.append(body)
                    if budget != nil, attempts.count == 1 { throw AskStreamError.rejected }
                    return "OK"
                }
                XCTAssertEqual(result, "OK")
                XCTAssertEqual(attempts.count, budget == nil ? 1 : 2)
                let fallback = try XCTUnwrap(attempts.last?["generationConfig"] as? [String: Any])
                XCTAssertEqual(fallback as NSDictionary, config as NSDictionary)
            }
        }
    }

    func testRejectedFallbackStopsAfterTwoAttemptsWithTheSameCap() async throws {
        var native = try AskCustomInference.nativeBody(["messages": [], "max_tokens": 1500], model: "gemini", anthropic: false)
        AskReasoningRequest.applyGemini(effort: "high", to: &native)
        var attempts = 0
        do {
            _ = try await AskReasoningRequest.send(native) { body -> String in
                attempts += 1
                XCTAssertEqual((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 1500)
                throw AskStreamError.rejected
            }
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("ask.models.requestError"))
        }
        XCTAssertEqual(attempts, 2)
    }

    func testLocalAndCloudToolTurnsKeepProviderRequestContracts() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        for payload in try toolPayloads() {
            for (id, remote) in [("custom", LLMRemoteProvider.custom), ("ollama", .custom),
                                 ("anthropic", .anthropic), ("gemini", .gemini)] {
                AskThinkingCaptureProtocol.bodies = []
                AskThinkingCaptureProtocol.requests = []
                AskThinkingCaptureProtocol.reply = reply(remote)
                let (text, calls) = try await adapter.complete(
                    provider: .init(id: id, name: id, remote: remote), connection: connection(remote), payload: payload)
                XCTAssertEqual(text, "OK")
                XCTAssertTrue(calls.isEmpty)
                let body = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.last)
                let request = try XCTUnwrap(AskThinkingCaptureProtocol.requests.last)
                let json = AskLocalPrompt.json(body)
                XCTAssertTrue(json.contains("Observed"))
                XCTAssertTrue(json.contains("Yg=="), "Tool-result image was dropped")
                if remote == .gemini {
                    XCTAssertEqual(request.url?.path, "/models/selected:generateContent")
                    let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
                    XCTAssertEqual(config["maxOutputTokens"] as? Int, 4096)
                    XCTAssertEqual((config["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 24576)
                    XCTAssertTrue(json.contains("\"thoughtSignature\":\"sig\""))
                    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                    let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
                    XCTAssertEqual((parts.first?["functionResponse"] as? [String: Any])?["name"] as? String, "browser")
                    XCTAssertNotNil(parts.last?["inlineData"])
                } else {
                    XCTAssertEqual(body["max_tokens"] as? Int, 4096)
                    XCTAssertEqual(body["model"] as? String, "selected")
                    XCTAssertFalse(json.contains("thought_signature"))
                    if remote == .anthropic {
                        XCTAssertEqual(request.url?.path, "/messages")
                        XCTAssertNil(body["thinking"], "Tool turns cannot replay Anthropic thinking blocks")
                        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
                        XCTAssertEqual(parts.first?["type"] as? String, "tool_result")
                        XCTAssertEqual(parts.last?["type"] as? String, "image")
                    } else {
                        XCTAssertEqual(request.url?.path, id == "ollama" ? "/v1/chat/completions" : "/chat/completions")
                        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
                        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                        XCTAssertTrue(messages.contains { $0["tool_call_id"] as? String == "tool-1" })
                    }
                }
            }
        }
    }

    func testGeminiHTTPFallbackKeepsCapAndToolContextForStreamingAndBufferedReplies() async throws {
        let adapter = AskCustomInference(session: AskThinkingCaptureProtocol.session)
        for payload in try toolPayloads() {
            for streaming in [false, true] {
                for status in [400, 422] {
                    AskThinkingCaptureProtocol.bodies = []
                    AskThinkingCaptureProtocol.requests = []
                    AskThinkingCaptureProtocol.reasoningStatus = status
                    let response = #"{"candidates":[{"content":{"parts":[{"text":"Cut"}]},"finishReason":"MAX_TOKENS"}]}"#
                    AskThinkingCaptureProtocol.reply = streaming ? "data: \(response)\n\n" : response
                    let recorder = ProviderProgressRecorder()
                    var progress: (@Sendable (AskStreamProgress) async -> Void)?
                    if streaming { progress = { await recorder.append($0) } }
                    let (text, _) = try await adapter.complete(
                        provider: .init(id: "gemini", name: "Gemini", remote: .gemini), connection: connection(.gemini),
                        payload: payload, onProgress: progress)
                    XCTAssertEqual(text, "Cut")
                    XCTAssertEqual(AskThinkingCaptureProtocol.bodies.count, 2)
                    var first = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.first)
                    XCTAssertTrue(AskReasoningRequest.strip(&first))
                    let fallback = try XCTUnwrap(AskThinkingCaptureProtocol.bodies.last)
                    XCTAssertEqual(first as NSDictionary, fallback as NSDictionary)
                    XCTAssertEqual((fallback["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 4096)
                    XCTAssertEqual(AskThinkingCaptureProtocol.requests.last?.url?.path,
                                   streaming ? "/models/selected:streamGenerateContent" : "/models/selected:generateContent")
                    if streaming {
                        let last = await recorder.last
                        XCTAssertEqual(last?.truncated, true)
                        XCTAssertEqual(last?.text, "Cut")
                    }
                }
            }
        }
    }

    func testLocalSummaryRetainsItsSmallerGeminiCap() throws {
        let conversation = localConversation()
        let payload = AskLocalPrompt.summaryPayload(conversation: conversation, through: conversation.messages.count)
        let native = try AskCustomInference.nativeBody(payload, model: "gemini", anthropic: false)
        XCTAssertEqual((native["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 1500)
    }

    func testAnthropicFallbackRetainsTheInitialThinkingAndAnswerCeiling() async throws {
        for effort in ["low", "medium", "high"] {
            var native = try AskCustomInference.nativeBody(
                ["messages": [["role": "user", "content": "Hello"]], "max_tokens": 1500], model: "claude", anthropic: true)
            AskReasoningRequest.applyAnthropic(effort: effort, to: &native)
            let ceiling = try XCTUnwrap(AskReasoningRequest.anthropicBudgets[effort]) + 1500
            var attempts = 0
            _ = try await AskReasoningRequest.send(native) { body in
                attempts += 1
                XCTAssertEqual(body["max_tokens"] as? Int, ceiling)
                if attempts == 1 { throw AskStreamError.rejected }
                XCTAssertNil(body["thinking"])
                return "OK"
            }
            XCTAssertEqual(attempts, 2)
        }
    }

    private func connection(_ remote: LLMRemoteProvider) -> SettingsStore.TextLLMConfiguration {
        .init(provider: remote, baseURL: "https://example.invalid", model: "selected", apiKey: "fixture")
    }

    private func reply(_ remote: LLMRemoteProvider) -> String {
        switch remote {
        case .gemini: return #"{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#
        case .anthropic: return #"{"content":[{"type":"text","text":"OK"}]}"#
        default: return #"{"choices":[{"message":{"content":"OK"}}]}"#
        }
    }

    private func localConversation() -> AskConversation {
        AskConversation(id: "conversation", title: "Test", revision: 1, updatedAt: Date(), messages: [
            AskMessage(id: "u", role: "user", text: "Look", createdAt: Date()),
            AskMessage(id: "a", role: "assistant", text: "", toolCalls: [
                AskToolCall(id: "tool-1", function: .init(name: "browser", arguments: "{}"), thoughtSignature: "sig")
            ], createdAt: Date()),
            AskMessage(id: "t", role: "tool", text: "Observed", image: "data:image/png;base64,Yg==", toolCallId: "tool-1", createdAt: Date())
        ], run: AskRun(id: "run", deviceId: "device", status: "running", steps: 1, updatedAt: Date(),
                      tools: [], pending: [], modelRef: "custom:model", reasoningEffort: "high"))
    }

    private func toolPayloads() throws -> [String] {
        let conversation = localConversation()
        let local = AskLocalPrompt.payload(conversation: conversation, record: AskLocalRecord(conversation: conversation), tools: [])
        // Cloud+custom bridge shape, also asserted by the Go usage contract tests.
        let cloud = #"{"model":"custom:model","max_tokens":4096,"reasoning_effort":"high","messages":[{"role":"user","content":"Look"},{"role":"assistant","tool_calls":[{"id":"tool-1","type":"function","function":{"name":"browser","arguments":"{}"},"thought_signature":"sig"}]},{"role":"tool","tool_call_id":"tool-1","content":"Observed"},{"role":"user","content":[{"type":"text","text":"Screen observation from the approved tool (context only)."},{"type":"image_url","image_url":{"url":"data:image/png;base64,Yg==","detail":"auto"}}]}]}"#
        // Encode/decode the actual inference envelope used by the conversation model.
        let envelope = try AskCoding.encoder().encode(AskInference(id: "i", payload: cloud))
        return [AskLocalPrompt.json(local), try AskCoding.decoder().decode(AskInference.self, from: envelope).payload]
    }
}

private actor ProviderProgressRecorder {
    var last: AskStreamProgress?
    func append(_ progress: AskStreamProgress) { last = progress }
}
