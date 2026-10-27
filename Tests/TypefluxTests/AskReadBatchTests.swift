import Foundation
import Testing
@testable import Typeflux

actor ReadBatchGate {
    var entered: [String] = []
    var active = 0
    var peak = 0
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    func enter(_ id: String) async {
        entered.append(id); active += 1; peak = max(peak, active)
        if !released.contains(id) { await withCheckedContinuation { waiters[id] = $0 } }
        active -= 1
    }
    func release(_ id: String) { released.insert(id); waiters.removeValue(forKey: id)?.resume() }
}

struct ReadBatchHost: AskBuiltinToolHosting {
    let gate: ReadBatchGate
    func definitions() -> [AskToolDefinition] {
        ["web_search", "web_fetch", "update_plan"].map {
            .init(name: $0, description: "Synthetic", parameters: JSONValue(data: Data(#"{"type":"object"}"#.utf8)))
        }
    }
    func executionClassification(for definition: AskToolDefinition) -> AskBuiltinExecutionClass {
        definition.name == "update_plan" ? .serial : .independentWebRead
    }
    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput {
        await gate.enter(input.call.id)
        return .init(text: input.call.id, isError: input.call.id == "failure")
    }
}

@Suite("Authorized read batches", .exclusiveUIState)
@MainActor struct AskReadBatchTests {
    func calls(_ names: [String]) -> [AskToolCall] {
        names.enumerated().map { .init(id: "c\($0.offset)", function: .init(name: $0.element, arguments: "{}")) }
    }
    func fixture(_ names: [String], budget: Int64 = 10) async throws -> (AskLocalEngine, AskConversation, ReadBatchGate, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gate = ReadBatchGate()
        var limits = AskBudgetResources.standard; limits.webRequests = budget
        let engine = AskLocalEngine(directory: root, budgetEnabled: true, budgetLimits: limits, builtinTools: ReadBatchHost(gate: gate))
        let request = AskSendRequest(clientToolApproval: true, id: "message", deviceId: "device", text: "Read", tools: [], modelRef: "custom:test")
        let value = try await engine.send(conversationId: "batch", request: request, token: "")
        let waiting = try await engine.inferenceResult(conversationId: value.id,
            request: .init(runId: value.run!.id, deviceId: "device", inferenceId: value.run!.inference!.id,
                           content: "", toolCalls: calls(names)), token: "")
        return (engine, waiting, gate, root)
    }
    func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }
    func executor(_ run: AskRun) -> AskReadBatchExecutor {
        { call, operation in
            let output = await operation!()
            return .init(runId: run.id, deviceId: run.deviceId, toolCallId: call.id, content: output.content, isError: output.isError)
        }
    }

    @Test func approvedBatchOverlapsKeepsOrderAndStopsAtNextApproval() async throws {
        let (engine, value, gate, root) = try await fixture(Array(repeating: "web_search", count: 4))
        defer { try? FileManager.default.removeItem(at: root) }
        let run = value.run!
        let execute = executor(run)
        let task = Task { try await engine.readBatch(conversationId: value.id, runId: run.id,
            calls: Array(run.pending.prefix(3)), token: "", execute: execute) }
        try await until { await gate.entered.count == 3 }
        #expect(await gate.peak == 3)
        for id in ["c2", "c1", "c0"] { await gate.release(id) }
        let result = try #require(try await task.value)
        #expect(result.messages.filter { $0.role == "tool" }.compactMap(\.toolCallId) == ["c0", "c1", "c2"])
        #expect(result.run?.pending.map(\.id) == ["c3"])
        #expect(result.run?.status == "waiting_tool")
        #expect(await gate.entered.count == 3)
        #expect(result.run?.budget?.events?.contains { ["pending", "reserved"].contains($0.state) && $0.kind == "web_search" } != true)
    }

    @Test(arguments: [0, 1, 2]) func insufficientBudgetLaunchesNothing(slots: Int) async throws {
        let (engine, value, gate, root) = try await fixture(Array(repeating: "web_search", count: 3), budget: Int64(slots))
        defer { try? FileManager.default.removeItem(at: root) }
        let run = value.run!
        let result = try await engine.readBatch(conversationId: value.id, runId: run.id, calls: run.pending, token: "", execute: executor(run))
        #expect(result?.run?.stopReason == "web_requests")
        #expect(await gate.entered.isEmpty)
    }

    @Test func serialBuiltinAndReorderedPrefixAreRejected() async throws {
        let (engine, value, gate, root) = try await fixture(["web_search", "update_plan", "web_fetch"])
        defer { try? FileManager.default.removeItem(at: root) }
        let run = value.run!
        for selection in [Array(run.pending.prefix(2)), Array(run.pending.reversed())] {
            await #expect(throws: (any Error).self) {
                _ = try await engine.readBatch(conversationId: value.id, runId: run.id, calls: selection, token: "", execute: executor(run))
            }
        }
        #expect(await gate.entered.isEmpty)
    }

    @Test func failedClientReceiptStopsBatchWithoutReexecutingCompletedRead() async throws {
        let (engine, value, gate, root) = try await fixture(["web_search", "web_search"])
        defer { try? FileManager.default.removeItem(at: root) }
        let run = value.run!
        await gate.release("c0"); await gate.release("c1")
        await #expect(throws: (any Error).self) {
            _ = try await engine.readBatch(conversationId: value.id, runId: run.id, calls: run.pending, token: "") { call, operation in
                let output = await operation!()
                if call.id == "c1" { throw AskRecoveryError.unknown }
                return .init(runId: run.id, deviceId: run.deviceId, toolCallId: call.id, content: output.content, isError: false)
            }
        }
        let failed = try await engine.conversation(id: value.id, token: "")
        #expect(failed.run?.needsRecoveryInspection == true)
        // A saved completed receipt is a result, not a second authorization intent.
        let recovered = try await engine.result(conversationId: value.id, request: .init(runId: run.id,
            deviceId: run.deviceId, toolCallId: "c0", content: "saved", isError: false), token: "")
        #expect(recovered.messages.last(where: { $0.toolCallId == "c0" })?.text == "saved")
        #expect(await gate.entered.filter { $0 == "c0" }.count == 1)
    }

    @Test func cancellationDoesNotPublishLateResultsOrStartAnotherWave() async throws {
        let (engine, value, gate, root) = try await fixture(Array(repeating: "web_search", count: 4))
        defer { try? FileManager.default.removeItem(at: root) }
        let run = value.run!, execute = executor(run)
        let task = Task { try await engine.readBatch(conversationId: value.id, runId: run.id,
            calls: Array(run.pending.prefix(3)), token: "", execute: execute) }
        try await until { await gate.entered.count == 3 }
        _ = try await engine.cancel(conversationId: value.id, runId: run.id, token: "")
        for id in ["c0", "c1", "c2"] { await gate.release(id) }
        _ = try? await task.value
        let result = try await engine.conversation(id: value.id, token: "")
        #expect(result.run?.status == "cancelled")
        #expect(await gate.entered.count == 3)
        #expect(await gate.active == 0)
        #expect(result.messages.filter { $0.role == "tool" }.allSatisfy { $0.text != $0.toolCallId })
    }
}
