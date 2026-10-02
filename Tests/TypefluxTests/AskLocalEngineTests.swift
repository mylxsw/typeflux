@testable import Typeflux
import XCTest

final class AskLocalEngineTests: XCTestCase {
    private var directory: URL!
    private let model = "custom:my-model"
    private let device = "device-1"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-local-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine(now: @escaping @Sendable () -> Date = Date.init, web: AskLocalWebTools = AskLocalWebTools(resolve: { _ in [] })) -> AskLocalEngine {
        AskLocalEngine(directory: directory, webTools: web, now: now)
    }

    private func request(_ text: String = "Hello", tools: [AskToolDefinition] = AskLocalTools.builtins, memory: AskMemory? = nil) -> AskSendRequest {
        var request = AskSendRequest(id: UUID().uuidString, deviceId: device, text: text, tools: tools, modelRef: model, memory: memory)
        request.timeZone = "Asia/Shanghai"
        request.locale = "zh-Hans-CN"
        return request
    }

    private func payload(_ c: AskConversation) throws -> [String: Any] {
        let inference = try XCTUnwrap(c.run?.inference)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inference.payload.utf8)) as? [String: Any])
    }

    private func answer(_ engine: AskLocalEngine, _ c: AskConversation, content: String = "", calls: [AskToolCall] = [],
                        finish: String? = nil, failed: Bool = false) async throws -> AskConversation {
        let run = try XCTUnwrap(c.run)
        let inference = try XCTUnwrap(run.inference)
        return try await engine.inferenceResult(conversationId: c.id, request: AskInferenceResult(
            runId: run.id, deviceId: device, inferenceId: inference.id, content: content, toolCalls: calls, failed: failed, finishReason: finish), token: "")
    }

    private func call(_ name: String, _ args: String = "{}", id: String = UUID().uuidString) -> AskToolCall {
        AskToolCall(id: id, type: "function", function: .init(name: name, arguments: args))
    }

    func testConversationRunsOnDeviceWithToolsAndPersists() async throws {
        let fixed = Date(timeIntervalSince1970: 1_790_870_400) // 2026-10-01 16:00 UTC, already Friday in Shanghai
        let engine = engine(now: { fixed })
        let id = UUID().uuidString.lowercased()
        var c = try await engine.send(conversationId: id, request: request("读一下当前页面", memory: AskMemory(global: "Prefers <b>short</b> answers")), token: "")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.title, "读一下当前页面")
        let body = try payload(c)
        // Read the system texts themselves; serialized JSON escapes "/".
        let text = ((body["messages"] as? [[String: Any]]) ?? []).compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("You are Typeflux Ask"))
        XCTAssertTrue(text.contains("Today's date: 2026-10-02 (Friday), time zone Asia/Shanghai."), text)
        XCTAssertTrue(text.contains("Device locale: zh-Hans-CN."))
        XCTAssertTrue(text.contains("Prefers &lt;b&gt;short&lt;/b&gt; answers"))
        let toolNames = (body["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(toolNames, ["computer", "browser", "update_plan", "web_fetch"])
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true)

        // The model plans (run here) and reads the page (device tool).
        c = try await answer(engine, c, calls: [call("update_plan", #"{"items":[{"step":"Read","status":"in_progress"}]}"#), call("browser", #"{"action":"read"}"#, id: "b1")])
        XCTAssertEqual(c.run?.status, "waiting_tool")
        XCTAssertEqual(c.run?.pending.map(\.id), ["b1"])
        XCTAssertEqual(c.run?.plan, [AskPlanItem(step: "Read", status: "in_progress")])
        XCTAssertEqual(c.messages.last?.text, "Plan updated.")

        c = try await engine.result(conversationId: id, request: AskToolResultRequest(runId: c.run!.id, deviceId: device, toolCallId: "b1", content: "Release 4.2", isError: false), token: "")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        // A duplicate device result is ignored.
        let replay = try await engine.result(conversationId: id, request: AskToolResultRequest(runId: c.run!.id, deviceId: device, toolCallId: "b1", content: "again", isError: false), token: "")
        XCTAssertEqual(replay.revision, c.revision)

        c = try await answer(engine, c, content: "Release 4.2 is out.")
        XCTAssertEqual(c.run?.status, "completed")
        XCTAssertEqual(c.run?.steps, 2)
        XCTAssertEqual(c.messages.last?.text, "Release 4.2 is out.")
        // A late receipt for a finished run is rejected.
        let runId = c.run!.id
        await assertThrows(L("ask.local.conflict")) {
            _ = try await engine.inferenceResult(conversationId: id, request: AskInferenceResult(
                runId: runId, deviceId: self.device, inferenceId: UUID().uuidString, content: "late"), token: "")
        }

        // Persisted as JSON and listed by another engine instance.
        let reopened = self.engine()
        let listed = try await reopened.list(token: "", offset: 0)
        XCTAssertEqual(listed.map(\.id), [id])
        let loaded = try await reopened.conversation(id: id, token: "")
        XCTAssertEqual(loaded.messages.count, c.messages.count)
        try await reopened.purgeMemory(token: "")
        let purged = try await reopened.conversation(id: id, token: "")
        XCTAssertNil(purged.memory)
        try await reopened.delete(conversationId: id, token: "")
        let empty = try await reopened.list(token: "", offset: 0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testCloudModelsAreRejectedAndRequestsValidated() async throws {
        let engine = engine()
        var cloud = request()
        cloud.modelRef = "cloud:default"
        await assertThrows(L("ask.local.modelRequired")) { _ = try await engine.send(conversationId: "c1", request: cloud, token: "") }
        cloud.modelRef = nil
        await assertThrows(L("ask.local.modelRequired")) { _ = try await engine.send(conversationId: "c1", request: cloud, token: "") }
        await assertThrows(L("ask.local.emptyQuestion")) { _ = try await engine.send(conversationId: "c1", request: self.request("  "), token: "") }
        await assertThrows(L("ask.local.notFound")) { _ = try await engine.conversation(id: "missing", token: "") }
        await assertThrows(L("ask.local.notFound")) { _ = try await engine.send(conversationId: "../escape", request: self.request(), token: "") }
        await assertThrows(L("ask.local.notFound")) { _ = try await engine.conversation(id: "a/b", token: "") }
        try await engine.delete(conversationId: "../x", token: "")
        XCTAssertTrue(AskLocalEngine.validID("0b6e-AZ_9"))
        XCTAssertFalse(AskLocalEngine.validID(String(repeating: "a", count: 129)))

        let first = request()
        let c = try await engine.send(conversationId: "c2", request: first, token: "")
        let again = try await engine.send(conversationId: "c2", request: first, token: "")
        XCTAssertEqual(again.revision, c.revision)
        await assertThrows(L("ask.local.busy")) { _ = try await engine.send(conversationId: "c2", request: self.request("next"), token: "") }
        await assertThrows(L("ask.local.conflict")) {
            _ = try await engine.result(conversationId: "c2", request: AskToolResultRequest(runId: "other", deviceId: self.device, toolCallId: "x", content: "", isError: false), token: "")
        }
        await assertThrows(L("ask.local.conflict")) {
            _ = try await engine.inferenceResult(conversationId: "c2", request: AskInferenceResult(runId: c.run!.id, deviceId: self.device, inferenceId: "wrong", content: ""), token: "")
        }
        let models = try await engine.models(token: "")
        XCTAssertTrue(models.isEmpty)
    }

    func testFailuresKeepPartialOutputAndRetryRegenerate() async throws {
        let engine = engine()
        var c = try await engine.send(conversationId: "c", request: request(), token: "")
        c = try await answer(engine, c, content: "Partial text", finish: "length")
        XCTAssertEqual(c.run?.status, "failed")
        XCTAssertEqual(c.run?.error, L("ask.local.truncated"))
        XCTAssertEqual(c.messages.last?.text, "Partial text")
        XCTAssertEqual(c.messages.last?.isError, true)

        c = try await engine.retry(conversationId: "c", runId: c.run!.id, deviceId: device, modelRef: nil, token: "")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        c = try await answer(engine, c, content: "half", failed: true)
        XCTAssertEqual(c.run?.error, L("ask.local.modelFailed"))
        c = try await engine.retry(conversationId: "c", runId: c.run!.id, deviceId: device, modelRef: "custom:other", token: "")
        XCTAssertEqual(c.modelRef, "custom:other")
        c = try await answer(engine, c, content: "")
        XCTAssertEqual(c.run?.error, L("ask.local.empty"))
        c = try await engine.retry(conversationId: "c", runId: c.run!.id, deviceId: device, modelRef: nil, token: "")
        c = try await answer(engine, c, calls: [call("unknown_tool")])
        XCTAssertEqual(c.run?.error, L("ask.local.invalidTools"))
        c = try await engine.retry(conversationId: "c", runId: c.run!.id, deviceId: device, modelRef: nil, token: "")
        c = try await answer(engine, c, content: "Final")
        XCTAssertEqual(c.run?.status, "completed")
        let completed = try await engine.retry(conversationId: "c", runId: c.run!.id, deviceId: device, modelRef: nil, token: "")
        XCTAssertEqual(completed.revision, c.revision)

        let answerId = try XCTUnwrap(c.messages.last?.id)
        c = try await engine.regenerate(conversationId: "c", request: AskRegenerateRequest(messageId: answerId, deviceId: device), token: "")
        XCTAssertEqual(c.run?.status, "waiting_inference")
        XCTAssertEqual(c.messages.last?.role, "user")
        await assertThrows(L("ask.local.conflict")) {
            _ = try await engine.regenerate(conversationId: "c", request: AskRegenerateRequest(messageId: answerId, deviceId: self.device), token: "")
        }
        c = try await engine.cancel(conversationId: "c", runId: c.run!.id, partial: AskInferenceResult(
            runId: c.run!.id, deviceId: device, inferenceId: c.run!.inference!.id, content: "So far"), token: "")
        XCTAssertEqual(c.run?.status, "cancelled")
        XCTAssertEqual(c.messages.last?.text, "So far")
        let cancelledAgain = try await engine.cancel(conversationId: "c", runId: c.run!.id, token: "")
        XCTAssertEqual(cancelledAgain.revision, c.revision)
        await assertThrows(L("ask.local.regenerateLatest")) {
            _ = try await engine.regenerate(conversationId: "c", request: AskRegenerateRequest(messageId: "nope", deviceId: self.device), token: "")
        }
    }

    func testCancelWhileWaitingForADeviceToolClosesTheCall() async throws {
        let engine = engine()
        var c = try await engine.send(conversationId: "c", request: request(), token: "")
        c = try await answer(engine, c, calls: [call("computer", #"{"action":"screenshot"}"#, id: "shot")])
        XCTAssertEqual(c.run?.status, "waiting_tool")
        c = try await engine.cancel(conversationId: "c", runId: c.run!.id, token: "")
        XCTAssertEqual(c.run?.status, "cancelled")
        XCTAssertEqual(c.messages.last?.toolCallId, "shot")
        XCTAssertEqual(c.messages.last?.isError, true)
        await assertThrows(L("ask.local.conflict")) { _ = try await engine.cancel(conversationId: "c", runId: "other", token: "") }
    }

    func testLongHistoryIsSummarizedOnDevice() async throws {
        let engine = engine()
        var c = try await engine.send(conversationId: "long", request: request("q0"), token: "")
        c = try await answer(engine, c, content: "a0")
        for index in 1 ... 14 {
            c = try await engine.send(conversationId: "long", request: request("q\(index)"), token: "")
            if c.run?.inference?.summaryThrough != nil { break }
            c = try await answer(engine, c, content: "a\(index)")
        }
        let cut = try XCTUnwrap(c.run?.inference?.summaryThrough)
        XCTAssertEqual(c.messages[cut].role, "user")
        let summaryPayload = String(describing: try payload(c)["messages"] ?? "")
        XCTAssertTrue(summaryPayload.contains("Summarize this conversation"))
        // A summary with tool calls is rejected; a valid one is kept and the answer is queued.
        var bad = try await answer(engine, c, content: "", calls: [call("browser")])
        XCTAssertEqual(bad.run?.error, L("ask.local.badSummary"))
        bad = try await engine.retry(conversationId: "long", runId: bad.run!.id, deviceId: device, modelRef: nil, token: "")
        c = try await answer(engine, bad, content: "Earlier: greetings.")
        XCTAssertEqual(c.summary, "Earlier: greetings.")
        XCTAssertEqual(c.summaryThrough, cut)
        XCTAssertNil(c.run?.inference?.summaryThrough)
        XCTAssertTrue(String(describing: try payload(c)["messages"] ?? "").contains("Previous conversation summary"))
    }

    func testStepAndBuiltinLimits() async throws {
        let engine = engine()
        var c = try await engine.send(conversationId: "loop", request: request(), token: "")
        var limitSeen = false
        for _ in 0 ..< AskLocalEngine.maxSteps {
            c = try await answer(engine, c, calls: [call("update_plan", #"{"items":[{"step":"x","status":"pending"}]}"#)])
            limitSeen = limitSeen || c.messages.contains { $0.text.contains("Web tool limit") }
            if c.run?.status != "waiting_inference" { break }
        }
        XCTAssertTrue(limitSeen)
        XCTAssertEqual(c.run?.status, "failed")
        XCTAssertEqual(c.run?.error, L("ask.local.stepLimit"))
        let invalid = try await engine.send(conversationId: "plan", request: request(), token: "")
        let failedPlan = try await answer(engine, invalid, calls: [call("update_plan", #"{"items":[]}"#)])
        XCTAssertEqual(failedPlan.messages.last?.isError, true)
        XCTAssertThrowsError(try AskLocalEngine.parsePlan(#"{"items":[{"step":"a","status":"in_progress"},{"step":"b","status":"in_progress"}]}"#))
        XCTAssertThrowsError(try AskLocalEngine.parsePlan(#"{"items":[{"step":"a","status":"done"}]}"#))
        XCTAssertThrowsError(try AskLocalEngine.parsePlan(#"{"items":[{"step":" ","status":"pending"}]}"#))
    }

    func testStaleRunsExpireAndWebFetchRunsOnDevice() async throws {
        let clock = Clock()
        let engine = engine(now: { clock.now })
        var c = try await engine.send(conversationId: "stale", request: request(), token: "")
        clock.now = clock.now.addingTimeInterval(AskLocalEngine.staleAfter + 60)
        c = try await engine.conversation(id: "stale", token: "")
        XCTAssertEqual(c.run?.status, "failed")
        XCTAssertEqual(c.run?.error, L("ask.local.expired"))

        // web_fetch is refused for private addresses by the engine's web tools.
        c = try await engine.retry(conversationId: "stale", runId: c.run!.id, deviceId: device, modelRef: nil, token: "")
        c = try await answer(engine, c, calls: [call("web_fetch", #"{"url":"http://192.168.1.1/admin"}"#, id: "f1")])
        XCTAssertEqual(c.run?.status, "waiting_inference")
        let result = try XCTUnwrap(c.messages.first { $0.toolCallId == "f1" })
        XCTAssertEqual(result.isError, true)
    }

    private func assertThrows(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date()
}
