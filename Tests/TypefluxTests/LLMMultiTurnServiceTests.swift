import XCTest
@testable import Typeflux

final class LLMMultiTurnServiceTests: XCTestCase {

    // MARK: - AgentTurn

    func testAgentTurnTextCase() {
        let turn = AgentTurn.text("Hello")
        if case .text(let t) = turn {
            XCTAssertEqual(t, "Hello")
        } else {
            XCTFail("Expected text case")
        }
    }

    func testAgentTurnToolCallsCase() {
        let tc = AgentToolCall(id: "1", name: "tool", argumentsJSON: "{}")
        let turn = AgentTurn.toolCalls([tc])
        if case .toolCalls(let calls) = turn {
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].name, "tool")
        } else {
            XCTFail("Expected toolCalls case")
        }
    }

    func testAgentTurnTextWithToolCallsCase() {
        let tc = AgentToolCall(id: "1", name: "tool", argumentsJSON: "{}")
        let turn = AgentTurn.textWithToolCalls(text: "thinking", toolCalls: [tc])
        if case .textWithToolCalls(let text, let calls) = turn {
            XCTAssertEqual(text, "thinking")
            XCTAssertEqual(calls.count, 1)
        } else {
            XCTFail("Expected textWithToolCalls case")
        }
    }

    // MARK: - LLMCallConfig

    func testLLMCallConfigDefaults() {
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)
        XCTAssertNil(config.forcedToolName)
        XCTAssertFalse(config.parallelToolCalls)
        XCTAssertNil(config.temperature)
    }

    func testLLMCallConfigCustomValues() {
        let config = LLMCallConfig(forcedToolName: "answer_text", parallelToolCalls: true, temperature: 0.5)
        XCTAssertEqual(config.forcedToolName, "answer_text")
        XCTAssertTrue(config.parallelToolCalls)
        XCTAssertEqual(config.temperature, 0.5)
    }

    // MARK: - MockLLMMultiTurnService behavior

    func testMockServiceReturnsTurnsInOrder() async throws {
        let mock = MockLLMMultiTurnService()
        mock.turns = [.text("first"), .text("second")]
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)

        let result1 = try await mock.complete(messages: [], tools: [], config: config)
        let result2 = try await mock.complete(messages: [], tools: [], config: config)

        if case .text(let t1) = result1.turn, case .text(let t2) = result2.turn {
            XCTAssertEqual(t1, "first")
            XCTAssertEqual(t2, "second")
        } else {
            XCTFail("Expected text turns")
        }
    }

    func testMockServiceFallsBackOnExhaustedTurns() async throws {
        let mock = MockLLMMultiTurnService()
        mock.turns = [.text("only")]
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)

        _ = try await mock.complete(messages: [], tools: [], config: config)
        let fallback = try await mock.complete(messages: [], tools: [], config: config)

        if case .text(let t) = fallback.turn {
            XCTAssertEqual(t, "fallback")
        } else {
            XCTFail("Expected fallback text")
        }
    }

    func testMockServiceTracksCallCount() async throws {
        let mock = MockLLMMultiTurnService()
        mock.turns = [.text("a"), .text("b")]
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)

        XCTAssertEqual(mock.totalCalls, 0)
        _ = try await mock.complete(messages: [], tools: [], config: config)
        XCTAssertEqual(mock.totalCalls, 1)
        _ = try await mock.complete(messages: [], tools: [], config: config)
        XCTAssertEqual(mock.totalCalls, 2)
    }

    // MARK: - OpenAI body building (through AgentLoop integration)

    func testOpenAIMessagesIncludeAllRoles() throws {
        let tc = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let messages: [AgentMessage] = [
            .system("system prompt"),
            .user("user input"),
            .assistant(AgentAssistantMessage(text: "let me check", toolCalls: [tc])),
            .toolResult(AgentToolResult(toolCallId: "tc1", content: "clipboard data", isError: false)),
            .assistant(AgentAssistantMessage(text: "Here is the result", toolCalls: [])),
        ]

        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 5)

        let roles = formatted.map { $0["role"] as? String }
        XCTAssertEqual(roles, ["system", "user", "assistant", "tool", "assistant"])

        // Verify assistant with tool calls has both content and tool_calls
        let assistantWithTools = formatted[2]
        XCTAssertEqual(assistantWithTools["content"] as? String, "let me check")
        XCTAssertNotNil(assistantWithTools["tool_calls"])
    }

    func testAnthropicMessagesUseContentBlocks() throws {
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("Hello"),
        ]
        let formatted = AgentMessage.toAnthropicMessages(messages)
        // system should be excluded
        XCTAssertEqual(formatted.count, 1)

        let userMsg = formatted[0]
        XCTAssertEqual(userMsg["role"] as? String, "user")
        let content = userMsg["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
    }

    func testGeminiContentsUseModelRole() throws {
        let messages: [AgentMessage] = [
            .user("Hello"),
            .assistant(AgentAssistantMessage(text: "Hi", toolCalls: [])),
        ]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual(contents[1]["role"] as? String, "model")
    }
}
