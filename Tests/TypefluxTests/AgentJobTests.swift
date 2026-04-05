@testable import Typeflux
import XCTest

final class AgentJobTests: XCTestCase {
    // MARK: - AgentJobStatus

    func testStatusRawValues() {
        XCTAssertEqual(AgentJobStatus.running.rawValue, "running")
        XCTAssertEqual(AgentJobStatus.completed.rawValue, "completed")
        XCTAssertEqual(AgentJobStatus.failed.rawValue, "failed")
    }

    func testStatusDecodable() throws {
        let json = #""completed""#.data(using: .utf8)!
        let status = try JSONDecoder().decode(AgentJobStatus.self, from: json)
        XCTAssertEqual(status, .completed)
    }

    // MARK: - AgentJobStep

    func testStepIdentifiable() {
        let step = AgentJobStep(stepIndex: 3, toolCalls: [], assistantText: nil, durationMs: 100)
        XCTAssertEqual(step.id, "3")
    }

    func testStepCodable() throws {
        let toolCall = AgentJobToolCall(
            id: "tc-1", name: "search", argumentsJSON: "{}", resultContent: "ok", isError: false,
        )
        let step = AgentJobStep(
            stepIndex: 0,
            toolCalls: [toolCall],
            assistantText: "Thinking...",
            durationMs: 250,
        )

        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(AgentJobStep.self, from: data)

        XCTAssertEqual(decoded.stepIndex, 0)
        XCTAssertEqual(decoded.toolCalls.count, 1)
        XCTAssertEqual(decoded.toolCalls[0].name, "search")
        XCTAssertEqual(decoded.assistantText, "Thinking...")
        XCTAssertEqual(decoded.durationMs, 250)
    }

    // MARK: - AgentJobToolCall

    func testToolCallCodable() throws {
        let tc = AgentJobToolCall(
            id: "call-1",
            name: "get_clipboard",
            argumentsJSON: #"{"format":"text"}"#,
            resultContent: "Hello",
            isError: false,
        )
        let data = try JSONEncoder().encode(tc)
        let decoded = try JSONDecoder().decode(AgentJobToolCall.self, from: data)

        XCTAssertEqual(decoded.id, "call-1")
        XCTAssertEqual(decoded.name, "get_clipboard")
        XCTAssertFalse(decoded.isError)
        XCTAssertEqual(decoded.resultContent, "Hello")
    }

    func testToolCallErrorFlag() {
        let tc = AgentJobToolCall(id: "e1", name: "fail_tool", argumentsJSON: "{}", resultContent: "error", isError: true)
        XCTAssertTrue(tc.isError)
    }

    // MARK: - AgentJob init defaults

    func testDefaultInit() {
        let job = AgentJob(userPrompt: "Tell me a joke")
        XCTAssertEqual(job.status, .running)
        XCTAssertNil(job.completedAt)
        XCTAssertNil(job.title)
        XCTAssertNil(job.selectedText)
        XCTAssertNil(job.resultText)
        XCTAssertNil(job.errorMessage)
        XCTAssertTrue(job.steps.isEmpty)
        XCTAssertNil(job.totalDurationMs)
        XCTAssertNil(job.outcomeType)
        XCTAssertEqual(job.userPrompt, "Tell me a joke")
    }

    // MARK: - displayTitle

    func testDisplayTitleUsesTitle() {
        let job = AgentJob(title: "Search Results", userPrompt: "Search for cats")
        XCTAssertEqual(job.displayTitle, "Search Results")
    }

    func testDisplayTitleFallsBackToPrompt() {
        let job = AgentJob(userPrompt: "Short prompt")
        XCTAssertEqual(job.displayTitle, "Short prompt")
    }

    func testDisplayTitleTruncatesLongPrompt() {
        let longPrompt = String(repeating: "a", count: 100)
        let job = AgentJob(userPrompt: longPrompt)
        XCTAssertEqual(job.displayTitle.count, 61) // 60 + "…"
        XCTAssertTrue(job.displayTitle.hasSuffix("…"))
    }

