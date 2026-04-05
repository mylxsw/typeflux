import XCTest
@testable import Typeflux

// MARK: - Mock Store

/// In-memory mock of AgentJobStore for testing AgentJobRecorder without SQLite.
private final class MockAgentJobStore: AgentJobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UUID: AgentJob] = [:]
    private var _saveCount = 0

    var savedJobs: [AgentJob] {
        synchronized { Array(jobs.values) }
    }

    var saveCount: Int {
        synchronized { _saveCount }
    }

    func save(_ job: AgentJob) async throws {
        synchronized {
            jobs[job.id] = job
            _saveCount += 1
        }
    }

    func list(limit: Int, offset: Int) async throws -> [AgentJob] {
        synchronized {
            Array(jobs.values.sorted { $0.createdAt > $1.createdAt }.dropFirst(offset).prefix(limit))
        }
    }

    func job(id: UUID) async throws -> AgentJob? {
        synchronized { jobs[id] }
    }

    func delete(id: UUID) async throws {
        synchronized {
            jobs.removeValue(forKey: id)
        }
    }

    func clear() async throws {
        synchronized {
            jobs.removeAll()
        }
    }

    func count() async throws -> Int {
        synchronized { jobs.count }
    }

    @discardableResult
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class AgentJobRecorderTests: XCTestCase {

    private var mockStore: MockAgentJobStore!
    private var recorder: AgentJobRecorder!
    private var jobID: UUID!

    override func setUp() {
        super.setUp()
        mockStore = MockAgentJobStore()
        jobID = UUID()
        recorder = AgentJobRecorder(store: mockStore, jobID: jobID)
    }

    override func tearDown() {
        recorder = nil
        mockStore = nil
        jobID = nil
        super.tearDown()
    }

    // MARK: - recordedJobID

    func testRecordedJobID() {
        XCTAssertEqual(recorder.recordedJobID, jobID)
    }

    // MARK: - beginJob

    func testBeginJobCreatesRunningJob() async throws {
        await recorder.beginJob(userPrompt: "What is Swift?", selectedText: nil)

        let job = try await mockStore.job(id: jobID)
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.status, .running)
        XCTAssertEqual(job?.userPrompt, "What is Swift?")
        XCTAssertNil(job?.selectedText)
        XCTAssertTrue(job?.steps.isEmpty ?? false)
    }

    func testBeginJobWithSelectedText() async throws {
        await recorder.beginJob(userPrompt: "Rewrite this", selectedText: "Hello world")

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.selectedText, "Hello world")
    }

    // MARK: - agentDidCompleteStep

    func testCompleteStepRecordsStep() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)

        let assistantMsg = AgentAssistantMessage(
            text: "Let me search",
            toolCalls: [
                AgentToolCall(id: "tc-1", name: "search", argumentsJSON: #"{"q":"swift"}"#)
            ]
        )
        let toolResults = [
            AgentToolResult(toolCallId: "tc-1", content: "Found results", isError: false)
        ]
        let step = AgentStep(
            stepIndex: 0,
            assistantMessage: assistantMsg,
            toolResults: toolResults,
            durationMs: 150
        )

        await recorder.agentDidCompleteStep(step)

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.steps.count, 1)
        XCTAssertEqual(job?.steps[0].stepIndex, 0)
        XCTAssertEqual(job?.steps[0].toolCalls.count, 1)
        XCTAssertEqual(job?.steps[0].toolCalls[0].name, "search")
        XCTAssertEqual(job?.steps[0].toolCalls[0].resultContent, "Found results")
        XCTAssertFalse(job?.steps[0].toolCalls[0].isError ?? true)
        XCTAssertEqual(job?.steps[0].assistantText, "Let me search")
        XCTAssertEqual(job?.steps[0].durationMs, 150)
    }

    func testMultipleStepsAccumulate() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)

        for i in 0..<3 {
            let msg = AgentAssistantMessage(text: nil, toolCalls: [
                AgentToolCall(id: "tc-\(i)", name: "tool_\(i)", argumentsJSON: "{}")
            ])
            let results = [AgentToolResult(toolCallId: "tc-\(i)", content: "ok", isError: false)]
            let step = AgentStep(stepIndex: i, assistantMessage: msg, toolResults: results, durationMs: Int64(i * 100))
            await recorder.agentDidCompleteStep(step)
        }

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.steps.count, 3)
        XCTAssertEqual(job?.steps[0].stepIndex, 0)
        XCTAssertEqual(job?.steps[1].stepIndex, 1)
        XCTAssertEqual(job?.steps[2].stepIndex, 2)
    }

    func testStepWithMoreToolResultsThanCalls() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)

        let msg = AgentAssistantMessage(text: nil, toolCalls: [
            AgentToolCall(id: "tc-1", name: "tool_a", argumentsJSON: "{}")
        ])
        // More tool results than tool calls — the extra result should use toolCallId as fallback
        let results = [
            AgentToolResult(toolCallId: "tc-1", content: "ok1", isError: false),
            AgentToolResult(toolCallId: "tc-extra", content: "ok2", isError: false)
        ]
        let step = AgentStep(stepIndex: 0, assistantMessage: msg, toolResults: results, durationMs: 50)
        await recorder.agentDidCompleteStep(step)

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.steps[0].toolCalls.count, 2)
        XCTAssertEqual(job?.steps[0].toolCalls[0].name, "tool_a")
        XCTAssertEqual(job?.steps[0].toolCalls[1].name, "unknown")
        XCTAssertEqual(job?.steps[0].toolCalls[1].id, "tc-extra")
    }

    // MARK: - agentDidFinish

    func testFinishWithTextOutcome() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .text("The answer"))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertEqual(job?.resultText, "The answer")
        XCTAssertEqual(job?.outcomeType, "text")
        XCTAssertNotNil(job?.completedAt)
        XCTAssertNotNil(job?.totalDurationMs)
    }

    func testFinishWithAnswerTextTool() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        let argsJSON = #"{"answer":"42 is the answer"}"#
        await recorder.agentDidFinish(outcome: .terminationTool(name: "answer_text", argumentsJSON: argsJSON))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertEqual(job?.resultText, "42 is the answer")
        XCTAssertEqual(job?.outcomeType, "answer_text")
    }

    func testFinishWithEditTextTool() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        let argsJSON = #"{"replacement":"Edited text here"}"#
        await recorder.agentDidFinish(outcome: .terminationTool(name: "edit_text", argumentsJSON: argsJSON))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertEqual(job?.resultText, "Edited text here")
        XCTAssertEqual(job?.outcomeType, "edit_text")
    }

    func testFinishWithUnknownTerminationTool() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .terminationTool(name: "custom_tool", argumentsJSON: "{}"))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertNil(job?.resultText)
        XCTAssertEqual(job?.outcomeType, "custom_tool")
    }

    func testFinishWithMaxStepsReached() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .maxStepsReached)

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertEqual(job?.errorMessage, "Maximum steps reached")
        XCTAssertEqual(job?.outcomeType, "maxStepsReached")
    }

    func testFinishWithError() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        let error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        await recorder.agentDidFinish(outcome: .error(error))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertEqual(job?.errorMessage, "Something broke")
        XCTAssertEqual(job?.outcomeType, "error")
    }

    func testFinishPreservesAccumulatedSteps() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)

        let msg = AgentAssistantMessage(text: "step", toolCalls: [
            AgentToolCall(id: "tc-1", name: "tool", argumentsJSON: "{}")
        ])
        let result = [AgentToolResult(toolCallId: "tc-1", content: "ok", isError: false)]
        await recorder.agentDidCompleteStep(AgentStep(stepIndex: 0, assistantMessage: msg, toolResults: result, durationMs: 100))

        await recorder.agentDidFinish(outcome: .text("Done"))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.steps.count, 1)
        XCTAssertEqual(job?.resultText, "Done")
    }

    // MARK: - markFailed

    func testMarkFailed() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network timeout"])
        await recorder.markFailed(error: error)

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertEqual(job?.errorMessage, "Network timeout")
        XCTAssertEqual(job?.outcomeType, "error")
        XCTAssertNotNil(job?.completedAt)
        XCTAssertNotNil(job?.totalDurationMs)
    }

    // MARK: - extractStringField (tested indirectly)

    func testFinishWithInvalidJSON() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .terminationTool(name: "answer_text", argumentsJSON: "not json"))

        let job = try await mockStore.job(id: jobID)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertNil(job?.resultText)
    }

    func testFinishWithMissingFieldInJSON() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .terminationTool(name: "answer_text", argumentsJSON: #"{"other":"value"}"#))

        let job = try await mockStore.job(id: jobID)
        XCTAssertNil(job?.resultText)
    }

    func testFinishWithNonStringFieldInJSON() async throws {
        await recorder.beginJob(userPrompt: "Test", selectedText: nil)
        await recorder.agentDidFinish(outcome: .terminationTool(name: "answer_text", argumentsJSON: #"{"answer":42}"#))

        let job = try await mockStore.job(id: jobID)
        XCTAssertNil(job?.resultText)
    }
}
