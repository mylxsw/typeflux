import XCTest
@testable import Typeflux

// MARK: - MockLLMMultiTurnService

final class MockLLMMultiTurnService: LLMMultiTurnService, @unchecked Sendable {
    var turns: [AgentTurn] = []
    private var callCount = 0

    func complete(
        messages: [AgentMessage],
        tools: [LLMAgentTool],
        config: LLMCallConfig
    ) async throws -> AgentTurn {
        guard callCount < turns.count else {
            return .text("fallback")
        }
        let turn = turns[callCount]
        callCount += 1
        return turn
    }

    var totalCalls: Int { callCount }
}

// MARK: - Tests

final class AgentLoopTests: XCTestCase {

    func testTerminatesOnPureTextResponse() async throws {
        let mockLLM = MockLLMMultiTurnService()
        mockLLM.turns = [.text("The answer is 42")]

        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        guard case .text(let text) = result.outcome else {
            XCTFail("Expected text outcome")
            return
        }
        XCTAssertEqual(text, "The answer is 42")
        XCTAssertEqual(result.steps.count, 0)
    }

    func testTerminatesOnAnswerTextTool() async throws {
        let mockLLM = MockLLMMultiTurnService()
        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "1", name: "answer_text", argumentsJSON: #"{"answer":"42"}"#)])
        ]

        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        guard case .terminationTool(let name, _) = result.outcome else {
            XCTFail("Expected terminationTool outcome")
            return
        }
        XCTAssertEqual(name, "answer_text")
        XCTAssertEqual(result.steps.count, 1)
    }

    func testTerminatesOnEditTextTool() async throws {
        let mockLLM = MockLLMMultiTurnService()
        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "1", name: "edit_text", argumentsJSON: #"{"replacement":"new text"}"#)])
        ]

        let registry = AgentToolRegistry()
        await registry.register(EditTextTool())

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        guard case .terminationTool(let name, let args) = result.outcome else {
            XCTFail("Expected terminationTool outcome")
            return
        }
        XCTAssertEqual(name, "edit_text")
        XCTAssertTrue(args.contains("new text"))
    }

    func testMaxStepsLimit() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "some text"
        // Always return get_clipboard (non-termination) tool call
        mockLLM.turns = Array(
            repeating: .toolCalls([AgentToolCall(id: "1", name: "get_clipboard", argumentsJSON: "{}")]),
            count: 20
        )

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))

        let config = AgentConfig(maxSteps: 3, allowParallelToolCalls: false, temperature: nil, enableStreaming: false)
        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: config)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        guard case .maxStepsReached = result.outcome else {
            XCTFail("Expected maxStepsReached outcome, got \(result.outcome)")
            return
        }
        XCTAssertEqual(result.steps.count, 3)
    }

    func testIntermediateToolCallsAccumulateSteps() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "clipboard content"

        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "c1", name: "get_clipboard", argumentsJSON: "{}")]),
            .toolCalls([AgentToolCall(id: "a1", name: "answer_text", argumentsJSON: #"{"answer":"done"}"#)]),
        ]

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        await registry.register(AnswerTextTool())

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        // Step 1: get_clipboard, Step 2: answer_text (termination)
        XCTAssertEqual(result.steps.count, 2)
        guard case .terminationTool(let name, _) = result.outcome else {
            XCTFail("Expected terminationTool")
            return
        }
        XCTAssertEqual(name, "answer_text")
    }

    func testTextWithToolCallsHandled() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "text"

        mockLLM.turns = [
            .textWithToolCalls(
                text: "Let me check...",
                toolCalls: [AgentToolCall(id: "c1", name: "get_clipboard", argumentsJSON: "{}")]
            ),
            .toolCalls([AgentToolCall(id: "a1", name: "answer_text", argumentsJSON: #"{"answer":"found"}"#)]),
        ]

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        await registry.register(AnswerTextTool())

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        guard case .terminationTool = result.outcome else {
            XCTFail("Expected terminationTool")
            return
        }
    }

    func testStreamHandlerCalledOnTextTurn() async throws {
        let mockLLM = MockLLMMultiTurnService()
        mockLLM.turns = [.text("Hello world")]

        let registry = AgentToolRegistry()
        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)

        var streamedText = ""
        _ = try await loop.run(messages: [.user("hi")]) { chunk in
            streamedText += chunk
        }
        XCTAssertEqual(streamedText, "Hello world")
    }

    func testStepMonitorReceivesCallbacks() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "text"

        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "c1", name: "get_clipboard", argumentsJSON: "{}")]),
            .toolCalls([AgentToolCall(id: "a1", name: "answer_text", argumentsJSON: #"{"answer":"x"}"#)]),
        ]

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))
        await registry.register(AnswerTextTool())

        let monitor = MockAgentStepMonitor()
        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        await loop.setStepMonitor(monitor)

        _ = try await loop.run(messages: [.system("sys"), .user("user")])

        XCTAssertEqual(monitor.completedSteps.count, 2)
        XCTAssertNotNil(monitor.finishedOutcome)
    }

    func testAgentResultAnswerText() throws {
        let result = AgentResult(
            outcome: .terminationTool(name: "answer_text", argumentsJSON: #"{"answer":"Hello"}"#),
            steps: [],
            totalDurationMs: 100
        )
        XCTAssertEqual(result.answerText, "Hello")
        XCTAssertNil(result.editedText)
    }

    func testAgentResultEditedText() throws {
        let result = AgentResult(
            outcome: .terminationTool(name: "edit_text", argumentsJSON: #"{"replacement":"New content"}"#),
            steps: [],
            totalDurationMs: 100
        )
        XCTAssertEqual(result.editedText, "New content")
        XCTAssertNil(result.answerText)
    }

    func testAgentResultTextOutcome() throws {
        let result = AgentResult(
            outcome: .text("Plain answer"),
            steps: [],
            totalDurationMs: 50
        )
        XCTAssertEqual(result.answerText, "Plain answer")
        XCTAssertNil(result.editedText)
    }

    func testTextWithToolCallsPreservesTextInStep() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "clip"

        mockLLM.turns = [
            .textWithToolCalls(
                text: "Let me look at clipboard...",
                toolCalls: [AgentToolCall(id: "c1", name: "get_clipboard", argumentsJSON: "{}")]
            ),
            .text("Done"),
        ]

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps[0].assistantMessage.text, "Let me look at clipboard...")
        XCTAssertEqual(result.steps[0].assistantMessage.toolCalls.count, 1)
    }

    func testParallelToolExecutionPreservesOrder() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let clipboard = MockClipboardService()
        clipboard.storedText = "data"

        // Multiple non-termination tool calls in one turn
        mockLLM.turns = [
            .toolCalls([
                AgentToolCall(id: "c1", name: "get_clipboard", argumentsJSON: "{}"),
                AgentToolCall(id: "c2", name: "get_clipboard", argumentsJSON: "{}"),
                AgentToolCall(id: "c3", name: "get_clipboard", argumentsJSON: "{}"),
            ]),
            .text("done"),
        ]

        let registry = AgentToolRegistry()
        await registry.register(GetClipboardTool(clipboardService: clipboard))

        let config = AgentConfig(maxSteps: 10, allowParallelToolCalls: true, temperature: nil, enableStreaming: false)
        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: config)
        let result = try await loop.run(messages: [.system("sys"), .user("user")])

        // Verify results are in same order as calls
        XCTAssertEqual(result.steps.count, 1)
        let step = result.steps[0]
        XCTAssertEqual(step.toolResults.count, 3)
        XCTAssertEqual(step.toolResults[0].toolCallId, "c1")
        XCTAssertEqual(step.toolResults[1].toolCallId, "c2")
        XCTAssertEqual(step.toolResults[2].toolCallId, "c3")
    }
}

