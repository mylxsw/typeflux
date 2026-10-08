import Foundation
import Testing
@testable import Typeflux

@Suite("Ask recovery wire")
struct AskRecoveryWireTests {
    @Test func `frozen R 03 fixture keeps every wire status and unknown version is inert`() throws {
        struct Case: Decodable { var jobState: String; var wireStatus: String; var recovery: AskRunRecovery }
        struct Fixture: Decodable { var cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/harness/fixtures/r03-recovery-v1.json")
        let fixture = try AskCoding.decoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 9)
        for example in fixture.cases {
            var conversation = AskRecoveryFixture.conversation()
            conversation.run?.status = example.wireStatus; conversation.run?.recovery = example.recovery
            let decoded = try AskCoding.decoder().decode(
                AskConversation.self,
                from: AskCoding.encoder().encode(conversation)
            )
            #expect(decoded.run?.recovery?.state == example.jobState)
            #expect(decoded.run?.recovery?.blocksExecution == (example.jobState == "unknown_outcome"))
            #expect(decoded.run?.isActive == [
                "queued",
                "running",
                "unknown_outcome",
                "waiting_device",
                "waiting_inference"
            ].contains(example.jobState))
        }
        for wire in [#"{"version":2,"state":"waiting_device","sequence":7}"#,
                     #"{"version":1,"state":"new_state","sequence":7}"#,
                     #"{"version":1,"state":"running","sequence":-1}"#,
                     #"{"version":"bad","state":[],"sequence":"bad"}"#, "{}", "[]"] {
            #expect(try AskCoding.decoder().decode(AskRunRecovery.self, from: Data(wire.utf8)).blocksExecution)
        }
        var future = AskRecoveryFixture.conversation()
        future.run?.status = "future_queued"
        #expect(future.run?.isActive == true && future.run?.needsRecoveryInspection == true)
        let phase = AskRunPhase.resolve(run: future.run, busy: false, pendingApproval: false,
                                        recovery: .init(run: future.run, entries: [], deviceId: "device", local: false))
        #expect(phase?.isWorking == false && phase?.tone == .attention)
        let old = AskRecoveryFixture.conversation()
        #expect(try AskCoding.decoder().decode(AskConversation.self, from: AskCoding.encoder().encode(old)).run?
            .recovery == nil)
    }

    @Test func `delayed SSE cannot resurrect terminal content even with new usage or recovery sequence`() throws {
        var terminal = AskRecoveryFixture.conversation()
        terminal.run?.status = "cancelled"; terminal.revision = 5
        terminal.run?.pending = []; terminal.run?.recovery = .init(state: "cancelled", sequence: 9)
        var late = terminal
        late.run?.status = "waiting_tool"; late.revision = 4
        late.run?.recovery = .init(state: "waiting_device", sequence: 10)
        var stream = AskConversationStreamState()
        func wire(_ value: AskConversation) throws -> String {
            try #require(String(data: AskCoding.encoder().encode(value), encoding: .utf8))
        }
        _ = try stream.consume(event: "snapshot", data: wire(terminal))
        _ = try stream.consume(event: "progress", data: wire(late))
        #expect(stream.value?.run?.status == "cancelled" && stream.value?.revision == 5)
        late.revision = 6
        _ = try stream.consume(event: "snapshot", data: wire(late))
        #expect(stream.value?.run?.status == "cancelled" && stream.value?.messages.map(\.text) == terminal.messages
            .map(\.text))
        var nextRun = terminal
        nextRun.run?.id = "new-run"; nextRun.run?.status = "waiting_tool"
        nextRun.revision = 6; nextRun.run?.recovery = .init(state: "waiting_device", sequence: 1)
        _ = try stream.consume(event: "snapshot", data: wire(nextRun))
        #expect(stream.value?.run?.id == "new-run")
        _ = try stream.consume(event: "snapshot", data: wire(late))
        #expect(stream.value?.run?.id == "new-run")
        var advance = nextRun
        advance.run?.recovery = .init(state: "unknown_outcome", sequence: 2)
        _ = try stream.consume(event: "progress", data: wire(advance))
        #expect(stream.value?.run?.recovery?.state == "unknown_outcome")
        #expect(try stream.consume(event: "progress", data: wire(advance)) == nil)
        advance.id = "other"
        #expect(try stream.consume(event: "progress", data: wire(advance)) == nil)
    }

    @Test func `stored waiting inference survives offline restart and late metering keeps memory purged`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root, budgetEnabled: true)
        let started = try await engine.send(
            conversationId: "local",
            request: .init(id: "question", deviceId: "device", text: "Question", tools: [], modelRef: "custom:model"),
            token: ""
        )
        let run = try #require(started.run), inference = try #require(run.inference)
        let receipt = AskInferenceResult(
            runId: run.id,
            deviceId: run.deviceId,
            inferenceId: inference.id,
            content: "Saved result",
            usage: .init(promptTokens: 5, completionTokens: 7, totalTokens: 12)
        )
        let restarted = AskLocalEngine(directory: root, now: { Date().addingTimeInterval(1200) }, budgetEnabled: true)
        #expect(try await restarted.conversation(id: "local", token: "").run?.status == "waiting_inference")
        _ = try await restarted.cancel(conversationId: "local", runId: run.id, token: "")
        // Retry uses the original deadline; this remains an independent receipt, even after stop.
        let afterRetry = try await restarted.retry(
            conversationId: "local",
            runId: run.id,
            deviceId: run.deviceId,
            modelRef: nil,
            token: ""
        )
        try await restarted.purgeMemory(token: "")
        let again = AskLocalEngine(directory: root, budgetEnabled: true)
        let late = try await again.inferenceResult(conversationId: "local", request: receipt, token: "")
        #expect(late.run?.id == afterRetry.run?.id && late.run?.budgetRootId == run.budgetRootId)
        #expect(late.run?.budget?.actual.tokens == 12 && late.memory == nil)
        #expect(!late.messages.contains { $0.text == receipt.content })
        let duplicate = try await again.inferenceResult(conversationId: "local", request: receipt, token: "")
        #expect(duplicate.run?.budget?.version == late.run?.budget?.version)
    }

    @Test func `interrupted local builtin is unknown across restart and explicit cancel retains it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var value = AskRecoveryFixture.conversation()
        value.run?.status = "running"
        try AskCoding.encoder().encode(AskLocalRecord(conversation: value))
            .write(to: root.appendingPathComponent(value.id + ".json"))
        let restarted = AskLocalEngine(directory: root)
        let unknown = try await restarted.conversation(id: value.id, token: "")
        #expect(unknown.run?.isActive == true && unknown.run?.recovery?.blocksExecution == true)
        let cancelled = try await restarted.cancel(conversationId: value.id, runId: "run", token: "")
        #expect(cancelled.run?.status == "cancelled" && cancelled.run?.recovery?.state == "unknown_outcome")
    }
}
