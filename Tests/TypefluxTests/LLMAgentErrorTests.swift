import XCTest
@testable import Typeflux

final class LLMAgentErrorTests: XCTestCase {

    func testUnsupportedProviderDescription() {
        let error = LLMAgentError.unsupportedProvider
        XCTAssertTrue(error.errorDescription?.contains("does not support agent tool calls") ?? false)
    }

    func testNoToolsConfiguredDescription() {
        let error = LLMAgentError.noToolsConfigured
        XCTAssertTrue(error.errorDescription?.contains("No agent tools") ?? false)
    }

    func testMissingToolCallDescription() {
        let error = LLMAgentError.missingToolCall
        XCTAssertTrue(error.errorDescription?.contains("did not return a tool call") ?? false)
    }

    func testUnexpectedToolNameWithExpected() {
        let error = LLMAgentError.unexpectedToolName(expected: "answer_text", actual: "edit_text")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("edit_text"))
        XCTAssertTrue(desc.contains("answer_text"))
    }

    func testUnexpectedToolNameWithoutExpected() {
        let error = LLMAgentError.unexpectedToolName(expected: nil, actual: "unknown_tool")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("unknown_tool"))
        XCTAssertFalse(desc.contains("expected '"))
    }

    func testInvalidToolArgumentsDescription() {
        let error = LLMAgentError.invalidToolArguments
        XCTAssertTrue(error.errorDescription?.contains("invalid tool arguments") ?? false)
    }

    func testEquality() {
        XCTAssertEqual(LLMAgentError.unsupportedProvider, LLMAgentError.unsupportedProvider)
        XCTAssertEqual(LLMAgentError.missingToolCall, LLMAgentError.missingToolCall)
        XCTAssertNotEqual(LLMAgentError.unsupportedProvider, LLMAgentError.missingToolCall)
        XCTAssertEqual(
            LLMAgentError.unexpectedToolName(expected: "a", actual: "b"),
            LLMAgentError.unexpectedToolName(expected: "a", actual: "b")
        )
        XCTAssertNotEqual(
            LLMAgentError.unexpectedToolName(expected: "a", actual: "b"),
            LLMAgentError.unexpectedToolName(expected: "a", actual: "c")
        )
    }

    // MARK: - LLMAgentTool

    func testLLMAgentToolCreation() {
        let tool = LLMAgentTool(
            name: "test_tool",
            description: "A test tool",
            inputSchema: LLMJSONSchema(name: "test", schema: [:])
        )
        XCTAssertEqual(tool.name, "test_tool")
        XCTAssertEqual(tool.description, "A test tool")
    }

    // MARK: - LLMAgentRequest

    func testLLMAgentRequestDefaults() {
        let request = LLMAgentRequest(
            systemPrompt: "system",
            userPrompt: "user",
            tools: []
        )
        XCTAssertNil(request.forcedToolName)
        XCTAssertEqual(request.systemPrompt, "system")
        XCTAssertEqual(request.userPrompt, "user")
        XCTAssertTrue(request.tools.isEmpty)
    }

    func testLLMAgentRequestWithForcedTool() {
        let request = LLMAgentRequest(
            systemPrompt: "sys",
            userPrompt: "usr",
            tools: [],
            forcedToolName: "answer_text"
        )
        XCTAssertEqual(request.forcedToolName, "answer_text")
    }
}