// MARK: - MockAgentStepMonitor

final class MockAgentStepMonitor: AgentStepMonitor, @unchecked Sendable {
    var completedSteps: [AgentStep] = []
    var finishedOutcome: AgentOutcome?

    func agentDidCompleteStep(_ step: AgentStep) async {
        completedSteps.append(step)
    }

    func agentDidFinish(outcome: AgentOutcome) async {
        finishedOutcome = outcome
    }
}

// MARK: - Extended AgentLoop tests

extension AgentLoopTests {

    func testLoopStepsAreCounted() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let registry = AgentToolRegistry()
        let stubTool = StubAgentTool(
            name: "search",
            description: "Searches",
            result: "results found"
        )
        await registry.register(stubTool)
        await registry.register(AnswerTextTool())

        // Tool call -> text response
        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "tc1", name: "search", argumentsJSON: #"{"query":"test"}"#)]),
            .toolCalls([AgentToolCall(id: "tc2", name: BuiltinAgentToolName.answerText.rawValue, argumentsJSON: #"{"answer":"done"}"#)])
        ]

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.user("search for test")])

        XCTAssertEqual(result.steps.count, 2)
    }

    func testLoopConfigAllowsCustomMaxSteps() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())

        // Each turn returns a tool call (stub), which will hit max steps
        let stubTool = StubAgentTool(
            name: "stub",
            description: "Stub",
            result: "ok"
        )
        await registry.register(stubTool)

        // Provide only tool call turns (no termination) - should hit maxSteps
        mockLLM.turns = [
            .toolCalls([AgentToolCall(id: "tc1", name: "stub", argumentsJSON: "{}")]),
            .toolCalls([AgentToolCall(id: "tc2", name: "stub", argumentsJSON: "{}")]),
            .toolCalls([AgentToolCall(id: "tc3", name: "stub", argumentsJSON: "{}")]),
        ]

        let config = AgentConfig(maxSteps: 2, allowParallelToolCalls: false, temperature: nil, enableStreaming: false)
        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: config)
        let result = try await loop.run(messages: [.user("do things")])

        // Should terminate with maxStepsReached
        guard case .maxStepsReached = result.outcome else {
            XCTFail("Expected maxStepsReached outcome")
            return
        }
    }

    func testLoopHandlesTextWithToolCallsTurn() async throws {
        let mockLLM = MockLLMMultiTurnService()
        let registry = AgentToolRegistry()
        await registry.register(AnswerTextTool())

        let stubTool = StubAgentTool(
            name: "info",
            description: "Info tool",
            result: "information"
        )
        await registry.register(stubTool)

        mockLLM.turns = [
            .textWithToolCalls(
                text: "Let me look that up...",
                toolCalls: [AgentToolCall(id: "tc1", name: "info", argumentsJSON: "{}")]
            ),
            .text("Here is the answer.")
        ]

        let loop = AgentLoop(llmService: mockLLM, toolRegistry: registry, config: .default)
        let result = try await loop.run(messages: [.user("what is X?")])

        guard case .text(let text) = result.outcome else {
            XCTFail("Expected text outcome")
            return
        }
        XCTAssertEqual(text, "Let me look that up...Here is the answer.")
        XCTAssertEqual(result.steps.count, 1)
    }
}

// MARK: - Helper for extended tests

private struct StubAgentTool: AgentTool {
    let definition: LLMAgentTool
    let result: String

    init(name: String, description: String, result: String) {
        self.definition = LLMAgentTool(
            name: name,
            description: description,
            inputSchema: LLMJSONSchema(
                name: name,
                schema: ["type": .string("object"), "properties": .object([:])],
                strict: false
            )
        )
        self.result = result
    }

    func execute(arguments: String) async throws -> String {
        return #"{"result": "\#(result)"}"#
    }
}
