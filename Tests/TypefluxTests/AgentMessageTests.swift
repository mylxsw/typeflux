import XCTest
@testable import Typeflux

final class AgentMessageTests: XCTestCase {

    func testSystemMessage() {
        let msg = AgentMessage.system("You are helpful.")
        if case .system(let text) = msg {
            XCTAssertEqual(text, "You are helpful.")
        } else {
            XCTFail("Expected system message")
        }
    }

    func testUserMessage() {
        let msg = AgentMessage.user("Hello!")
        if case .user(let text) = msg {
            XCTAssertEqual(text, "Hello!")
        } else {
            XCTFail("Expected user message")
        }
    }

    func testAssistantMessageTextOnly() {
        let assistantMsg = AgentAssistantMessage(text: "Hi there", toolCalls: [])
        let msg = AgentMessage.assistant(assistantMsg)
        if case .assistant(let m) = msg {
            XCTAssertEqual(m.text, "Hi there")
            XCTAssertTrue(m.toolCalls.isEmpty)
        } else {
            XCTFail("Expected assistant message")
        }
    }

    func testAssistantMessageWithToolCalls() {
        let toolCall = AgentToolCall(id: "tc1", name: "get_clipboard", argumentsJSON: "{}")
        let assistantMsg = AgentAssistantMessage(text: nil, toolCalls: [toolCall])
        let msg = AgentMessage.assistant(assistantMsg)
        if case .assistant(let m) = msg {
            XCTAssertNil(m.text)
            XCTAssertEqual(m.toolCalls.count, 1)
            XCTAssertEqual(m.toolCalls[0].name, "get_clipboard")
        } else {
            XCTFail("Expected assistant message")
        }
    }

    func testToolResultMessage() {
        let result = AgentToolResult(toolCallId: "tc1", content: "clipboard content", isError: false)
        let msg = AgentMessage.toolResult(result)
        if case .toolResult(let r) = msg {
            XCTAssertEqual(r.toolCallId, "tc1")
            XCTAssertEqual(r.content, "clipboard content")
            XCTAssertFalse(r.isError)
        } else {
            XCTFail("Expected toolResult message")
        }
    }

    func testAgentToolCallEquality() {
        let tc1 = AgentToolCall(id: "1", name: "tool", argumentsJSON: "{}")
        let tc2 = AgentToolCall(id: "1", name: "tool", argumentsJSON: "{}")
        let tc3 = AgentToolCall(id: "2", name: "tool", argumentsJSON: "{}")
        XCTAssertEqual(tc1, tc2)
        XCTAssertNotEqual(tc1, tc3)
    }

    func testAgentToolResultEquality() {
        let r1 = AgentToolResult(toolCallId: "tc1", content: "ok", isError: false)
        let r2 = AgentToolResult(toolCallId: "tc1", content: "ok", isError: false)
        let r3 = AgentToolResult(toolCallId: "tc1", content: "ok", isError: true)
        XCTAssertEqual(r1, r2)
        XCTAssertNotEqual(r1, r3)
    }

    func testAgentToolCallCodable() throws {
        let tc = AgentToolCall(id: "abc", name: "my_tool", argumentsJSON: #"{"key":"val"}"#)
        let data = try JSONEncoder().encode(tc)
        let decoded = try JSONDecoder().decode(AgentToolCall.self, from: data)
        XCTAssertEqual(tc, decoded)
    }

    func testAgentMessageEquality() {
        XCTAssertEqual(AgentMessage.system("a"), AgentMessage.system("a"))
        XCTAssertNotEqual(AgentMessage.system("a"), AgentMessage.system("b"))
        XCTAssertNotEqual(AgentMessage.system("a"), AgentMessage.user("a"))
    }
}
