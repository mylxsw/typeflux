@testable import Typeflux
import XCTest

final class AskTaskProgressTests: XCTestCase {
    private var directory: URL!
    private let pending = #"{"items":[{"step":"Finish the script and verify it","status":"in_progress"}]}"#
    private let done = #"{"items":[{"step":"Finish the script and verify it","status":"completed"}],"outcome":"completed"}"#
    private let blocked = #"{"items":[{"step":"Verify customer endpoint","status":"pending"}],"outcome":"needs_input","reason":"Which staging endpoint should be tested?"}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-progress-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func engine() -> AskLocalEngine { AskLocalEngine(directory: directory, contextLimits: { _ in .init(window: 1000000, maxOutput: 4096, known: true) }) }
    private func start(_ engine: AskLocalEngine, maxSteps: Int? = nil) async throws -> AskConversation {
        let tool = AskToolDefinition(name: "files", description: "Workspace files", parameters: JSONValue(data: Data(#"{"type":"object"}"#.utf8)))
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Finish the website", tools: [tool], modelRef: "custom:fixture")
        request.maxSteps = maxSteps
        request.executionMode = maxSteps == nil ? .continuous : .bounded
        return try await engine.send(conversationId: "task", request: request, token: "")
    }
    private func call(_ name: String, _ arguments: String) -> AskToolCall {
        .init(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: arguments))
    }
    private func answer(_ engine: AskLocalEngine, _ c: AskConversation, text: String = "", calls: [AskToolCall] = []) async throws -> AskConversation {
        let run = try XCTUnwrap(c.run), inference = try XCTUnwrap(run.inference)
        return try await engine.inferenceResult(conversationId: c.id, request: .init(runId: run.id, deviceId: "device", inferenceId: inference.id,
            content: text, toolCalls: calls, failed: false), token: "")
    }
    private func receipt(_ engine: AskLocalEngine, _ c: AskConversation, text: String = "Unchanged directory: index.html and assets/style.css") async throws -> AskConversation {
        let run = try XCTUnwrap(c.run), call = try XCTUnwrap(run.pending.first)
        return try await engine.result(conversationId: c.id, request: .init(runId: run.id, deviceId: "device", toolCallId: call.id, content: text, isError: false), token: "")
    }

    func testClosingReviewRequestsConcreteToolsWithoutGrantingPermission() async throws {
        let e = engine()
        var c = try await start(e)
        c = try await answer(e, c, calls: [call("update_plan", pending)])
        c = try await answer(e, c, text: "May I create the missing script?")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.run?.taskProgress?.closingReviewRequested, true)
        XCTAssertTrue(c.run?.inference?.payload.contains("submit its actual call") == true)
        XCTAssertEqual(c.run?.plan?.first?.status, "in_progress")
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"assets/app.js","content":"example"}"#)])
        XCTAssertEqual(c.run?.status, "waiting_tool")
        XCTAssertEqual(c.run?.pending.first?.function.name, "files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("assets/app.js").path))
        c = try await receipt(e, c, text: "Verified script written")
        c = try await answer(e, c, calls: [call("update_plan", done)])
        c = try await answer(e, c, text: "Implemented and verified")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertEqual(c.run?.taskResolution?.outcome, "completed")
    }

    func testUnreconciledFinalGetsOnlyOneReviewAcrossRestart() async throws {
        let e = engine()
        var c = try await start(e)
        c = try await answer(e, c, calls: [call("update_plan", pending)])
        c = try await answer(e, c, text: "Done")
        let reopened = engine()
        c = try await answer(reopened, c, text: "Still done")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertNil(c.run?.inference)
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
        XCTAssertEqual(c.run?.plan?.first?.status, "in_progress")
        XCTAssertEqual(c.run?.steps, 3)
        let saved = try await engine().conversation(id: c.id, token: "")
        XCTAssertEqual(saved.run?.taskResolution, c.run?.taskResolution)
    }

    func testStructuredMissingInputEndsWithoutInventingToolApproval() async throws {
        let e = engine()
        var c = try await start(e)
        c = try await answer(e, c, calls: [call("update_plan", blocked)])
        c = try await answer(e, c, text: "Please provide the staging endpoint.")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertEqual(c.run?.taskResolution?.outcome, "needs_input")
        XCTAssertEqual(c.run?.taskResolution?.reason, "Which staging endpoint should be tested?")
        XCTAssertEqual(c.run?.taskProgress?.closingReviewRequested, false)
        XCTAssertTrue(c.run?.pending.isEmpty == true)
        XCTAssertEqual(AskRunPhase.resolve(run: c.run, busy: false, pendingApproval: false, recovery: nil), .taskNeedsInput)
    }

    func testRepeatedUnchangedReadsWarnThenStopAndNewInputCanContinue() async throws {
        let e = engine()
        var c = try await start(e)
        for count in 1...5 {
            c = try await answer(e, c, calls: [call("files", #"{"action":"list","path":"work"}"#)])
            let waiting = c
            c = try await receipt(e, c)
            let replay = try await receipt(e, waiting)
            XCTAssertEqual(replay.revision, c.revision)
            if count == 3 {
                XCTAssertNotNil(c.run?.taskProgress?.repeatedKey)
                XCTAssertTrue(c.run?.inference?.payload.contains("unchanged results") == true)
            }
        }
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertNil(c.run?.inference)
        XCTAssertEqual(AskRunPhase.resolve(run: c.run, busy: false, pendingApproval: false, recovery: nil), .taskBlocked)
        let previousCount = c.messages.count
        c = try await start(e)
        XCTAssertNil(c.run?.taskResolution)
        XCTAssertEqual(c.run?.taskProgress?.startIndex, previousCount + 1)
        c = try await answer(e, c, calls: [call("files", #"{"action":"list","path":"work"}"#)])
        c = try await receipt(e, c)
        XCTAssertEqual(c.run?.status, "waiting_inference")
    }

    func testChangingEvidenceAndMutationsDoNotTriggerRepetition() async throws {
        let e = engine()
        var c = try await start(e)
        for count in 1...6 {
            c = try await answer(e, c, calls: [call("files", #"{"action":"read","path":"work/state.txt"}"#)])
            c = try await receipt(e, c, text: "A different observed result number \(count)")
        }
        XCTAssertNil(c.run?.taskProgress?.repeatedKey)
        for _ in 1...3 {
            c = try await answer(e, c, calls: [call("files", #"{"action":"list","path":"work"}"#)])
            c = try await receipt(e, c)
        }
        XCTAssertNotNil(c.run?.taskProgress?.repeatedKey)
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"work/new.txt","content":"new"}"#)])
        c = try await receipt(e, c)
        XCTAssertNil(c.run?.taskProgress?.repeatedKey)
        XCTAssertNil(AskTaskProgress.repetition(c))
    }

    private func checkpoint(_ e: AskLocalEngine) async throws -> AskConversation {
        var c = try await start(e)
        c = try await answer(e, c, calls: [call("update_plan", pending)])
        for index in 0..<16 {
            c = try await answer(e, c, calls: [call("files", "{\"action\":\"read\",\"path\":\"file-\(index)\"}")])
            c = try await receipt(e, c, text: "Distinct verified file content \(index)")
        }
        return c
    }

    func testStalePlanCheckpointRestrictsToolsAndResumesAfterValidUpdate() async throws {
        let e = engine()
        var c = try await checkpoint(e)
        XCTAssertEqual(c.run?.taskProgress?.planCheckpoint, true)
        let payload = try XCTUnwrap(c.run?.inference?.payload.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "update_plan")
        c = try await answer(e, c, calls: [call("update_plan", pending)])
        XCTAssertEqual(c.run?.taskProgress?.planCheckpoint, false)
        XCTAssertEqual(c.run?.plan?.first?.status, "in_progress")
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"app.js","content":"verified"}"#)])
        XCTAssertEqual(c.run?.status, "waiting_tool")
    }

    func testCheckpointRefusesOtherOperationsWithoutDispatch() async throws {
        let e = engine()
        var c = try await checkpoint(e)
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"app.js","content":"unexpected"}"#)])
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
        XCTAssertTrue(c.run?.pending.isEmpty == true)
        XCTAssertNil(c.run?.inference)
        XCTAssertFalse(c.messages.contains { ($0.toolCalls ?? []).contains { $0.function.arguments.contains("unexpected") } })
    }

    func testInvalidCheckpointPlanStopsInsteadOfRetryingForever() async throws {
        let e = engine()
        var c = try await checkpoint(e)
        c = try await answer(e, c, calls: [call("update_plan", #"{"items":[]}"#)])
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.run?.taskProgress?.checkpointCorrectionUsed, true)
        c = try await answer(e, c, calls: [call("update_plan", #"{"items":[]}"#)])
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
        XCTAssertNil(c.run?.inference)
        XCTAssertTrue(c.messages.contains { $0.role == "tool" && $0.isError == true })
    }

    func testClosingReviewHonorsExplicitStepLimit() async throws {
        let e = engine()
        var c = try await start(e, maxSteps: 10)
        for _ in 0..<9 { c = try await answer(e, c, calls: [call("update_plan", pending)]) }
        c = try await answer(e, c, text: "Unfinished")
        XCTAssertEqual(c.run?.steps, 10)
        XCTAssertNil(c.run?.inference)
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
    }

    func testSteeringDuringCheckpointDoesNotDispatchTheStaleProposal() async throws {
        let e = engine()
        var c = try await checkpoint(e)
        let message = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Use a different endpoint instead", tools: [], modelRef: "custom:fixture")
        _ = try await e.steer(conversationId: c.id, request: .init(runId: c.run!.id, message: message), token: "")
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"old.js","content":"stale"}"#)])
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.run?.taskProgress?.planCheckpoint, false)
        XCTAssertTrue(c.run?.pending.isEmpty == true)
        XCTAssertEqual(c.messages.last(where: { $0.role == "user" })?.id, message.id)
        XCTAssertFalse(c.messages.contains { ($0.toolCalls ?? []).contains { $0.function.arguments.contains("stale") } })
    }

    func testCheckpointErrorsAreMatchedToPlanReceipts() async throws {
        let e = engine()
        var c = try await start(e)
        let plan = call("update_plan", "{}")
        c.messages.append(.init(id: "proposal", role: "assistant", text: "", toolCalls: [plan], createdAt: Date()))
        c.messages.append(.init(id: "error", role: "tool", text: "invalid plan", toolCallId: plan.id, isError: true, createdAt: Date()))
        XCTAssertEqual(AskTaskProgress.lastPlanError(c), "error")
        let saved = try AskCoding.decoder().decode(AskTaskProgress.self,
            from: AskCoding.encoder().encode(AskTaskProgress(startIndex: 0, closingReviewRequested: true, planCheckpoint: true,
                checkpointCorrectionUsed: true, lastCheckpointErrorId: "error")))
        XCTAssertEqual(saved.lastCheckpointErrorId, AskTaskProgress.lastPlanError(c))
        c.messages[c.messages.count - 1].toolCallId = "a-different-tool"
        XCTAssertNil(AskTaskProgress.lastPlanError(c))
    }

    func testExplicitDenialDoesNotTriggerAnotherClosingApprovalRequest() async throws {
        let e = engine()
        var c = try await start(e)
        c = try await answer(e, c, calls: [call("update_plan", pending)])
        c = try await answer(e, c, calls: [call("files", #"{"action":"write","path":"app.js","content":"example"}"#)])
        let run = try XCTUnwrap(c.run), operation = try XCTUnwrap(run.pending.first)
        c = try await e.result(conversationId: c.id, request: .init(runId: run.id, deviceId: "device", toolCallId: operation.id,
            content: "User denied this tool call. Do not repeat it.", isError: true,
            harness: .init(version: 1, outcome: .init(status: "denied"))), token: "")
        c = try await answer(e, c, text: "The requested write was declined; unfinished work is retained.")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertEqual(c.run?.taskResolution?.outcome, "blocked")
        XCTAssertEqual(c.run?.taskProgress?.closingReviewRequested, false)
        XCTAssertNil(c.run?.inference)
    }

    func testOutcomeValidationPreservesHonestPendingWork() throws {
        XCTAssertNotNil(try AskBuiltinPlan.parse(blocked))
        XCTAssertNotNil(try AskBuiltinPlan.parse(done))
        for extra in [#""outcome":"completed""#, #""outcome":"needs_input""#, #""outcome":"blocked","reason":12"#, #""outcome":"approval","reason":"allow""#, #""reason":"missing outcome""#] {
            let raw = #"{"items":[{"step":"Unfinished","status":"pending"}],"# + extra + "}"
            XCTAssertThrowsError(try AskBuiltinPlan.parse(raw), raw)
        }
        XCTAssertEqual(AskPlanList.symbol("paused"), "pause.circle")
    }
}
