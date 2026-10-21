import Foundation
import XCTest
@testable import Typeflux

private final class TurnAdapter: AskAgentTurnAdapter, @unchecked Sendable {
    let descriptor: AskAgentDescriptor
    private let lock = NSLock()
    private var inputs: [AskAgentTurnInput] = []
    let decide: @Sendable (AskAgentTurnInput) async throws -> AskAgentDecision
    init(binding: AskAgentBinding = .init(id: "test.turn", version: 1),
         decide: @escaping @Sendable (AskAgentTurnInput) async throws -> AskAgentDecision) {
        descriptor = .init(binding: binding, operations: Set(AskAgentOperation.allCases))
        self.decide = decide
    }
    func next(_ input: AskAgentTurnInput) async throws -> AskAgentDecision {
        lock.withLock { inputs.append(input) }
        return try await decide(input)
    }
    var count: Int { lock.withLock { inputs.count } }
}

final class AskAgentTurnTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func policy(_ adapter: TurnAdapter, owner: AskTurnDirectoryOwner, selected: AskAgentBinding? = nil) throws -> AskAgentTurnPolicy {
        let binding = adapter.descriptor.binding
        return try .init(adapters: [DefaultAskAgentTurnAdapter(), adapter], selected: selected ?? binding, enabled: [.default, binding],
            peer: .init(protocolVersion: 1, contracts: [.init(id: binding.id, version: binding.version, operations: AskAgentOperation.allCases)]), owner: owner)
    }
    private func fake() -> TurnAdapter {
        TurnAdapter { input in
            if case .model = input.previous {
                return .proposeTools([.init(name: "update_plan", arguments: #"{"items":[{"step":"Host tool executed","status":"completed"}]}"#, callID: "plan-call")],
                    content: "", state: .object(["phase": .string("tool"), "opaque": .number(.init("9007199254740993"))]))
            }
            if case let .tools(results) = input.previous, results.contains(where: { $0.callID == "plan-call" }) {
                return .finish(content: "Finished using host results", reasoning: nil, state: .string("done"))
            }
            return .requestModel(prompt: input.preparedPrompt, purpose: "main", state: .string("model"))
        }
    }
    private func request() -> AskSendRequest {
        var req = AskSendRequest(id: UUID().uuidString, deviceId: "device", text: "Question", tools: [], modelRef: "custom:model")
        req.clientToolApproval = true
        return req
    }
    private func read(_ id: String) throws -> AskLocalRecord {
        try .decodeSnapshot(Data(contentsOf: directory.appendingPathComponent(id + ".json")))
    }
    private func app(_ engine: AskLocalEngine) -> AskApplicationAPI {
        .init(runtime: engine, conversations: engine, modelAccess: engine)
    }

    func testFakeThroughApplicationModelReceiptApprovalToolAndReload() async throws {
        let owner = try AskTurnDirectoryOwner(directory: directory)
        let adapter = fake()
        var engine: AskLocalEngine? = AskLocalEngine(directory: directory, budgetEnabled: true, turnPolicy: try policy(adapter, owner: owner))
        var api: AskApplicationAPI? = app(engine!)
        let req = request()
        var conversation = try await api!.send(conversationId: "fake", request: req, token: "")
        XCTAssertEqual(conversation.run?.status, "waiting_inference")
        XCTAssertEqual(conversation.run?.agentBinding, adapter.descriptor.binding)
        XCTAssertEqual(adapter.count, 1)
        let run = try XCTUnwrap(conversation.run), inference = try XCTUnwrap(run.inference)
        let receipt = AskInferenceResult(runId: run.id, deviceId: req.deviceId, inferenceId: inference.id, content: "Provider completion")
        conversation = try await api!.inferenceResult(conversationId: conversation.id, request: receipt, token: "")
        XCTAssertEqual(conversation.run?.status, "waiting_tool")
        XCTAssertTrue(conversation.run?.plan?.isEmpty != false)
        let before = adapter.count
        do {
            _ = try await api!.result(conversationId: conversation.id, request: .init(runId: run.id, deviceId: "other", toolCallId: "plan-call", content: "", isError: false), token: "")
            XCTFail("Wrong device executed")
        } catch {}
        do {
            _ = try await api!.result(conversationId: conversation.id, request: .init(runId: run.id, deviceId: req.deviceId, toolCallId: "plan-call", content: "", isError: false), token: "")
            XCTFail("Missing approval executed")
        } catch {}
        XCTAssertEqual(adapter.count, before)
        XCTAssertTrue(try read(conversation.id).agentState?.encodeRaw().range(of: Data("9007199254740993".utf8)) != nil)
        api = nil
        engine = nil
        // Same exclusive cohort and durable state, different default for new runs.
        let restarted = AskLocalEngine(directory: directory, budgetEnabled: true, turnPolicy: try policy(adapter, owner: owner, selected: .default))
        let restartedAPI = app(restarted)
        conversation = try await restartedAPI.result(conversationId: conversation.id, request: .init(approveExecution: true,
                runId: run.id, deviceId: req.deviceId, toolCallId: "plan-call", content: "", isError: false), token: "")
        XCTAssertEqual(conversation.run?.status, "completed")
        XCTAssertEqual(conversation.messages.last?.text, "Finished using host results")
        XCTAssertEqual(conversation.run?.plan?.first?.step, "Host tool executed")
        XCTAssertEqual(conversation.run?.agentBinding, adapter.descriptor.binding)
        let doneCount = adapter.count
        _ = try await restartedAPI.inferenceResult(conversationId: conversation.id, request: receipt, token: "")
        XCTAssertEqual(adapter.count, doneCount)
        XCTAssertTrue(try read(conversation.id).agentState?.encodeRaw().range(of: Data("done".utf8)) != nil)
        let wire = String(decoding: try AskCoding.encoder().encode(conversation), as: UTF8.self)
        XCTAssertFalse(wire.contains("agent_state")); XCTAssertFalse(wire.contains("9007199254740993"))
        let usage = try await restartedAPI.usage(id: conversation.id, runId: nil, cursor: nil, token: "")
        XCTAssertFalse(String(decoding: try AskCoding.encoder().encode(usage), as: UTF8.self).contains("agent_state"))
    }

    func testProductionDefaultCallsAdapterAndPreservesContent() async throws {
        let adapter = TurnAdapter(binding: .default) { input in try await DefaultAskAgentTurnAdapter().next(input) }
        let policy = try AskAgentTurnPolicy(adapters: [adapter], selected: .default, enabled: [.default], peer: .canonical)
        let engine = AskLocalEngine(directory: directory, turnPolicy: policy)
        var conversation = try await app(engine).send(conversationId: "default", request: request(), token: "")
        let run = try XCTUnwrap(conversation.run), inference = try XCTUnwrap(run.inference)
        conversation = try await app(engine).inferenceResult(conversationId: conversation.id, request: .init(runId: run.id, deviceId: "device",
                inferenceId: inference.id, content: "Unchanged answer"), token: "")
        XCTAssertEqual(conversation.messages.last?.text, "Unchanged answer")
        XCTAssertEqual(conversation.run?.steps, 1)
        XCTAssertEqual(adapter.count, 2)
    }

    func testUnknownStateRemainsReadableAndExactButCannotExecute() async throws {
        let owner = try AskTurnDirectoryOwner(directory: directory), adapter = fake()
        var engine: AskLocalEngine? = AskLocalEngine(directory: directory, turnPolicy: try policy(adapter, owner: owner))
        let conversation = try await engine!.send(conversationId: "schema", request: request(), token: "")
        var record = try read(conversation.id)
        record.agentState = try AskRouteJSON.decodeRaw(Data(#"{"version":999,"opaque":123456789012345678901234567890.123456789}"#.utf8))
        let original = try record.encodeSnapshot()
        try original.write(to: directory.appendingPathComponent(conversation.id + ".json"))
        engine = nil
        let reopened = AskLocalEngine(directory: directory, turnPolicy: try policy(adapter, owner: owner))
        let loaded = try await reopened.conversation(id: conversation.id, token: "")
        XCTAssertEqual(loaded.run?.status, conversation.run?.status)
        let count = adapter.count
        do { _ = try await reopened.resume(conversationId: conversation.id, runId: conversation.run!.id, token: ""); XCTFail("Executed unknown state") } catch {}
        XCTAssertEqual(adapter.count, count)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(conversation.id + ".json")), original)
    }

    func testCohortDirectoryAndPeerRefusal() throws {
        let adapter = fake(), binding = adapter.descriptor.binding
        XCTAssertThrowsError(try AskAgentTurnPolicy(adapters: [adapter], selected: binding, enabled: [binding], peer: .canonical))
        let owner = try AskTurnDirectoryOwner(directory: directory)
        XCTAssertThrowsError(try AskTurnDirectoryOwner(directory: directory))
        XCTAssertThrowsError(try AskAgentTurnPolicy(adapters: [adapter], selected: binding, enabled: [binding], peer: .canonical, owner: owner))
        XCTAssertThrowsError(try AskAgentTurnPolicy(adapters: [adapter, adapter], selected: binding, enabled: [binding], peer: .canonical, owner: owner))
        XCTAssertThrowsError(try AskTurnDirectoryOwner(directory: AskLocalEngine.defaultDirectory))
        XCTAssertFalse(try policy(adapter, owner: owner).acceptsDirectory(directory.appendingPathComponent("other")))
        XCTAssertThrowsError(try AskAgentTurnPolicy.canonical.resolve(binding))
        XCTAssertNil(AskAgentPeerCapabilities.parse(nil))
        for raw in ["null", "{}", String(repeating: "x", count: 4097), #"{"protocolVersion":1,"contracts":[{"id":"a","version":1,"operations":["inject"]}]}"#] {
            XCTAssertNil(AskAgentPeerCapabilities.parse(raw))
        }
        XCTAssertNotNil(AskAgentPeerCapabilities.parse(AskAgentPeerCapabilities.canonical.headerValue))
    }
    func testExclusiveOwnerRefusesConcurrentEngineWriters() async throws {
        let owner = try AskTurnDirectoryOwner(directory: directory), adapter = fake()
        let policy = try policy(adapter, owner: owner)
        let first = AskLocalEngine(directory: directory, turnPolicy: policy)
        _ = try await first.send(conversationId: "owner", request: request(), token: "")
        let second = AskLocalEngine(directory: directory, turnPolicy: policy)
        do { _ = try await second.send(conversationId: "second", request: request(), token: ""); XCTFail("Shared directory writer executed") } catch {}
        XCTAssertEqual(adapter.count, 1)
        let readable = try await second.conversation(id: "owner", token: "")
        XCTAssertEqual(readable.run?.status, "waiting_inference")
    }

    func testModelContinuationUsesHostQueueAndSuspendResumes() async throws {
        for suspend in [false, true] {
            let adapter = TurnAdapter(binding: .default) { input in
                if input.turnSequence == 0 {
                    if suspend { return .suspend(state: .string("paused")) }
                    return .requestModel(prompt: input.preparedPrompt, purpose: "main", state: nil)
                }
                if !suspend, input.turnSequence == 1 {
                    return .requestModel(prompt: .object(["messages": .array([.object(["role": .string("user"), "content": .string("Continue")])])]), purpose: "main", state: .string("again"))
                }
                return .finish(content: "Completed", reasoning: "Normal answer summary", state: nil)
            }
            let policy = try AskAgentTurnPolicy(adapters: [adapter], selected: .default, enabled: [.default], peer: .canonical)
            let engine = AskLocalEngine(directory: directory.appendingPathComponent(String(suspend)), turnPolicy: policy)
            var conversation = try await engine.send(conversationId: "continuation", request: request(), token: "")
            if suspend {
                XCTAssertEqual(conversation.run?.status, "waiting_tool")
                conversation = try await engine.resume(conversationId: conversation.id, runId: conversation.run!.id, token: "")
            } else {
                for _ in 0..<2 {
                    let run = conversation.run!, inference = run.inference!
                    conversation = try await engine.inferenceResult(conversationId: conversation.id, request: .init(runId: run.id, deviceId: "device",
                inferenceId: inference.id, content: "Provider result"), token: "")
                }
            }
            XCTAssertEqual(conversation.run?.status, "completed")
            XCTAssertEqual(conversation.messages.last?.text, "Completed")
            XCTAssertEqual(conversation.messages.last?.reasoning, "Normal answer summary")
        }
    }

    func testInvalidDecisionCannotQueueModelOrExecuteTools() async throws {
        for kind in ["tool", "model", "messages", "empty", "oversized"] {
            let adapter = TurnAdapter(binding: .default) { _ in
                switch kind {
                case "tool": return .proposeTools([.init(name: "unregistered", arguments: "{}", callID: "call")], content: "", state: nil)
                case "model": return .requestModel(prompt: .object(["endpoint": .string("arbitrary")]), purpose: "main", state: nil)
                case "messages": return .requestModel(prompt: .object(["messages": .array([.object(["role": .string("inject")])])]), purpose: "main", state: nil)
                case "oversized": return .suspend(state: .string(String(repeating: "x", count: 65536)))
                default: return .finish(content: "", reasoning: nil, state: nil)
                }
            }
            let policy = try AskAgentTurnPolicy(adapters: [adapter], selected: .default, enabled: [.default], peer: .canonical)
            let engine = AskLocalEngine(directory: directory.appendingPathComponent(kind), turnPolicy: policy)
            do { _ = try await engine.send(conversationId: "invalid", request: request(), token: ""); XCTFail("Accepted invalid decision") } catch {}
            let conversation = try await engine.conversation(id: "invalid", token: "")
            XCTAssertNil(conversation.run?.inference)
            XCTAssertTrue(conversation.run?.pending.isEmpty == true)
        }
    }

    func testSummaryIntentUsesApprovedModelWithoutTools() async throws {
        let adapter = TurnAdapter(binding: .default) { input in
            .requestModel(prompt: input.preparedPrompt, purpose: "summary", state: .string("summarizing"))
        }
        let policy = try AskAgentTurnPolicy(adapters: [adapter], selected: .default, enabled: [.default], peer: .canonical)
        let engine = AskLocalEngine(directory: directory, turnPolicy: policy)
        let conversation = try await engine.send(conversationId: "summary", request: request(), token: "")
        let raw = try XCTUnwrap(conversation.run?.inference?.payload)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertNil(payload["tools"])
        XCTAssertNotNil(payload["model"])
        XCTAssertEqual(conversation.run?.status, "waiting_inference")
    }

    func testAccountAndCancellationDuringNextPreventEffects() async throws {
        let gate = TurnGate()
        let adapter = TurnAdapter(binding: .default) { input in
            await gate.wait()
            return .requestModel(prompt: input.preparedPrompt, purpose: "main", state: .string("discarded"))
        }
        let policy = try AskAgentTurnPolicy(adapters: [adapter], selected: .default, enabled: [.default], peer: .canonical)
        let engine = AskLocalEngine(directory: directory, turnPolicy: policy)
        do { _ = try await engine.send(conversationId: "wrong-account", request: request(), token: "cloud-account"); XCTFail("Accepted cloud account") } catch {}
        XCTAssertEqual(adapter.count, 0)
        let req = request()
        let pending = Task { try await engine.send(conversationId: "cancelled", request: req, token: "") }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = try await engine.conversation(id: "cancelled", token: "")
        _ = try await engine.cancel(conversationId: before.id, runId: before.run!.id, token: "")
        await gate.release()
        do { _ = try await pending.value; XCTFail("Stale adapter queued inference") } catch {}
        let after = try await engine.conversation(id: before.id, token: "")
        XCTAssertEqual(after.run?.status, "cancelled")
        XCTAssertNil(after.run?.inference)
        XCTAssertNil(try read(before.id).agentState)
    }

}

private actor TurnGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