    func testDisplayTitleIgnoresEmptyTitle() {
        let job = AgentJob(title: "", userPrompt: "Fallback prompt")
        XCTAssertEqual(job.displayTitle, "Fallback prompt")
    }

    func testDisplayTitleExactly60CharPrompt() {
        let prompt = String(repeating: "b", count: 60)
        let job = AgentJob(userPrompt: prompt)
        XCTAssertEqual(job.displayTitle, prompt)
        XCTAssertFalse(job.displayTitle.hasSuffix("…"))
    }

    // MARK: - isSuccess

    func testIsSuccessCompleted() {
        let job = AgentJob(status: .completed, userPrompt: "test")
        XCTAssertTrue(job.isSuccess)
    }

    func testIsSuccessRunning() {
        let job = AgentJob(status: .running, userPrompt: "test")
        XCTAssertFalse(job.isSuccess)
    }

    func testIsSuccessFailed() {
        let job = AgentJob(status: .failed, userPrompt: "test")
        XCTAssertFalse(job.isSuccess)
    }

    // MARK: - totalToolCalls

    func testTotalToolCallsEmpty() {
        let job = AgentJob(userPrompt: "test")
        XCTAssertEqual(job.totalToolCalls, 0)
    }

    func testTotalToolCallsSingle() {
        let tc = AgentJobToolCall(id: "1", name: "a", argumentsJSON: "{}", resultContent: "", isError: false)
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc], assistantText: nil, durationMs: 10)
        let job = AgentJob(userPrompt: "test", steps: [step])
        XCTAssertEqual(job.totalToolCalls, 1)
    }

    func testTotalToolCallsMultipleSteps() {
        let tc1 = AgentJobToolCall(id: "1", name: "a", argumentsJSON: "{}", resultContent: "", isError: false)
        let tc2 = AgentJobToolCall(id: "2", name: "b", argumentsJSON: "{}", resultContent: "", isError: false)
        let tc3 = AgentJobToolCall(id: "3", name: "c", argumentsJSON: "{}", resultContent: "", isError: false)
        let step1 = AgentJobStep(stepIndex: 0, toolCalls: [tc1, tc2], assistantText: nil, durationMs: 10)
        let step2 = AgentJobStep(stepIndex: 1, toolCalls: [tc3], assistantText: nil, durationMs: 20)
        let job = AgentJob(userPrompt: "test", steps: [step1, step2])
        XCTAssertEqual(job.totalToolCalls, 3)
    }

    // MARK: - formattedDuration

    func testFormattedDurationNil() {
        let job = AgentJob(userPrompt: "test")
        XCTAssertNil(job.formattedDuration)
    }

    func testFormattedDurationMs() {
        let job = AgentJob(userPrompt: "test", totalDurationMs: 500)
        XCTAssertEqual(job.formattedDuration, "500ms")
    }

    func testFormattedDurationSeconds() {
        let job = AgentJob(userPrompt: "test", totalDurationMs: 3500)
        XCTAssertEqual(job.formattedDuration, "3.5s")
    }

    func testFormattedDurationExactSecond() {
        let job = AgentJob(userPrompt: "test", totalDurationMs: 1000)
        XCTAssertEqual(job.formattedDuration, "1.0s")
    }

    func testFormattedDurationZero() {
        let job = AgentJob(userPrompt: "test", totalDurationMs: 0)
        XCTAssertEqual(job.formattedDuration, "0ms")
    }

    func testFormattedDurationBoundary999ms() {
        let job = AgentJob(userPrompt: "test", totalDurationMs: 999)
        XCTAssertEqual(job.formattedDuration, "999ms")
    }

    // MARK: - formattedTotalTokens

    func testFormattedTotalTokensNil() {
        let job = AgentJob(userPrompt: "test")
        XCTAssertNil(job.formattedTotalTokens)
    }

    func testFormattedTotalTokensZero() {
        let job = AgentJob(userPrompt: "test", totalTokenUsage: LLMTokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0))
        XCTAssertNil(job.formattedTotalTokens)
    }

    func testFormattedTotalTokensSmall() {
        let job = AgentJob(userPrompt: "test", totalTokenUsage: LLMTokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150))
        XCTAssertEqual(job.formattedTotalTokens, "150 tokens")
    }

    func testFormattedTotalTokensThousands() {
        let job = AgentJob(userPrompt: "test", totalTokenUsage: LLMTokenUsage(promptTokens: 1500, completionTokens: 500, totalTokens: 2000))
        XCTAssertEqual(job.formattedTotalTokens, "2.0K tokens")
    }

    func testFormattedTotalTokensMillions() {
        let job = AgentJob(userPrompt: "test", totalTokenUsage: LLMTokenUsage(promptTokens: 900_000, completionTokens: 200_000, totalTokens: 1_100_000))
        XCTAssertEqual(job.formattedTotalTokens, "1.1M tokens")
    }

    // MARK: - AgentJobStep stepDescription

    func testStepDescriptionNoTools() {
        let step = AgentJobStep(stepIndex: 0, toolCalls: [], assistantText: "Hello", durationMs: 100)
        XCTAssertEqual(step.stepDescription, "Generating response")
    }

    func testStepDescriptionNoToolsNoText() {
        let step = AgentJobStep(stepIndex: 0, toolCalls: [], assistantText: nil, durationMs: 100)
        XCTAssertEqual(step.stepDescription, "Processing")
    }

    func testStepDescriptionSingleTool() {
        let tc = AgentJobToolCall(id: "1", name: "web_search", argumentsJSON: "{}", resultContent: "", isError: false)
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc], assistantText: nil, durationMs: 100)
        XCTAssertEqual(step.stepDescription, "Web Search")
    }

    func testStepDescriptionMultipleTools() {
        let tc1 = AgentJobToolCall(id: "1", name: "search", argumentsJSON: "{}", resultContent: "", isError: false)
        let tc2 = AgentJobToolCall(id: "2", name: "fetch", argumentsJSON: "{}", resultContent: "", isError: false)
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc1, tc2], assistantText: nil, durationMs: 100)
        XCTAssertEqual(step.stepDescription, "2 tools: search, fetch")
    }

    // MARK: - AgentJobStep formattedDuration

    func testStepFormattedDurationMs() {
        let step = AgentJobStep(stepIndex: 0, toolCalls: [], assistantText: nil, durationMs: 500)
        XCTAssertEqual(step.formattedDuration, "500ms")
    }

    func testStepFormattedDurationSeconds() {
        let step = AgentJobStep(stepIndex: 0, toolCalls: [], assistantText: nil, durationMs: 2500)
        XCTAssertEqual(step.formattedDuration, "2.5s")
    }

    // MARK: - LLMTokenUsage arithmetic

    func testTokenUsageAddition() {
        let a = LLMTokenUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
        let b = LLMTokenUsage(promptTokens: 200, completionTokens: 80, totalTokens: 280)
        let sum = a + b
        XCTAssertEqual(sum.promptTokens, 300)
        XCTAssertEqual(sum.completionTokens, 130)
        XCTAssertEqual(sum.totalTokens, 430)
    }

    // MARK: - Codable round-trip

    func testAgentJobCodable() throws {
        let tc = AgentJobToolCall(id: "tc1", name: "search", argumentsJSON: #"{"q":"test"}"#, resultContent: "found", isError: false)
        let step = AgentJobStep(stepIndex: 0, toolCalls: [tc], assistantText: "Let me search.", durationMs: 150)
        let job = AgentJob(
            id: UUID(),
            createdAt: Date(),
            completedAt: Date(),
            status: .completed,
            title: "Test Job",
            userPrompt: "Search for test",
            selectedText: "selected",
            resultText: "The answer is 42",
            errorMessage: nil,
            steps: [step],
            totalDurationMs: 1500,
            outcomeType: "answer_text",
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(AgentJob.self, from: data)

        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.title, "Test Job")
        XCTAssertEqual(decoded.userPrompt, "Search for test")
        XCTAssertEqual(decoded.selectedText, "selected")
        XCTAssertEqual(decoded.resultText, "The answer is 42")
        XCTAssertEqual(decoded.steps.count, 1)
        XCTAssertEqual(decoded.totalDurationMs, 1500)
        XCTAssertEqual(decoded.outcomeType, "answer_text")
    }
}
