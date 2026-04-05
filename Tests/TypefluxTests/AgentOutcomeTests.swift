import XCTest
@testable import Typeflux

final class AgentOutcomeTests: XCTestCase {

    // MARK: - AgentOutcome

    func testTextOutcome() {
        let outcome = AgentOutcome.text("Hello")
        if case .text(let text) = outcome {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .text outcome")
        }
    }

    func testTerminationToolOutcome() {
        let outcome = AgentOutcome.terminationTool(name: "answer_text", argumentsJSON: "{}")
        if case .terminationTool(let name, let args) = outcome {
            XCTAssertEqual(name, "answer_text")
            XCTAssertEqual(args, "{}")
        } else {
            XCTFail("Expected .terminationTool outcome")
        }
    }

    func testMaxStepsReachedOutcome() {
        let outcome = AgentOutcome.maxStepsReached
        if case .maxStepsReached = outcome {
            // pass
        } else {
            XCTFail("Expected .maxStepsReached outcome")
        }
    }

    func testErrorOutcome() {
        struct TestError: Error {}
        let outcome = AgentOutcome.error(TestError())
        if case .error(let error) = outcome {
            XCTAssertTrue(error is TestError)
        } else {
            XCTFail("Expected .error outcome")
        }
    }

    // MARK: - AgentRealtimeState

    func testRealtimeStateProperties() {
        let state = AgentRealtimeState(
            currentStep: 3,
            lastToolCall: nil,
            accumulatedText: "thinking...",
            toolCallsSoFar: []
        )
        XCTAssertEqual(state.currentStep, 3)
        XCTAssertNil(state.lastToolCall)
        XCTAssertEqual(state.accumulatedText, "thinking...")
        XCTAssertTrue(state.toolCallsSoFar.isEmpty)
    }

    // MARK: - BuiltinAgentToolName

    func testBuiltinToolNameRawValues() {
        XCTAssertEqual(BuiltinAgentToolName.answerText.rawValue, "answer_text")
        XCTAssertEqual(BuiltinAgentToolName.editText.rawValue, "edit_text")
        XCTAssertEqual(BuiltinAgentToolName.getClipboard.rawValue, "get_clipboard")
    }

    func testBuiltinToolNameCaseIterable() {
        XCTAssertEqual(BuiltinAgentToolName.allCases.count, 3)
    }

    // MARK: - AgentError (additional coverage beyond MCPToolAdapterTests)

    func testAgentErrorMaxStepsDescription() {
        let error = AgentError.maxStepsExceeded
        XCTAssertTrue(error.errorDescription?.contains("maximum execution steps") ?? false)
    }

    func testAgentErrorToolNotFound() {
        let error = AgentError.toolNotFound(name: "missing_tool")
        XCTAssertTrue(error.errorDescription?.contains("missing_tool") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("not found") ?? false)
    }

    func testAgentErrorToolExecutionFailed() {
        let error = AgentError.toolExecutionFailed(name: "test_tool", reason: "timeout")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("test_tool"))
        XCTAssertTrue(desc.contains("timeout"))
    }

    func testAgentErrorMCPConnectionFailed() {
        let error = AgentError.mcpConnectionFailed(serverName: "myserver", reason: "refused")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("myserver"))
        XCTAssertTrue(desc.contains("refused"))
    }

    func testAgentErrorMCPServerNotFound() {
        let id = UUID()
        let error = AgentError.mcpServerNotFound(id: id)
        XCTAssertTrue(error.errorDescription?.contains(id.uuidString) ?? false)
    }

    func testAgentErrorInvalidState() {
        let error = AgentError.invalidAgentState(reason: "no tools")
        XCTAssertTrue(error.errorDescription?.contains("no tools") ?? false)
    }

    func testAgentErrorLLMConnectionFailed() {
        let error = AgentError.llmConnectionFailed(reason: "network timeout")
        XCTAssertTrue(error.errorDescription?.contains("network timeout") ?? false)
    }

    func testAgentErrorEquatable() {
        XCTAssertEqual(AgentError.maxStepsExceeded, AgentError.maxStepsExceeded)
        XCTAssertNotEqual(AgentError.maxStepsExceeded, AgentError.toolNotFound(name: "x"))
        XCTAssertEqual(
            AgentError.toolNotFound(name: "a"),
            AgentError.toolNotFound(name: "a")
        )
        XCTAssertNotEqual(
            AgentError.toolNotFound(name: "a"),
            AgentError.toolNotFound(name: "b")
        )
    }

    // MARK: - LLMRewriteRequest

    func testRewriteRequestEditSelectionMode() {
        let request = LLMRewriteRequest(
            mode: .editSelection,
            sourceText: "original",
            spokenInstruction: "make it better",
            personaPrompt: "formal"
        )
        if case .editSelection = request.mode {} else { XCTFail("Expected editSelection") }
        XCTAssertEqual(request.sourceText, "original")
        XCTAssertEqual(request.spokenInstruction, "make it better")
        XCTAssertEqual(request.personaPrompt, "formal")
    }

    func testRewriteRequestRewriteTranscriptMode() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "raw text",
            spokenInstruction: nil,
            personaPrompt: nil
        )
        if case .rewriteTranscript = request.mode {} else { XCTFail("Expected rewriteTranscript") }
        XCTAssertNil(request.spokenInstruction)
        XCTAssertNil(request.personaPrompt)
    }
}

