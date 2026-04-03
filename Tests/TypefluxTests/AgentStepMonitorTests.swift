import XCTest
@testable import Typeflux

final class AgentStepMonitorTests: XCTestCase {

    func testStepLoggerDoesNotThrow() async throws {
        let logger = AgentStepLogger()
        let step = AgentStep(
            stepIndex: 0,
            assistantMessage: AgentAssistantMessage(
                text: nil,
                toolCalls: [AgentToolCall(id: "1", name: "get_clipboard", argumentsJSON: "{}")]
            ),
            toolResults: [AgentToolResult(toolCallId: "1", content: "data", isError: false)],
            durationMs: 123
        )
        await logger.agentDidCompleteStep(step)
        await logger.agentDidFinish(outcome: .text("done"))
        // No assertion needed — just verifies it doesn't crash
    }

    func testStepLoggerAllOutcomes() async throws {
        let logger = AgentStepLogger()
        await logger.agentDidFinish(outcome: .text("answer"))
        await logger.agentDidFinish(outcome: .terminationTool(name: "answer_text", argumentsJSON: "{}"))
        await logger.agentDidFinish(outcome: .maxStepsReached)

        struct DummyError: Error {}
        await logger.agentDidFinish(outcome: .error(DummyError()))
    }

    func testAgentRealtimeState() {
        let tc = AgentToolCall(id: "1", name: "get_clipboard", argumentsJSON: "{}")
        let state = AgentRealtimeState(
            currentStep: 2,
            lastToolCall: tc,
            accumulatedText: "partial",
            toolCallsSoFar: [tc]
        )
        XCTAssertEqual(state.currentStep, 2)
        XCTAssertEqual(state.lastToolCall?.name, "get_clipboard")
        XCTAssertEqual(state.accumulatedText, "partial")
        XCTAssertEqual(state.toolCallsSoFar.count, 1)
    }

    func testAgentStepProperties() {
        let assistantMsg = AgentAssistantMessage(
            text: "thinking",
            toolCalls: [AgentToolCall(id: "1", name: "tool", argumentsJSON: "{}")]
        )
        let results = [AgentToolResult(toolCallId: "1", content: "result", isError: false)]
        let step = AgentStep(
            stepIndex: 3,
            assistantMessage: assistantMsg,
            toolResults: results,
            durationMs: 250
        )
        XCTAssertEqual(step.stepIndex, 3)
        XCTAssertEqual(step.assistantMessage.text, "thinking")
        XCTAssertEqual(step.toolResults.count, 1)
        XCTAssertEqual(step.durationMs, 250)
    }

    func testMockMonitorAccumulatesSteps() async throws {
        let monitor = MockAgentStepMonitor()

        let step1 = AgentStep(
            stepIndex: 0,
            assistantMessage: AgentAssistantMessage(text: nil, toolCalls: []),
            toolResults: [],
            durationMs: 10
        )
        let step2 = AgentStep(
            stepIndex: 1,
            assistantMessage: AgentAssistantMessage(text: nil, toolCalls: []),
            toolResults: [],
            durationMs: 20
        )

        await monitor.agentDidCompleteStep(step1)
        await monitor.agentDidCompleteStep(step2)
        await monitor.agentDidFinish(outcome: .maxStepsReached)

        XCTAssertEqual(monitor.completedSteps.count, 2)
        XCTAssertEqual(monitor.completedSteps[0].stepIndex, 0)
        XCTAssertEqual(monitor.completedSteps[1].stepIndex, 1)
        if case .maxStepsReached = monitor.finishedOutcome! {
            // pass
        } else {
            XCTFail("Expected maxStepsReached")
        }
    }
}
