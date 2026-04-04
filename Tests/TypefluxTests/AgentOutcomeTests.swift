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