// MARK: - Extended AgentOutcome tests

extension AgentOutcomeTests {

    // MARK: - AgentTurn cases

    func testAgentTurnTextCase() {
        let turn = AgentTurn.text("hello")
        guard case .text(let text) = turn else {
            XCTFail("Expected .text")
            return
        }
        XCTAssertEqual(text, "hello")
    }

    func testAgentTurnToolCallsCase() {
        let tc = AgentToolCall(id: "tc1", name: "my_tool", argumentsJSON: "{}")
        let turn = AgentTurn.toolCalls([tc])
        guard case .toolCalls(let calls) = turn else {
            XCTFail("Expected .toolCalls")
            return
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "tc1")
    }

    func testAgentTurnTextWithToolCallsCase() {
        let tc = AgentToolCall(id: "tc2", name: "search", argumentsJSON: #"{"q":"test"}"#)
        let turn = AgentTurn.textWithToolCalls(text: "Searching...", toolCalls: [tc])
        guard case .textWithToolCalls(let text, let calls) = turn else {
            XCTFail("Expected .textWithToolCalls")
            return
        }
        XCTAssertEqual(text, "Searching...")
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - AgentToolCall

    func testAgentToolCallProperties() {
        let tc = AgentToolCall(id: "unique-id", name: "execute_code", argumentsJSON: #"{"code":"print(1)"}"#)
        XCTAssertEqual(tc.id, "unique-id")
        XCTAssertEqual(tc.name, "execute_code")
        XCTAssertEqual(tc.argumentsJSON, #"{"code":"print(1)"}"#)
    }

    // MARK: - LLMCallConfig

    func testLLMCallConfigDefaults() {
        let config = LLMCallConfig(forcedToolName: nil, parallelToolCalls: true, temperature: nil)
        XCTAssertNil(config.forcedToolName)
        XCTAssertNil(config.temperature)
        XCTAssertTrue(config.parallelToolCalls)
    }

    func testLLMCallConfigCustom() {
        let config = LLMCallConfig(forcedToolName: "my_tool", parallelToolCalls: false, temperature: 0.5)
        XCTAssertEqual(config.forcedToolName, "my_tool")
        XCTAssertFalse(config.parallelToolCalls)
        XCTAssertEqual(config.temperature, 0.5)
    }

    // MARK: - AgentMessage

    func testAgentMessageSystemCase() {
        let msg = AgentMessage.system("You are helpful.")
        guard case .system(let text) = msg else {
            XCTFail("Expected .system")
            return
        }
        XCTAssertEqual(text, "You are helpful.")
    }

    func testAgentMessageUserCase() {
        let msg = AgentMessage.user("Hello!")
        guard case .user(let text) = msg else {
            XCTFail("Expected .user")
            return
        }
        XCTAssertEqual(text, "Hello!")
    }

    func testAgentMessageAssistantCase() {
        let am = AgentAssistantMessage(text: "Response", toolCalls: [])
        let msg = AgentMessage.assistant(am)
        guard case .assistant(let m) = msg else {
            XCTFail("Expected .assistant")
            return
        }
        XCTAssertEqual(m.text, "Response")
    }

    func testAgentMessageToolResultCase() {
        let tr = AgentToolResult(toolCallId: "tc1", content: "result", isError: false)
        let msg = AgentMessage.toolResult(tr)
        guard case .toolResult(let r) = msg else {
            XCTFail("Expected .toolResult")
            return
        }
        XCTAssertEqual(r.toolCallId, "tc1")
        XCTAssertEqual(r.content, "result")
        XCTAssertFalse(r.isError)
    }

    // MARK: - AgentResult

    func testAgentResultTotalDuration() {
        let result = AgentResult(outcome: .text("done"), steps: [], totalDurationMs: 1234)
        XCTAssertEqual(result.totalDurationMs, 1234)
    }

    func testAgentResultStepsCount() {
        let assistantMsg = AgentAssistantMessage(text: "thinking", toolCalls: [])
        let step = AgentStep(
            stepIndex: 0,
            assistantMessage: assistantMsg,
            toolResults: [],
            durationMs: 50
        )
        let result = AgentResult(outcome: .text("done"), steps: [step], totalDurationMs: 100)
        XCTAssertEqual(result.steps.count, 1)
    }
}
