import XCTest
@testable import Typeflux

final class AgentMessageProviderFormatTests: XCTestCase {

    // MARK: - OpenAI Format

    func testOpenAISystemMessage() throws {
        let messages: [AgentMessage] = [.system("You are helpful.")]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "system")
        XCTAssertEqual(formatted[0]["content"] as? String, "You are helpful.")
    }

    func testOpenAIUserMessage() throws {
        let messages: [AgentMessage] = [.user("Hello!")]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "user")
        XCTAssertEqual(formatted[0]["content"] as? String, "Hello!")
    }

    func testOpenAIAssistantTextOnly() throws {
        let assistantMsg = AgentAssistantMessage(text: "Hi there", toolCalls: [])
        let messages: [AgentMessage] = [.assistant(assistantMsg)]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "assistant")
        XCTAssertEqual(formatted[0]["content"] as? String, "Hi there")
    }

    func testOpenAIAssistantWithToolCalls() throws {
        let tc = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let assistantMsg = AgentAssistantMessage(text: nil, toolCalls: [tc])
        let messages: [AgentMessage] = [.assistant(assistantMsg)]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "assistant")
        let toolCalls = formatted[0]["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(toolCalls?.count, 1)
        let fn = toolCalls?.first?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_clipboard")
    }

    func testOpenAIToolResultMessage() throws {
        let result = AgentToolResult(toolCallId: "tc1", content: "clipboard data", isError: false)
        let messages: [AgentMessage] = [.toolResult(result)]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "tool")
        XCTAssertEqual(formatted[0]["tool_call_id"] as? String, "tc1")
        XCTAssertEqual(formatted[0]["content"] as? String, "clipboard data")
    }

    func testOpenAIMultiTurnConversation() throws {
        let tc = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("user input"),
            .assistant(AgentAssistantMessage(text: nil, toolCalls: [tc])),
            .toolResult(AgentToolResult(toolCallId: "tc1", content: "result", isError: false)),
        ]
        let formatted = AgentMessage.toOpenAIMessages(messages)
        XCTAssertEqual(formatted.count, 4)
        XCTAssertEqual(formatted[0]["role"] as? String, "system")
        XCTAssertEqual(formatted[1]["role"] as? String, "user")
        XCTAssertEqual(formatted[2]["role"] as? String, "assistant")
        XCTAssertEqual(formatted[3]["role"] as? String, "tool")
    }

    // MARK: - Anthropic Format

    func testAnthropicSystemExtracted() throws {
        let messages: [AgentMessage] = [
            .system("You are helpful."),
            .user("Hello!"),
        ]
        let system = AgentMessage.extractAnthropicSystemPrompt(messages)
        XCTAssertEqual(system, "You are helpful.")
    }

    func testAnthropicSystemExcludedFromMessages() throws {
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("Hello!"),
        ]
        let formatted = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "user")
    }

    func testAnthropicUserMessage() throws {
        let messages: [AgentMessage] = [.user("Hello!")]
        let formatted = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "user")
        let content = formatted[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertEqual(content?.first?["text"] as? String, "Hello!")
    }

    func testAnthropicAssistantWithToolUse() throws {
        let tc = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let assistantMsg = AgentAssistantMessage(text: nil, toolCalls: [tc])
        let messages: [AgentMessage] = [.assistant(assistantMsg)]
        let formatted = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "assistant")
        let content = formatted[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "tool_use")
        XCTAssertEqual(content?.first?["name"] as? String, "get_clipboard")
    }

    func testAnthropicToolResult() throws {
        let result = AgentToolResult(toolCallId: "tc1", content: "data", isError: false)
        let messages: [AgentMessage] = [.toolResult(result)]
        let formatted = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(formatted.count, 1)
        XCTAssertEqual(formatted[0]["role"] as? String, "user")
        let content = formatted[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(content?.first?["tool_use_id"] as? String, "tc1")
    }

    // MARK: - Gemini Format

    func testGeminiSystemExtracted() throws {
        let messages: [AgentMessage] = [.system("You are helpful.")]
        let instruction = AgentMessage.extractGeminiSystemInstruction(messages)
        XCTAssertNotNil(instruction)
        let parts = instruction?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "You are helpful.")
    }

    func testGeminiSystemExcludedFromContents() throws {
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("Hello!"),
        ]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
    }

    func testGeminiUserMessage() throws {
        let messages: [AgentMessage] = [.user("Hello!")]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = contents[0]["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "Hello!")
    }

    func testGeminiAssistantWithFunctionCall() throws {
        let tc = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let assistantMsg = AgentAssistantMessage(text: nil, toolCalls: [tc])
        let messages: [AgentMessage] = [.assistant(assistantMsg)]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "model")
        let parts = contents[0]["parts"] as? [[String: Any]]
        let functionCall = parts?.first?["functionCall"] as? [String: Any]
        XCTAssertEqual(functionCall?["name"] as? String, "get_clipboard")
    }
}
