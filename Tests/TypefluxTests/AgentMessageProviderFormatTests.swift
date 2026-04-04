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

// MARK: - Extended AgentMessage format tests

extension AgentMessageProviderFormatTests {

    // MARK: - extractAnthropicSystemPrompt

    func testExtractAnthropicSystemPromptWithNoSystem() {
        let messages: [AgentMessage] = [.user("hello")]
        let result = AgentMessage.extractAnthropicSystemPrompt(messages)
        XCTAssertNil(result)
    }

    func testExtractAnthropicSystemPromptWithSingleSystem() {
        let messages: [AgentMessage] = [.system("Be helpful."), .user("hello")]
        let result = AgentMessage.extractAnthropicSystemPrompt(messages)
        XCTAssertEqual(result, "Be helpful.")
    }

    func testExtractAnthropicSystemPromptJoinsMultipleSystemMessages() {
        let messages: [AgentMessage] = [
            .system("Rule 1."),
            .user("hello"),
            .system("Rule 2.")
        ]
        let result = AgentMessage.extractAnthropicSystemPrompt(messages)
        XCTAssertEqual(result, "Rule 1.\n\nRule 2.")
    }

    // MARK: - extractGeminiSystemInstruction

    func testExtractGeminiSystemInstructionWithNoSystem() {
        let messages: [AgentMessage] = [.user("hello")]
        let result = AgentMessage.extractGeminiSystemInstruction(messages)
        XCTAssertNil(result)
    }

    func testExtractGeminiSystemInstructionWithSystemMessage() {
        let messages: [AgentMessage] = [.system("Be helpful."), .user("hi")]
        let result = AgentMessage.extractGeminiSystemInstruction(messages)
        XCTAssertNotNil(result)
        let parts = result?["parts"] as? [[String: Any]]
        let textValue = parts?.first?["text"] as? String
        XCTAssertEqual(textValue, "Be helpful.")
    }

    // MARK: - toGeminiContents

    func testGeminiSystemMessagesAreSkipped() {
        let messages: [AgentMessage] = [.system("Skip me."), .user("hello")]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
    }

    func testGeminiUserMessage() {
        let messages: [AgentMessage] = [.user("test")]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = contents[0]["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "test")
    }

    func testGeminiAssistantTextOnlyMessage() {
        let msg = AgentAssistantMessage(text: "Hello!", toolCalls: [])
        let messages: [AgentMessage] = [.assistant(msg)]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "model")
        let parts = contents[0]["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "Hello!")
    }

    func testGeminiAssistantEmptyTextAndNoToolCallsIsSkipped() {
        let msg = AgentAssistantMessage(text: "", toolCalls: [])
        let messages: [AgentMessage] = [.assistant(msg)]
        let contents = AgentMessage.toGeminiContents(messages)
        // Empty parts -> message is skipped
        XCTAssertEqual(contents.count, 0)
    }

    func testGeminiAssistantWithToolCalls() {
        let tc = AgentToolCall(id: "tc1", name: "search", argumentsJSON: #"{"query":"test"}"#)
        let msg = AgentAssistantMessage(text: nil, toolCalls: [tc])
        let messages: [AgentMessage] = [.assistant(msg)]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        let parts = contents[0]["parts"] as? [[String: Any]]
        let functionCall = parts?.first?["functionCall"] as? [String: Any]
        XCTAssertEqual(functionCall?["name"] as? String, "search")
    }

    func testGeminiToolResultMessage() {
        let tr = AgentToolResult(toolCallId: "tc1", content: "result data", isError: false)
        let messages: [AgentMessage] = [.toolResult(tr)]
        let contents = AgentMessage.toGeminiContents(messages)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = contents[0]["parts"] as? [[String: Any]]
        let funcResponse = parts?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(funcResponse?["name"] as? String, "tc1")
    }

    // MARK: - toAnthropicMessages

    func testAnthropicSystemMessagesAreSkipped() {
        let messages: [AgentMessage] = [.system("Skip me."), .user("hello")]
        let result = AgentMessage.toAnthropicMessages(messages)
        // system messages are skipped in Anthropic format
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["role"] as? String, "user")
    }

    func testAnthropicToolResultUsesUserRole() {
        let tr = AgentToolResult(toolCallId: "tc_abc", content: "success", isError: false)
        let messages: [AgentMessage] = [.toolResult(tr)]
        let result = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["role"] as? String, "user")
        let content = result[0]["content"] as? [[String: Any]]
        let first = content?.first
        XCTAssertEqual(first?["type"] as? String, "tool_result")
        XCTAssertEqual(first?["tool_use_id"] as? String, "tc_abc")
    }

    func testAnthropicAssistantWithToolCalls() {
        let tc = AgentToolCall(id: "tc2", name: "calculator", argumentsJSON: #"{"x":2}"#)
        let msg = AgentAssistantMessage(text: "Computing...", toolCalls: [tc])
        let messages: [AgentMessage] = [.assistant(msg)]
        let result = AgentMessage.toAnthropicMessages(messages)
        XCTAssertEqual(result.count, 1)
        let content = result[0]["content"] as? [[String: Any]]
        // text block + tool_use block
        let textBlock = content?.first { $0["type"] as? String == "text" }
        let toolBlock = content?.first { $0["type"] as? String == "tool_use" }
        XCTAssertEqual(textBlock?["text"] as? String, "Computing...")
        XCTAssertEqual(toolBlock?["name"] as? String, "calculator")
    }
}
