import Foundation
import Testing
@testable import Typeflux

@Suite("Internal task recovery", .exclusiveUIState)
@MainActor
struct AskInternalRecoveryTests {
    private let device = "device"
    private let files = AskToolDefinition(name: "files", description: "Workspace files", parameters: JSONValue(data: Data(#"{"type":"object","properties":{"action":{"type":"string","enum":["read","edit","write"]}}}"#.utf8)))

    private func call(_ id: String, _ action: String) -> AskToolCall {
        .init(id: id, function: .init(name: "files", arguments: "{\"action\":\"\(action)\",\"path\":\"solver.js\"}"))
    }

    private func finish(_ ids: [String], resolution: String = "verified", id: String = "finish") -> AskToolCall {
        let data = try! JSONSerialization.data(withJSONObject: ["resolution": resolution,
            "evidence_call_ids": ids, "explanation": "The fresh file contents show the earlier edit completed; continue with the remaining game test."])
        return .init(id: id, function: .init(name: AskInternalRecovery.toolName, arguments: String(decoding: data, as: UTF8.self)))
    }

    private func start(_ api: any AskAPI, id: String = "task", token: String = "") async throws -> AskConversation {
        var request = AskSendRequest(id: "user", deviceId: device, text: "Fix the game and play until 1024.",
                                     tools: [files], modelRef: "custom:test")
        request.maxSteps = 20
        request.clientToolApproval = true
        return try await api.send(conversationId: id, request: request, token: token)
    }

    private func answer(_ api: any AskAPI, _ c: AskConversation, calls: [AskToolCall] = [], text: String = "", token: String = "") async throws -> AskConversation {
        let run = try #require(c.run), inference = try #require(run.inference)
        return try await api.inferenceResult(conversationId: c.id, request: .init(runId: run.id,
            deviceId: device, inferenceId: inference.id, content: text, toolCalls: calls), token: token)
    }

    private func result(_ api: any AskAPI, _ c: AskConversation, id: String, status: String = "ok", token: String = "") async throws -> AskConversation {
        let run = try #require(c.run)
        return try await api.result(conversationId: c.id, request: .init(runId: run.id, deviceId: device,
            toolCallId: id, content: status == "ok" ? "Fresh solver.js contents: corrected algorithm" : "Result unavailable",
            isError: status != "ok", harness: .init(version: 1, outcome: .init(status: status, eventDispatched: status == "invalid" ? false : nil))), token: token)
    }

    private func payload(_ c: AskConversation) throws -> [String: Any] {
        let inference = try #require(c.run?.inference)
        return try #require(JSONSerialization.jsonObject(with: Data(inference.payload.utf8)) as? [String: Any])
    }

    @Test(arguments: [false, true]) func `ambiguous edit is inspected and original task continues without a user message`(budget: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root, budgetEnabled: budget)
        var c = try await start(engine)
        let runID = try #require(c.run?.id)
        let budgetRoot = c.run?.budgetRootId, budgetDeadline = c.run?.budgetDeadline
        let original = c.messages.filter { $0.role == "user" }
        c = try await answer(engine, c, calls: [call("edit", "edit"), call("queued", "write")])
        c = try await result(engine, c, id: "edit", status: "unknown")
        #expect(c.run?.id == runID && c.run?.internalRecovery?.phase == .inspecting)
        #expect(c.run?.maxSteps == 20 && c.run?.clientToolApproval == true)
        #expect(c.run?.budgetRootId == budgetRoot && c.run?.budgetDeadline == budgetDeadline)
        #expect(c.run?.pending.isEmpty == true)
        #expect(c.messages.first { $0.toolCallId == "queued" }?.harness?.outcome?.eventDispatched == false)
        let body = try payload(c)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.last?["role"] as? String == "system")
        #expect((messages.last?["content"] as? String)?.contains("original task") == true)
        let tools = try #require(body["tools"] as? [[String: Any]])
        let fileTool = try #require(tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "files" })
        let params = try #require(fileTool["parameters"] as? [String: Any])
        let properties = try #require(params["properties"] as? [String: Any])
        #expect((properties["action"] as? [String: Any])?["enum"] as? [String] == ["read"])

        // A model cannot bypass the read-only gate just by using an offered tool name.
        c = try await answer(engine, c, calls: [call("forbidden", "write")])
        #expect(c.run?.status == "waiting_inference")
        #expect(c.messages.last?.harness?.outcome?.eventDispatched == false)
        c = try await answer(engine, c, calls: [call("observation", "read")])
        c = try await result(engine, c, id: "observation")
        c = try await answer(engine, c, calls: [finish(["observation"])])
        #expect(c.run?.internalRecovery?.phase == .continued && c.run?.recoveryCheck == false)
        c = try await answer(engine, c, calls: [call("remaining-work", "write")])
        #expect(c.run?.pending.map(\.id) == ["remaining-work"])
        c = try await result(engine, c, id: "remaining-work")
        c = try await answer(engine, c, text: "The game reached 1024.")
        #expect(c.run?.status == "completed" && c.run?.id == runID)
        #expect(c.messages.filter { $0.role == "user" } == original)
        #expect(c.messages.filter { $0.toolCallId == "edit" }.count == 1)
        #expect(c.messages.last?.text == "The game reached 1024.")
    }

    @Test func `known invalid arguments return to the model without entering uncertain recovery`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        var c = try await start(engine)
        c = try await answer(engine, c, calls: [call("stale", "edit")])
        c = try await result(engine, c, id: "stale", status: "invalid")
        #expect(c.run?.internalRecovery == nil && c.run?.status == "waiting_inference")
        let body = try payload(c)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        #expect(text.contains("nothing was dispatched") && text.contains("continue the original task"))
        c = try await answer(engine, c, calls: [call("refresh", "read")])
        c = try await result(engine, c, id: "refresh")
        c = try await answer(engine, c, calls: [call("corrected", "edit")])
        #expect(c.run?.pending.first?.id == "corrected")
        #expect(c.messages.filter { $0.role == "user" }.count == 1)
    }

