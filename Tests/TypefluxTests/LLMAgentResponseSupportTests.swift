import XCTest
@testable import Typeflux

final class LLMAgentResponseSupportTests: XCTestCase {
    private let tool = LLMAgentTool(
        name: "answer_or_edit_selection",
        description: "Decide whether to answer or edit.",
        inputSchema: AskSelectionDecision.schema
    )

    func testOpenAICompatibleToolBodyForcesSpecificTool() throws {
        let body = LLMAgentResponseSupport.openAICompatibleToolBody(
            model: "gpt-4o-mini",
            systemPrompt: "system",
            userPrompt: "user",
            tools: [tool],
            forcedToolName: tool.name
        )

        let toolChoice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        let function = try XCTUnwrap(toolChoice["function"] as? [String: String])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])

        XCTAssertEqual(function["name"], tool.name)
        XCTAssertEqual(tools.count, 1)
    }

    func testAnthropicToolBodyIncludesInputSchemaAndForcedChoice() throws {
        let body = LLMAgentResponseSupport.anthropicToolBody(
            model: "claude-sonnet-4",
            systemPrompt: "system",
            userPrompt: "user",
            tools: [tool],
            forcedToolName: tool.name
        )

        let toolChoice = try XCTUnwrap(body["tool_choice"] as? [String: String])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let inputSchema = try XCTUnwrap(tools.first?["input_schema"] as? [String: Any])

        XCTAssertEqual(toolChoice["type"], "tool")
        XCTAssertEqual(toolChoice["name"], tool.name)
        XCTAssertEqual(inputSchema["type"] as? String, "object")
    }

    func testGeminiToolBodyRestrictsAllowedFunctionNames() throws {
        let body = LLMAgentResponseSupport.geminiToolBody(
            systemPrompt: "system",
            userPrompt: "user",
            tools: [tool],
            forcedToolName: tool.name
        )

        let toolConfig = try XCTUnwrap(body["toolConfig"] as? [String: Any])
        let functionCallingConfig = try XCTUnwrap(toolConfig["functionCallingConfig"] as? [String: Any])
        let names = try XCTUnwrap(functionCallingConfig["allowedFunctionNames"] as? [String])

        XCTAssertEqual(functionCallingConfig["mode"] as? String, "ANY")
        XCTAssertEqual(names, [tool.name])
    }

    func testExtractOpenAICompatibleToolCall() throws {
        let data = try jsonData([
            "choices": [
                [
                    "message": [
                        "tool_calls": [
                            [
                                "function": [
                                    "name": "answer_or_edit_selection",
                                    "arguments": #"{"answer_edit":"answer","content":"done"}"#
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let toolCall = LLMAgentResponseSupport.extractOpenAICompatibleToolCall(from: data)

        XCTAssertEqual(
            toolCall,
            LLMAgentToolCall(
                name: "answer_or_edit_selection",
                argumentsJSON: #"{"answer_edit":"answer","content":"done"}"#
            )
        )
    }

    func testExtractAnthropicToolCall() throws {
        let data = try jsonData([
            "content": [
                [
                    "type": "tool_use",
                    "name": "answer_or_edit_selection",
                    "input": [
                        "answer_edit": "edit",
                        "content": "rewritten text"
                    ]
                ]
            ]
        ])

        let toolCall = try XCTUnwrap(LLMAgentResponseSupport.extractAnthropicToolCall(from: data))
        let decision = try JSONDecoder().decode(AskSelectionDecision.self, from: Data(toolCall.argumentsJSON.utf8))

        XCTAssertEqual(toolCall.name, "answer_or_edit_selection")
        XCTAssertEqual(decision, AskSelectionDecision(answerEdit: .edit, content: "rewritten text"))
    }

    func testExtractGeminiToolCall() throws {
        let data = try jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            [
                                "functionCall": [
                                    "name": "answer_or_edit_selection",
                                    "args": [
                                        "answer_edit": "answer",
                                        "content": "done"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        let toolCall = try XCTUnwrap(LLMAgentResponseSupport.extractGeminiToolCall(from: data))
        let decision = try JSONDecoder().decode(AskSelectionDecision.self, from: Data(toolCall.argumentsJSON.utf8))

        XCTAssertEqual(toolCall.name, "answer_or_edit_selection")
        XCTAssertEqual(decision, AskSelectionDecision(answerEdit: .answer, content: "done"))
    }

    func testDecodeToolArgumentsRejectsUnexpectedToolName() {
        XCTAssertThrowsError(
            try RemoteAgentClient.decodeToolArguments(
                LLMAgentToolCall(name: "other_tool", argumentsJSON: #"{"answer_edit":"answer","content":"done"}"#),
                expectedToolName: "answer_or_edit_selection",
                as: AskSelectionDecision.self
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMAgentError,
                .unexpectedToolName(expected: "answer_or_edit_selection", actual: "other_tool")
            )
        }
    }

    func testDecodeToolArgumentsRejectsInvalidJSON() {
        XCTAssertThrowsError(
            try RemoteAgentClient.decodeToolArguments(
                LLMAgentToolCall(name: "answer_or_edit_selection", argumentsJSON: "{not-json}"),
                expectedToolName: "answer_or_edit_selection",
                as: AskSelectionDecision.self
            )
        ) { error in
            XCTAssertEqual(error as? LLMAgentError, .invalidToolArguments)
        }
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
