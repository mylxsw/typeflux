@testable import Typeflux
import XCTest

final class AskBuiltinToolHostTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-host-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func call(_ name: String = "update_plan", id: String = UUID().uuidString,
              arguments: String = "{}") -> AskToolCall {
        .init(id: id, function: .init(name: name, arguments: arguments))
    }

    private func send(_ engine: AskLocalEngine, tools: [AskToolDefinition] = [],
                      approval: Bool = true) async throws -> AskConversation {
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question", tools: tools,
                                     modelRef: "custom:test", memory: AskMemory(global: "purge-sentinel"))
        request.clientToolApproval = approval
        return try await engine.send(conversationId: "conversation", request: request, token: "")
    }

    private func receipt(_ conversation: AskConversation, _ calls: [AskToolCall]) throws -> AskInferenceResult {
        try .init(
            runId: XCTUnwrap(conversation.run?.id),
            deviceId: "device",
            inferenceId: XCTUnwrap(conversation.run?.inference?.id),
            content: "",
            toolCalls: calls,
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        )
    }

    private func approve(_ engine: AskLocalEngine, _ conversation: AskConversation, _ id: String,
                         allow: Bool = true) async throws -> AskConversation {
        try await engine.result(conversationId: conversation.id, request: .init(
            approveExecution: allow,
            runId: XCTUnwrap(conversation.run?.id),
            deviceId: "device",
            toolCallId: id,
            content: "untrusted client text",
            isError: false
        ), token: "")
    }

    func testInjectedHostReceivesApprovedSnapshotAndAppliesDeltaOnce() async throws {
        let host = RecordingBuiltinHost()
        let engine = AskLocalEngine(directory: directory, budgetEnabled: true, builtinTools: host)
        var conversation = try await send(engine)
        XCTAssertEqual(host.definitionCount, 1)
        XCTAssertEqual(conversation.run?.cloudTools?.map(\.name), ["update_plan", "web_search"])
        let input = try receipt(conversation, [call(id: "yes"), call(id: "no")])
        conversation = try await engine.inferenceResult(conversationId: conversation.id, request: input, token: "")
        XCTAssertTrue(host.inputs.isEmpty)
        conversation = try await approve(engine, conversation, "yes")
        let admitted = try XCTUnwrap(host.inputs.first)
        XCTAssertEqual(admitted.call.id, "yes")
        XCTAssertTrue(admitted.budgeted)
        XCTAssertEqual(admitted.conversation.id, conversation.id)
        XCTAssertEqual(admitted.conversation.memory?.global, "purge-sentinel")
        XCTAssertEqual(admitted.conversation.run?.status, "running")
        XCTAssertEqual(admitted.conversation.run?.pending.first?.id, "yes")
        XCTAssertEqual(conversation.run?.plan, host.output.plan)
        XCTAssertEqual(conversation.messages.filter { $0.toolCallId == "yes" }.map(\.text), [host.output.text])
        let replay = try await approve(engine, conversation, "yes")
        XCTAssertEqual(replay, conversation)
        conversation = try await approve(engine, conversation, "no", allow: false)
        let duplicate = try await engine.inferenceResult(conversationId: conversation.id, request: input, token: "")
        XCTAssertEqual(duplicate, conversation)
        XCTAssertEqual(host.inputs.count, 1)
        XCTAssertEqual(conversation.messages.filter { $0.toolCallId == "yes" }.count, 1)
        XCTAssertEqual(conversation.messages.last?.isError, true)
    }

    func testDeviceCollisionDoesNotInvokeHost() async throws {
        let host = RecordingBuiltinHost()
        let engine = AskLocalEngine(directory: directory, builtinTools: host)
        var conversation = try await send(engine, tools: [AskLocalEngine.planTool])
        XCTAssertEqual(conversation.run?.cloudTools?.map(\.name), ["web_search"])
        conversation = try await engine.inferenceResult(
            conversationId: conversation.id,
            request: receipt(conversation, [call(id: "device")]),
            token: ""
        )
        XCTAssertEqual(conversation.run?.status, "waiting_tool")
        conversation = try await engine.result(
            conversationId: conversation.id,
            request: .init(runId: XCTUnwrap(conversation.run?.id), deviceId: "device",
                           toolCallId: "device", content: "device receipt",
                           isError: false),
            token: ""
        )
        XCTAssertTrue(host.inputs.isEmpty)
        XCTAssertNil(conversation.run?.plan)
        XCTAssertEqual(conversation.messages.last?.text, "device receipt")
    }

    func testBindingAndBudgetRejectBeforeHostInvocation() async throws {
        let host = RecordingBuiltinHost()
        var limits = AskBudgetResources.standard
        limits.webRequests = 0
        let engine = AskLocalEngine(directory: directory, budgetEnabled: true, budgetLimits: limits, builtinTools: host)
        var conversation = try await send(engine)
        conversation = try await engine.inferenceResult(
            conversationId: conversation.id,
            request: receipt(conversation, [call("web_search", id: "budget")]),
            token: ""
        )
        conversation = try await approve(engine, conversation, "budget")
        XCTAssertEqual(conversation.run?.status, "failed")
        XCTAssertEqual(conversation.run?.stopReason, "web_requests")
        XCTAssertTrue(host.inputs.isEmpty)

        let file = directory.appendingPathComponent(conversation.id + ".json")
        var record = try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: file))
        record.conversation.run?.agentBinding = .init(id: "unknown.agent", version: 1)
        try AskCoding.encoder().encode(record).write(to: file)
        let reopened = AskLocalEngine(directory: directory, builtinTools: host)
        do {
            _ = try await reopened.retry(
                conversationId: conversation.id,
                runId: XCTUnwrap(conversation.run?.id),
                deviceId: "device",
                modelRef: nil,
                token: ""
            )
            XCTFail("Unsupported binding must reject execution")
        } catch { XCTAssertEqual(
            error.localizedDescription,
            AskLocalError.implementationUnavailable.localizedDescription
        ) }
        XCTAssertTrue(host.inputs.isEmpty)
    }

    func testLimitCannotBeRelaxedByHostAndPlanHistoryRemainExempt() async throws {
        let host = RecordingBuiltinHost()
        let engine = AskLocalEngine(directory: directory, builtinTools: host)
        var conversation = try await send(engine, approval: false)
        // Persist the boundary rather than spending sixteen unrelated model steps.
        let file = directory.appendingPathComponent(conversation.id + ".json")
        var record = try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: file))
        record.cloudCalls = AskLocalEngine.maxBuiltinCalls
        record.conversation.summary = "Earlier evidence"
        record.builtinTools.append(AskSemanticCompaction.historyTool)
        try AskCoding.encoder().encode(record).write(to: file)
        let reopened = AskLocalEngine(directory: directory, builtinTools: host)
        conversation = try await reopened.inferenceResult(
            conversationId: conversation.id,
            request: receipt(conversation, [
                call("web_search", id: "limit"), call(id: "plan"), call("read_conversation_history", id: "history")
            ]),
            token: ""
        )
        XCTAssertEqual(host.inputs.map(\.call.id), ["plan", "history"])
        XCTAssertEqual(conversation.messages.first { $0.toolCallId == "limit" }?.text,
                       "Web tool limit for this request reached. Answer with the information gathered so far.")
        XCTAssertEqual(conversation.messages.first { $0.toolCallId == "limit" }?.isError, true)
        let saved = try AskCoding.decoder().decode(AskLocalRecord.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.cloudCalls, AskLocalEngine.maxBuiltinCalls + 1)
        XCTAssertEqual(conversation.run?.plan, host.output.plan)
    }

    // Keep release/collection and assertions together for each suspended interleaving.
    // swiftlint:disable:next function_body_length
    func testHeldInjectedOutputCannotReviveCancelledOrReplacementRunOrPurgedMemory() async throws {
        for mode in ["purge", "cancel", "replace"] {
            let host = RecordingBuiltinHost(held: true)
            let engine = AskLocalEngine(
                directory: directory.appendingPathComponent(mode),
                budgetEnabled: true,
                builtinTools: host
            )
            var conversation = try await send(engine)
            let input = try receipt(conversation, [call("web_search", id: "held")])
            conversation = try await engine.inferenceResult(conversationId: conversation.id, request: input, token: "")
            let waiting = conversation
            let task = Task { try await self.approve(engine, waiting, "held") }
            await fulfillment(of: [host.started], timeout: 5)
            let expected: AskConversation
            do {
                try await engine.purgeMemory(token: "")
                if mode != "purge" {
                    _ = try await engine.cancel(conversationId: conversation.id, runId: input.runId, token: "")
                }
                if mode == "replace" {
                    _ = try await engine.retry(
                        conversationId: conversation.id,
                        runId: input.runId,
                        deviceId: "device",
                        modelRef: nil,
                        token: ""
                    )
                }
                expected = try await engine.conversation(id: conversation.id, token: "")
            } catch {
                host.release()
                _ = try? await task.value
                throw error
            }
            host.release()
            let result = try await task.value
            XCTAssertNil(result.memory)
            XCTAssertFalse(result.run?.inference?.payload.contains("purge-sentinel") == true)
            XCTAssertEqual(host.inputs.count, 1)
            if mode == "purge" {
                XCTAssertEqual(result.run?.plan, host.output.plan)
                XCTAssertEqual(result.messages.filter { $0.toolCallId == "held" }.map(\.text), [host.output.text])
                XCTAssertEqual(result.run?.budget?.actual.webRequests, 1)
            } else {
                // Settlement still updates the budget of the original root;
                // it cannot change the winning run's content or ownership.
                var settled = expected
                settled.run?.budget = result.run?.budget
                XCTAssertEqual(result, settled)
                XCTAssertEqual(result.run?.budget?.pending, (expected.run?.budget?.pending ?? 0) - 1)
                XCTAssertNil(result.run?.plan)
                XCTAssertFalse(result.messages.contains { $0.text == host.output.text })
                XCTAssertEqual(result.messages.filter { $0.toolCallId == "held" }.count, 1)
            }
            let replay = try await engine.inferenceResult(conversationId: conversation.id, request: input, token: "")
            XCTAssertEqual(replay, result)
            let root = try XCTUnwrap(waiting.run?.budgetRootId)
            let journal = try AskBudgetStore(directory: directory.appendingPathComponent(mode)).update(
                conversation: conversation.id,
                root: root
            ) { _ in }
            let reservation = journal.reservations["\(input.runId)/held/tool"]
            XCTAssertEqual(reservation?.actual.webRequests, 1)
            XCTAssertEqual(reservation?.state, "settled")
            XCTAssertEqual(reservation?.source, "scheduler")
        }
    }
}

private final class RecordingBuiltinHost: AskBuiltinToolHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [AskBuiltinToolInput] = []
    private var definitionsRead = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released: Bool
    let started = XCTestExpectation(description: "Injected host suspended")
    let output = AskBuiltinToolOutput(
        text: "host delta",
        isError: false,
        plan: [.init(step: "Host plan", status: "completed")]
    )

    init(held: Bool = false) {
        released = !held
    }

    var inputs: [AskBuiltinToolInput] {
        lock.withLock { calls }
    }

    var definitionCount: Int {
        lock.withLock { definitionsRead }
    }

    func definitions() -> [AskToolDefinition] {
        lock.withLock { definitionsRead += 1 }
        return [
            AskLocalEngine.planTool,
            .init(name: "web_search", description: "Fixture", parameters: .init(data: Data("{}".utf8)))
        ]
    }

    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput {
        lock.withLock { calls.append(input) }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released {
                    return true
                }
                self.continuation = continuation
                return false
            }
            started.fulfill()
            if resume {
                continuation.resume()
            }
        }
        return output
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
}