    @Test func `missing receipt recovery survives restart and is idempotent`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        var c = try await start(engine)
        c = try await answer(engine, c, calls: [call("missing", "edit")])
        let request = AskRecoveryRequest(runId: c.run!.id, deviceId: device, callIds: ["missing"])
        let restarted = AskLocalEngine(directory: root)
        c = try await restarted.recover(conversationId: c.id, request: request, token: "")
        let repeated = try await restarted.recover(conversationId: c.id, request: request, token: "")
        #expect(repeated.revision == c.revision)
        #expect(c.run?.internalRecovery?.phase == .inspecting && c.run?.recoveryCheck == true)
        #expect(c.messages.filter { $0.toolCallId == "missing" }.count == 1)
        let reopened = AskLocalEngine(directory: root)
        let stored = try await reopened.conversation(id: c.id, token: "")
        #expect(stored.run?.internalRecovery == c.run?.internalRecovery)
        c = try await answer(reopened, stored, calls: [call("fresh", "read")])
        c = try await result(reopened, c, id: "fresh")
        c = try await answer(reopened, c, calls: [finish(["fresh"])])
        #expect(c.run?.internalRecovery?.phase == .continued)
        #expect(c.run?.id == request.runId)
    }

    @Test func `lost inference uses same run and rejects wrong ownership or unknown call IDs`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        let original = try await start(engine)
        let run = try #require(original.run)
        for request in [AskRecoveryRequest(runId: "other", deviceId: device, callIds: []),
                        .init(runId: run.id, deviceId: "other", callIds: []),
                        .init(runId: run.id, deviceId: device, callIds: ["invented"]),
                        .init(runId: run.id, deviceId: device, callIds: [], inferenceId: "invented")] {
            await #expect(throws: (any Error).self) {
                try await engine.recover(conversationId: original.id, request: request, token: "")
            }
        }
        let request = AskRecoveryRequest(runId: run.id, deviceId: device, callIds: [], inferenceId: run.inference?.id)
        var c = try await engine.recover(conversationId: original.id, request: request, token: "")
        #expect(c.run?.id == run.id && c.run?.inference?.id != run.inference?.id)
        #expect(c.run?.internalRecovery?.handledCallIds == [run.inference!.id])
        #expect(c.messages.filter { $0.role == "user" } == original.messages.filter { $0.role == "user" })
        let repeated = try await engine.recover(conversationId: original.id, request: request, token: "")
        #expect(repeated.revision == c.revision)
        c = try await answer(engine, c, text: "Finished the original task.")
        #expect(c.run?.status == "completed")
    }

    @Test(arguments: ["missing", "old", "error", "unknown", "write", "wait", "different-run", "parallel"])
    func `verification rejects evidence that does not establish a fresh successful observation`(_ kind: String) {
        let observation = kind == "wait"
            ? AskToolCall(id: "read", function: .init(name: "computer", arguments: #"{"action":"wait"}"#))
            : call("read", kind == "write" ? "write" : "read")
        let control = finish(kind == "missing" ? ["invented"] : ["read"])
        let messages: [AskMessage] = [
            .init(id: "assistant", role: "assistant", text: "", toolCalls: [observation], createdAt: Date(), runId: "run"),
            .init(id: "result", role: "tool", text: "Observation", toolCallId: "read", isError: kind == "error", createdAt: Date(),
                  runId: kind == "different-run" ? "other" : "run",
                  harness: .init(version: 1, outcome: .init(status: kind == "unknown" ? "unknown" : "ok")))
        ]
        let c = AskConversation(id: "task", title: "Task", revision: 1, updatedAt: Date(), messages: messages,
            run: .init(id: "run", deviceId: device, status: "running", steps: 2, updatedAt: Date(), tools: [files],
                       pending: kind == "parallel" ? [control, call("write", "write")] : [control]))
        var recovery = AskInternalRecovery(handledCallIds: ["lost"], uncertainCallIds: ["lost"],
                                           evidenceStart: kind == "old" ? 2 : 0, startedStep: 1)
        let resolved = recovery.resolve(control, conversation: c)
        #expect(!resolved)
        #expect(recovery.phase == .inspecting)
    }

    @Test func `inspection is bounded and blocking does not restore writing tools`() async throws {
        var recovery = AskInternalRecovery(handledCallIds: [], uncertainCallIds: ["lost"], evidenceStart: 0, startedStep: 4)
        #expect(recovery.tools([files], step: 10).map(\.name) == [AskInternalRecovery.toolName])
        recovery.attempts = 3
        #expect(recovery.tools([files], step: 4).map(\.name) == [AskInternalRecovery.toolName])
        let control = finish([], resolution: "blocked")
        let c = AskConversation(id: "task", title: "Task", revision: 1, updatedAt: Date(), messages: [],
            run: .init(id: "run", deviceId: device, status: "running", steps: 2, updatedAt: Date(), tools: [files], pending: [control]))
        let resolved = recovery.resolve(control, conversation: c)
        #expect(resolved)
        #expect(recovery.phase == .blocked && recovery.tools([files], step: 4).isEmpty)
        #expect(recovery.prompt.contains("smallest useful user action"))
        let data = try AskCoding.encoder().encode(recovery)
        #expect(try AskCoding.decoder().decode(AskInternalRecovery.self, from: data) == recovery)
    }

    @Test func `internal inspection stays cancellable and does not ask for a recovery decision`() {
        var c = AskRecoveryFixture.conversation()
        c.run?.internalRecovery = .init(handledCallIds: ["call"], uncertainCallIds: ["call"], evidenceStart: 1, startedStep: 1)
        let entries = [AskExecutionEntry(id: "run/call", audit: AskRecoveryFixture.audit(c), receipt: nil)]
        let presentation = AskRecoveryPresentation(run: c.run, entries: entries, deviceId: device, local: true)
        #expect(!presentation.unknown)
        let phase = AskRunPhase.resolve(run: c.run, busy: true, pendingApproval: false, recovery: presentation)
        #expect(phase == .working(step: 1) && phase?.offersStop == true)
        #expect(AskRunPhase.resolve(run: c.run, busy: true, pendingApproval: true, recovery: presentation) == .approval)
    }

    @Test func `cancelled inspection never restarts automatically and explicit retry retains its gate`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        var c = try await start(engine)
        c = try await answer(engine, c, calls: [call("edit", "edit")])
        c = try await result(engine, c, id: "edit", status: "unknown")
        let originalRun = try #require(c.run)
        c = try await engine.cancel(conversationId: c.id, runId: originalRun.id, token: "")
        let id = c.id
        await #expect(throws: (any Error).self) {
            try await engine.recover(conversationId: id,
                request: .init(runId: originalRun.id, deviceId: device, callIds: ["edit"]), token: "")
        }
        c = try await engine.retry(conversationId: c.id, runId: originalRun.id, deviceId: device, modelRef: nil, token: "")
        #expect(c.run?.internalRecovery?.phase == .inspecting && c.run?.recoveryCheck == true)
        #expect(c.run?.internalRecovery?.uncertainCallIds == ["edit"])
        c = try await answer(engine, c, calls: [call("forbidden", "edit")])
        #expect(c.run?.pending.isEmpty == true)
        #expect(c.messages.last?.harness?.outcome?.eventDispatched == false)
    }

    @Test func `routing forwards internal continuation without a send or cancellation`() async throws {
        let cloud = AskTestAPI(), local = AskTestAPI()
        let api = AskApplicationAPI.routed(cloud: cloud, local: local)
        for token in ["", "cloud-token"] {
            let original = AskRecoveryFixture.conversation()
            let target = token.isEmpty ? local : cloud
            await target.seed(original)
            let c = try await api.recover(conversationId: original.id,
                request: .init(runId: original.run!.id, deviceId: device, callIds: ["call"]), token: token)
            #expect(c.run?.id == original.run?.id && c.messages == original.messages)
            #expect(await target.recoveries.count == 1)
            #expect(await target.sends.isEmpty)
            #expect(await target.cancellations.isEmpty)
        }
    }
}
