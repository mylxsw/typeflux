@testable import Typeflux
import XCTest

/// Tests for the turn-parsing methods exposed on OpenAICompatibleAgentService+LLMMultiTurnService.
/// The methods (parseOpenAITurn, parseAnthropicTurn, parseGeminiTurn, buildOpenAIBody) are internal,
/// accessible via @testable import.
final class LLMMultiTurnServiceOpenAIParsingTests: XCTestCase {
    // A minimal SettingsStore backed by an isolated UserDefaults suite.
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: OpenAICompatibleAgentService!

    override func setUp() {
        super.setUp()
        suiteName = "LLMMultiTurnParsingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        service = OpenAICompatibleAgentService(settingsStore: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - parseOpenAITurn

    func testParseOpenAITurnReturnsEmptyTextOnInvalidJSON() {
        let result = service.parseOpenAITurn(from: Data("not json".utf8))
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "")
    }

    func testParseOpenAITurnReturnsEmptyTextWhenNoChoices() {
        let data = jsonData(["choices": [] as [[String: Any]]])
        let result = service.parseOpenAITurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "")
    }

    func testParseOpenAITurnReturnsPureTextResponse() {
        let data = jsonData([
            "choices": [
                ["message": ["role": "assistant", "content": "Hello, world!"]],
            ],
        ])
        let result = service.parseOpenAITurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Hello, world!")
    }

    func testParseOpenAITurnReturnsToolCallsOnlyWhenNoText() {
        let data = jsonData([
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                "id": "call_123",
                                "type": "function",
                                "function": [
                                    "name": "get_weather",
                                    "arguments": #"{"location":"NYC"}"#,
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseOpenAITurn(from: data)
        guard case let .toolCalls(calls) = result else {
            XCTFail("Expected .toolCalls, got \(result)")
            return
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "call_123")
        XCTAssertEqual(calls[0].name, "get_weather")
        XCTAssertEqual(calls[0].argumentsJSON, #"{"location":"NYC"}"#)
    }

    func testParseOpenAITurnReturnsTextWithToolCallsWhenBothPresent() {
        let data = jsonData([
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "Let me check that.",
                        "tool_calls": [
                            [
                                "id": "call_456",
                                "type": "function",
                                "function": [
                                    "name": "search",
                                    "arguments": #"{"query":"test"}"#,
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseOpenAITurn(from: data)
        guard case let .textWithToolCalls(text, calls) = result else {
            XCTFail("Expected .textWithToolCalls")
            return
        }
        XCTAssertEqual(text, "Let me check that.")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "search")
    }

    func testParseOpenAITurnGeneratesIDWhenMissing() {
        let data = jsonData([
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                // No "id" field
                                "type": "function",
                                "function": [
                                    "name": "my_tool",
                                    "arguments": #"{}"#,
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseOpenAITurn(from: data)
        guard case let .toolCalls(calls) = result else {
            XCTFail("Expected .toolCalls")
            return
        }
        XCTAssertFalse(calls[0].id.isEmpty)
    }

    func testParseOpenAITurnStripsLeadingThinkingTags() {
        let data = jsonData([
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "<think>reasoning here</think>Final answer",
                    ],
                ],
            ],
        ])
        let result = service.parseOpenAITurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Final answer")
    }

    // MARK: - parseAnthropicTurn

    func testParseAnthropicTurnReturnsEmptyTextOnInvalidJSON() {
        let result = service.parseAnthropicTurn(from: Data("bad".utf8))
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "")
    }

    func testParseAnthropicTurnReturnsTextFromTextBlock() {
        let data = jsonData([
            "content": [
                ["type": "text", "text": "Hello from Claude!"],
            ],
        ])
        let result = service.parseAnthropicTurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Hello from Claude!")
    }

    func testParseAnthropicTurnAccumulatesMultipleTextBlocks() {
        let data = jsonData([
            "content": [
                ["type": "text", "text": "Part 1. "],
                ["type": "text", "text": "Part 2."],
            ],
        ])
        let result = service.parseAnthropicTurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Part 1. Part 2.")
    }

    func testParseAnthropicTurnReturnsToolCallsFromToolUseBlock() {
        let data = jsonData([
            "content": [
                [
                    "type": "tool_use",
                    "id": "tool_abc",
                    "name": "calculator",
                    "input": ["expression": "2+2"],
                ],
            ],
        ])
        let result = service.parseAnthropicTurn(from: data)
        guard case let .toolCalls(calls) = result else {
            XCTFail("Expected .toolCalls")
            return
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "tool_abc")
        XCTAssertEqual(calls[0].name, "calculator")
        XCTAssertTrue(calls[0].argumentsJSON.contains("expression"))
    }

    func testParseAnthropicTurnReturnsTextWithToolCallsWhenMixed() {
        let data = jsonData([
            "content": [
                ["type": "text", "text": "I'll calculate that."],
                [
                    "type": "tool_use",
                    "id": "tool_xyz",
                    "name": "compute",
                    "input": ["x": 42],
                ],
            ],
        ])
        let result = service.parseAnthropicTurn(from: data)
        guard case let .textWithToolCalls(text, calls) = result else {
            XCTFail("Expected .textWithToolCalls")
            return
        }
        XCTAssertEqual(text, "I'll calculate that.")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "compute")
    }

    func testParseAnthropicTurnSkipsInvalidToolUseBlocks() {
        let data = jsonData([
            "content": [
                [
                    "type": "tool_use",
                    // Missing "id" and "name"
                    "input": ["x": 1],
                ],
            ],
        ])
        let result = service.parseAnthropicTurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text (no valid tool calls)")
            return
        }
        XCTAssertEqual(text, "")
    }

    // MARK: - parseGeminiTurn

    func testParseGeminiTurnReturnsEmptyTextOnInvalidJSON() {
        let result = service.parseGeminiTurn(from: Data("nope".utf8))
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "")
    }

    func testParseGeminiTurnReturnsTextFromTextPart() {
        let data = jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": "Gemini says hi!"],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseGeminiTurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Gemini says hi!")
    }

    func testParseGeminiTurnAccumulatesMultipleTextParts() {
        let data = jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": "Hello "],
                            ["text": "World"],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseGeminiTurn(from: data)
        guard case let .text(text) = result else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "Hello World")
    }

    func testParseGeminiTurnReturnsFunctionCallsFromFunctionCallPart() {
        let data = jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            [
                                "functionCall": [
                                    "name": "search_web",
                                    "args": ["query": "Swift testing"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseGeminiTurn(from: data)
        guard case let .toolCalls(calls) = result else {
            XCTFail("Expected .toolCalls")
            return
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "search_web")
        XCTAssertTrue(calls[0].argumentsJSON.contains("query"))
        XCTAssertTrue(calls[0].id.hasPrefix("search_web_"))
    }

    func testParseGeminiTurnReturnsMixedTextAndFunctionCalls() {
        let data = jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": "Searching..."],
                            [
                                "functionCall": [
                                    "name": "lookup",
                                    "args": ["term": "XCTest"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseGeminiTurn(from: data)
        guard case let .textWithToolCalls(text, calls) = result else {
            XCTFail("Expected .textWithToolCalls")
            return
        }
        XCTAssertEqual(text, "Searching...")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "lookup")
    }

    func testParseGeminiTurnUsesFallbackEmptyArgsWhenArgsAreInvalid() {
        // "args" key missing — should default to "{}"
        let data = jsonData([
            "candidates": [
                [
                    "content": [
                        "parts": [
                            [
                                "functionCall": [
                                    "name": "no_args_tool",
                                    // no "args" key
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        let result = service.parseGeminiTurn(from: data)
        guard case let .toolCalls(calls) = result else {
            XCTFail("Expected .toolCalls")
            return
        }
        XCTAssertEqual(calls[0].argumentsJSON, "{}")
    }

    // MARK: - buildOpenAIBody

    func testBuildOpenAIBodyContainsModelAndMessages() {
        let messages: [AgentMessage] = [.system("sys"), .user("hello")]
        let tools: [LLMAgentTool] = []
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: true, temperature: nil)

        let body = service.buildOpenAIBody(model: "gpt-4o", messages: messages, tools: tools, config: config)
        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true)
        let msgArr = body["messages"] as? [[String: Any]]
        XCTAssertEqual(msgArr?.count, 2)
    }

    func testBuildOpenAIBodyIncludesForcedToolChoice() {
        let messages: [AgentMessage] = [.user("go")]
        let tools: [LLMAgentTool] = []
        let config = LLMCallConfig(forcedToolName: "my_tool", parallelToolCalls: false, temperature: nil)

        let body = service.buildOpenAIBody(model: "gpt-4o", messages: messages, tools: tools, config: config)
        let toolChoice = body["tool_choice"] as? [String: Any]
        XCTAssertEqual(toolChoice?["type"] as? String, "function")
        let fn = toolChoice?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "my_tool")
    }

    func testBuildOpenAIBodyIncludesTemperatureWhenSet() {
        let messages: [AgentMessage] = [.user("temp test")]
        let tools: [LLMAgentTool] = []
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: 0.7)

        let body = service.buildOpenAIBody(model: "gpt-4o", messages: messages, tools: tools, config: config)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
    }

    func testBuildOpenAIBodyOmitsTemperatureWhenNil() {
        let messages: [AgentMessage] = [.user("no temp")]
        let tools: [LLMAgentTool] = []
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)

        let body = service.buildOpenAIBody(model: "gpt-4o", messages: messages, tools: tools, config: config)
        XCTAssertNil(body["temperature"])
    }

    func testBuildOpenAIBodyIncludesToolDefinitions() {
        let messages: [AgentMessage] = [.user("use tool")]
        let schema = LLMJSONSchema(name: "get_info", schema: [
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
        ])
        let tools = [LLMAgentTool(name: "get_info", description: "Gets info", inputSchema: schema)]
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: false, temperature: nil)

        let body = service.buildOpenAIBody(model: "gpt-4o", messages: messages, tools: tools, config: config)
        let toolsArr = body["tools"] as? [[String: Any]]
        XCTAssertEqual(toolsArr?.count, 1)
        let firstTool = toolsArr?.first
        XCTAssertEqual(firstTool?["type"] as? String, "function")
        let fn = firstTool?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_info")
        XCTAssertEqual(fn?["description"] as? String, "Gets info")
    }
}
