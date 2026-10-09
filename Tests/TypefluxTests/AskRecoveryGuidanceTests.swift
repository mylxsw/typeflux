import Foundation
import Testing
@testable import Typeflux

@Suite("Ask recovery guidance", .serialized, .exclusiveUIState)
@MainActor
struct AskRecoveryGuidanceTests {
    @Test(arguments: [true, false], [true, false])
    func `returning to chat never changes the request or confirms an unknown outcome`(
        active: Bool, working: Bool
    ) async throws {
        let fixture = try AskTestFixture(), value = AskRecoveryFixture.conversation()
        defer { fixture.model.resetSession() }
        let audit = AskRecoveryFixture.audit(value)
        _ = try await fixture.cache.claimExecution(audit, owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        fixture.model.draft.text = "Keep this queued message"
        fixture.model.submitDraft()
        #expect(fixture.model.queuedMessages.count == 1)
        if !active {
            await fixture.model.endRecoveryRun()
        }

        fixture.model.draft.text = "Keep my unfinished message"
        fixture.model.commandFeedback = "Keep the existing feedback"
        fixture.model.inspectingRecovery = true
        fixture.model.recoveryWorking = working
        let draft = fixture.model.draft
        let queue = fixture.model.sendQueue
        let selected = fixture.model.selected
        let entries = fixture.model.selectedRecoveryEntries
        let serverValues = await fixture.api.values
        let stored = try await fixture.cache.execution(id: audit.identity.key, owner: "owner")

        fixture.model.dismissRecoveryInspector()

        #expect(fixture.model.inspectingRecovery == working)
        #expect(fixture.model.recoveryWorking == working)
        #expect(fixture.model.draft == draft)
        #expect(fixture.model.sendQueue == queue)
        #expect(fixture.model.commandFeedback == "Keep the existing feedback")
        #expect(fixture.model.selected == selected)
        #expect(fixture.model.selectedRecoveryEntries == entries)
        #expect(fixture.model.hasRecoveryNotice && fixture.model.recoveryPresentation.unknown)
        #expect(fixture.model.recoveryBlocksResume(value))
        #expect(try await fixture.cache.execution(id: audit.identity.key, owner: "owner") == stored)
        #expect(await fixture.api.values == serverValues)
        #expect(await fixture.api.sends.isEmpty)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        #expect(await fixture.api.retryModels.isEmpty)
        #expect(await fixture.api.regenerations.isEmpty)
        #expect(await fixture.api.steers.isEmpty)
        #expect(fixture.tools.executions == 0)
    }

    @Test(arguments: [true, false])
    func `guidance quotes only the original user message for the inspected run`(journal: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        #expect(fixture.model.recoveryRequestText == nil)
        var value = AskRecoveryFixture.conversation()
        value.messages = [
            message("old", text: "A different completed task", runId: "old-run"),
            message("unbound", text: "A message without run identity", runId: nil),
            message("assistant", role: "assistant", text: "A model answer", runId: "run"),
            message("steered", text: "An extra instruction", runId: "run", steered: true),
            message("original", text: "  Update my weekly plan.\n", runId: "run"),
            message("later", text: "A later user message", runId: "run"),
            message("latest", text: "The latest message is unrelated", runId: "new-run")
        ]
        if journal {
            _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        } else {
            value.run?.recovery = .init(state: "unknown", sequence: 1)
        }
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        #expect(fixture.model.recoveryRequestText == "Update my weekly plan.")
    }

    @Test func `missing request identity never falls back to a nearby message`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(value), owner: "owner")
        let invalidMessages: [[AskMessage]] = [
            [message("other", text: "A different task", runId: "old-run")],
            [message("legacy", text: "A message without run identity", runId: nil)],
            [message("steered", text: "An extra instruction", runId: "run", steered: true)],
            [message("assistant", role: "assistant", text: "A model answer", runId: "run")],
            [message("blank", text: " \n\t ", runId: "run"),
             message("later", text: "Do not substitute this message", runId: "run")],
            []
        ]
        for messages in invalidMessages {
            value.messages = messages
            value.revision += 1
            await fixture.api.seed(value)
            await fixture.model.select(value.id, reload: true)
            #expect(fixture.model.recoveryRequestText == nil)
        }
        value.run = nil
        value.messages = [message("unbound", text: "No active run", runId: nil)]
        value.revision += 1
        await fixture.api.seed(value)
        await fixture.model.select(value.id, reload: true)
        #expect(fixture.model.recoveryRequestText == nil)
    }

    @Test(arguments: ["none", "legacy", "old-run"])
    func `unrelated uncertainty never attaches the current question`(source: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.messages[0].runId = value.run?.id
        if source == "legacy" {
            _ = try await fixture.cache.claimTool(id: "run/call", owner: "owner")
            try await fixture.cache.associateTool(id: "run/call", conversationId: value.id, owner: "owner")
        } else if source == "old-run" {
            var previous = value
            previous.run?.id = "previous-run"
            _ = try await fixture.cache.claimExecution(AskRecoveryFixture.audit(previous), owner: "owner")
        }
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        if source == "none" {
            #expect(fixture.model.selectedRecoveryEntries.isEmpty)
        } else {
            #expect(fixture.model.selectedRecoveryEntries.count == 1)
            #expect(fixture.model.selectedRecoveryEntries[0].unknown)
        }
        #expect(fixture.model.recoveryRequestText == nil)
    }

    private func message(_ id: String, role: String = "user", text: String,
                         runId: String?, steered: Bool = false) -> AskMessage {
        .init(id: id, role: role, text: text, createdAt: Date(), runId: runId, steered: steered)
    }
}
