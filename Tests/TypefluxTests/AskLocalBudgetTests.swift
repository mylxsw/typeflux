import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

final class AskLocalBudgetTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func engine(limits: AskBudgetResources = .standard, context: AskContextLimits = .init()) -> AskLocalEngine {
        AskLocalEngine(directory: directory, budgetEnabled: true, budgetLimits: limits, contextLimits: { _ in context })
    }

    func request(_ text: String = "Question") -> AskSendRequest {
        .init(id: UUID().uuidString, deviceId: "device", text: text, tools: [
            .init(name: "browser", description: "Read", parameters: .init(data: Data(#"{"type":"object"}"#.utf8)))
        ], modelRef: "custom:test")
    }

    func receipt(
        _ conversation: AskConversation,
        content: String = "",
        calls: [AskToolCall] = [],
        failed: Bool = false
    ) throws -> AskInferenceResult {
        let run = try XCTUnwrap(conversation.run)
        return try .init(runId: run.id, deviceId: "device", inferenceId: XCTUnwrap(run.inference?.id), content: content,
                         toolCalls: calls, usage: .init(promptTokens: 5, completionTokens: 5, totalTokens: 10),
                         failed: failed)
    }

    func testLocalBudgetPersistsAcrossCancelRestartLateUsageAndRetry() async throws {
        let engine = engine()
        var conversation = try await engine.send(conversationId: "conversation", request: request(), token: "")
        let pending = try receipt(conversation, content: "Late")
        let root = conversation.run?.budgetRootId, deadline = conversation.run?.budgetDeadline
        XCTAssertEqual(conversation.run?.budget?.pending, 1)
        XCTAssertTrue(try XCTUnwrap(conversation.run?.inference?.payload.contains("typeflux_budget")))
        conversation = try await engine.cancel(conversationId: "conversation", runId: pending.runId, token: "")
        let restarted = self.engine()
        conversation = try await restarted.inferenceResult(conversationId: "conversation", request: pending, token: "")
        XCTAssertEqual(conversation.run?.status, "cancelled")
        XCTAssertEqual(conversation.run?.budget?.actual.tokens, 10)
        XCTAssertGreaterThan(conversation.run?.budget?.occupied.tokens ?? 0, 10)
        let version = conversation.run?.budget?.version
        conversation = try await restarted.inferenceResult(conversationId: "conversation", request: pending, token: "")
        XCTAssertEqual(conversation.run?.budget?.version, version)
        conversation = try await restarted.retry(
            conversationId: "conversation",
            runId: pending.runId,
            deviceId: "device",
            modelRef: nil,
            token: ""
        )
        XCTAssertEqual(conversation.run?.budgetRootId, root)
        XCTAssertEqual(
            try XCTUnwrap(conversation.run?.budgetDeadline).timeIntervalSince1970,
            try XCTUnwrap(deadline).timeIntervalSince1970,
            accuracy: 0.002
        )
        XCTAssertEqual(conversation.run?.budget?.pending, 2)
    }

    func testLocalPlanExemptionDeviceReceiptsAndBudgetStop() async throws {
        var limits = AskBudgetResources.standard
        limits.webRequests = 0
        limits.operations = 4
        let engine = engine(limits: limits)
        var conversation = try await engine.send(conversationId: "conversation", request: request(), token: "")
        let plan = AskToolCall(
            id: "plan",
            function: .init(name: "update_plan", arguments: #"{"items":[{"step":"Read","status":"in_progress"}]}"#)
        )
        let device = AskToolCall(id: "device", function: .init(name: "browser", arguments: "{}"))
        conversation = try await engine.inferenceResult(
            conversationId: "conversation",
            request: receipt(conversation, calls: [plan, device]),
            token: ""
        )
        XCTAssertEqual(conversation.run?.status, "waiting_tool")
        XCTAssertEqual(conversation.run?.budget?.occupied.webRequests, 0)
        XCTAssertEqual(conversation.run?.plan?.first?.step, "Read")
        conversation = try await engine.result(
            conversationId: "conversation",
            request: .init(
                runId: XCTUnwrap(conversation.run?.id),
                deviceId: "device",
                toolCallId: "device",
                content: "Evidence",
                isError: false
            ),
            token: ""
        )
        XCTAssertEqual(conversation.run?.status, "waiting_inference")
        conversation = try await engine.inferenceResult(
            conversationId: "conversation",
            request: receipt(
                conversation,
                calls: [.init(id: "more", function: .init(name: "browser", arguments: "{}"))]
            ),
            token: ""
        )
        XCTAssertEqual(conversation.run?.status, "failed")
        XCTAssertEqual(conversation.run?.stopReason, "operations")
        XCTAssertTrue(conversation.messages.contains { $0.role == "assistant" && $0.text.contains("Evidence") })
        XCTAssertTrue(conversation.messages.contains { $0.text == "Evidence" })
        XCTAssertTrue(conversation.run?.pending.isEmpty == true)
    }

    func testContextBudgetStopsBeforeInferenceAndUsesModelWindow() async throws {
        let engine = engine(context: .init(window: 4096, maxOutput: 512, known: true))
        let short = try await engine.send(conversationId: "short", request: request(), token: "")
        XCTAssertEqual(short.contextUsage?.capacity, 4096)
        XCTAssertEqual(short.contextUsage?.outputReserve, 512)
        let oversized = try await engine.send(
            conversationId: "long",
            request: request(String(repeating: "constraint", count: 5000)),
            token: ""
        )
        XCTAssertEqual(oversized.run?.stopReason, "context_capacity")
        XCTAssertNil(oversized.run?.inference)
        XCTAssertEqual(AskBudgetView.reasonKey("unknown"), "ask.budget.reason.budget_unavailable")
    }

    func testDeviceRechecksRegisteredWindowWithoutIncreasingOutput() throws {
        let raw = #"{"messages":[{"role":"user","content":"Question"}],"max_tokens":2048,"typeflux_budget":true}"#
        let model = RegisteredModel(id: "test", name: "Test", contextWindowTokens: 4096, maxOutputTokens: 512)
        XCTAssertEqual(try AskContextPlanner.devicePayload(raw, model: model, budgeted: false), raw)
        let bounded = try AskContextPlanner.devicePayload(raw, model: model, budgeted: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bounded.utf8)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertThrowsError(try AskContextPlanner.devicePayload("[]", model: model, budgeted: true))
    }

    func testProviderThinkingNeverInflatesReservedOutput() throws {
        var native: [String: Any] = ["max_tokens": 4096, "messages": [["role": "user", "content": "Question"]]]
        AskReasoningRequest.applyAnthropic(effort: "high", to: &native, totalOutputLimit: 4096)
        XCTAssertEqual(native["max_tokens"] as? Int, 4096)
        XCTAssertEqual((native["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 3072)
        native.removeValue(forKey: "thinking")
        AskReasoningRequest.applyAnthropic(effort: "high", to: &native, totalOutputLimit: 1024)
        XCTAssertNil(native["thinking"])
        XCTAssertEqual(native["max_tokens"] as? Int, 1024)
        let body: [String: Any] = ["messages": [["role": "user", "content": "Question"]], "max_tokens": 123]
        let gemini = try AskCustomInference.nativeBody(body, model: "model", anthropic: false)
        XCTAssertEqual((gemini["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 123)
    }

    @MainActor
    func testBudgetCardRendersAndLateSummaryMergesWithoutContentRevival() throws {
        let state = AskBudgetController(runId: "run", limits: .standard, deadline: Date().addingTimeInterval(60))
        var summary = state.summary
        summary.pending = 1
        summary.stopReason = "tokens"
        summary.metering = "client_reported"
        let view = NSHostingView(rootView: AskBudgetView(budget: summary).frame(width: 310).padding(16))
        view.frame = NSRect(x: 0, y: 0, width: 342, height: 260)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100)
        if let path = ProcessInfo.processInfo
            .environment["GUL181_BUDGET_SCREENSHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
        var old = AskConversation(id: "conversation", title: "Question", revision: 2, updatedAt: Date(), messages: [])
        old.run = .init(
            id: "run",
            deviceId: "device",
            status: "cancelled",
            steps: 1,
            updatedAt: Date(),
            tools: [],
            pending: [],
            budget: summary
        )
        var incoming = old
        incoming.revision = 1
        incoming.run?.status = "running"
        incoming.run?.budget?.version += 1
        let merged = old.reconciling(incoming)
        XCTAssertEqual(merged.run?.status, "cancelled")
        XCTAssertEqual(merged.run?.budget?.version, summary.version + 1)
        XCTAssertTrue(incoming.isNewer(than: old))
        var stream = AskConversationStreamState()
        _ = try stream.consume(
            event: "snapshot",
            data: XCTUnwrap(String(data: AskCoding.encoder().encode(old), encoding: .utf8))
        )
        let next = try stream.consume(
            event: "progress",
            data: XCTUnwrap(String(data: AskCoding.encoder().encode(incoming), encoding: .utf8))
        )
        XCTAssertEqual(next?.run?.status, "cancelled")
        XCTAssertEqual(next?.run?.budget?.version, summary.version + 1)
    }

    func testBudgetedProviderDoesNotRetryRejectedReasoning() async {
        var calls = 0
        do {
            let _: String = try await AskReasoningRequest.send(["reasoning_effort": "high"], allowRetry: false) { _ in
                calls += 1
                throw AskStreamError.rejected
            }
            XCTFail("Expected refusal")
        } catch { XCTAssertEqual(calls, 1) }
    }
}
