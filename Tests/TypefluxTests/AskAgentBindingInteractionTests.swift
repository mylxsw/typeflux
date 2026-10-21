import Foundation
import Testing
@testable import Typeflux

@Suite("Ask implementation admission", .exclusiveUIState)
@MainActor
struct AskAgentBindingInteractionTests {
    @Test func acceptanceStopBeforeRunAdmission() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.text = "Stop before sending"
        fixture.model.submitLauncher()
        #expect(fixture.model.selected != nil)
        #expect(fixture.model.selected?.run == nil)
        fixture.model.stop()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.tools.executions == 0)
        #expect(fixture.tools.definitionRequests.isEmpty)
        #expect(fixture.tools.cancelledRuns.isEmpty)
        #expect(fixture.model.pendingApprovals.isEmpty)
    }

    @Test(arguments: ["default", "unsupported"], [false, true])
    func acceptanceStopAfterObserverPrecedesSendResponse(binding: String, inference: Bool) async throws {
        let fixture = try AskTestFixture()
        let gate = CancellationGate()
        defer { gate.release(); fixture.model.resetSession() }
        await fixture.api.setBeforeSend { await gate.wait() }
        fixture.model.launcherDraft.text = "Stop after observing dispatched run"
        fixture.model.submitLauncher()
        try await fixture.wait { gate.entered }
        var observed = try #require(fixture.model.selected)
        observed.run = AskRecoveryFixture.conversation(model: inference).run
        observed.run?.agentBinding = binding == "default" ? .default : .init(id: "future.engine", version: 1)
        observed.revision += 10
        await fixture.api.seed(observed)
        // Use the real default observe polling and monitorConversation acceptance.
        // The optimistic pending message is included so the observer may publish it.
        try await fixture.wait { fixture.model.selected?.run?.id == observed.run?.id }
        #expect(fixture.model.selected?.revision == observed.revision)
        fixture.model.stop()
        try await fixture.wait { gate.cancelled }
        #expect(!gate.returned)
        #expect(fixture.tools.cancelledRuns.isEmpty)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.model.hasPendingSubmission)
        gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selected?.revision == observed.revision)
        #expect(fixture.model.hasPendingSubmission)
        #expect(fixture.tools.executions == 0)
        #expect(try await fixture.cache.executions(conversationId: observed.id, owner: "owner").isEmpty)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        #expect(await fixture.api.cancellations.isEmpty)
    }

    @Test func stopDuringResponsePersistenceDoesNotPublishTheResponse() async throws {
        let gate = CancellationGate()
        let cache = GatedConversationCache(base: try AskConversationCache.inMemory()) { value in
            if value.run != nil { await gate.wait() }
        }
        let fixture = try AskTestFixture(cacheOverride: cache)
        defer { gate.release(); fixture.model.resetSession() }
        fixture.model.launcherDraft.text = "Stop while saving response"
        fixture.model.submitLauncher()
        try await fixture.wait { gate.entered }
        fixture.model.stop()
        try await fixture.wait { gate.cancelled }
        gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selected?.run == nil)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.tools.cancelledRuns.isEmpty)
        #expect(fixture.tools.executions == 0)
    }

    @Test(arguments: ["preflight", "prepare", "send"])
    func stopBeforeDriveObservesCancellationWithoutNetworkRelease(phase: String) async throws {
        let fixture = try AskTestFixture()
        let gate = CancellationGate()
        defer { gate.release(); fixture.model.resetSession() }
        if phase == "preflight" {
            await fixture.api.setCloudModels([.init(id: "chosen", name: "Chosen")])
            await fixture.api.setBeforeModels { await gate.wait() }
            fixture.model.launcherDraft.modelRef = "cloud:chosen"
        } else if phase == "prepare" { fixture.tools.beforeDefinitions = { await gate.wait() } }
        else { await fixture.api.setBeforeSend { await gate.wait() } }
        await fixture.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: "{}")))
        fixture.model.launcherDraft.text = "Stop suspended command"
        fixture.model.submitLauncher()
        try await fixture.wait { gate.entered }
        fixture.model.stop()
        try await fixture.wait { gate.cancelled }
        #expect(fixture.model.selected?.run == nil)
        #expect(fixture.tools.cancelledRuns.isEmpty)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.model.hasPendingSubmission == (phase != "preflight"))
        gate.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.count == (phase == "send" ? 1 : 0))
        #expect(fixture.model.selected?.run == nil)
        #expect(fixture.model.hasPendingSubmission == (phase != "preflight"))
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
    }

    @Test(arguments: ["retry", "regenerate", "resume"])
    func stopExistingCommandBeforeTaskStarts(command: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.run?.status = command == "resume" ? "paused_credits" : "failed"
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        if command == "regenerate" { fixture.model.regenerate("answer") }
        else if command == "resume" { fixture.model.resumeCreditPause() }
        else { fixture.model.resume() }
        #expect(!fixture.model.busyIds.isEmpty)
        fixture.model.stop()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.retryModels.isEmpty)
        #expect(await fixture.api.regenerations.isEmpty)
        #expect(await fixture.api.resumes.isEmpty)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.tools.cancelledRuns.isEmpty)
    }

    @Test(arguments: ["account", "operation"])
    func cancelledSubmissionCannotReviveReplacement(change: String) async throws {
        let fixture = try AskTestFixture()
        let gate = CancellationGate()
        defer { gate.release(); fixture.model.resetSession() }
        await fixture.api.setBeforeSend { await gate.wait() }
        fixture.model.launcherDraft.text = "Old submission"
        fixture.model.submitLauncher()
        try await fixture.wait { gate.entered }
        let id = try #require(fixture.model.selected?.id)
        fixture.model.stop()
        try await fixture.wait { gate.cancelled }
        fixture.model.resetSession()
        if change == "account" { fixture.sessionState.owner = "other" }
        _ = fixture.model.credentials()
        var replacement = AskRecoveryFixture.conversation()
        replacement.id = id
        replacement.revision = 100
        await fixture.api.seed(replacement)
        await fixture.model.select(id)
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.resume()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        gate.release()
        // Drain the deliberately non-cooperative send; its late response must
        // neither clear the replacement's busy state nor overwrite its snapshot.
        try await fixture.wait { gate.returned }
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.model.selected?.revision == 100)
        #expect(!fixture.model.busyIds.isEmpty)
        #expect(!fixture.model.pendingApprovals.isEmpty)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.cancellations.isEmpty)
    }

    @Test(arguments: ["waiting_tool", "waiting_inference", "paused_credits", "failed", "completed"])
    func commandsRejectUnsupportedHistoryBeforeHostPreflight(status: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation(model: status == "waiting_inference")
        value.run?.status = status
        value.run?.agentBinding = .init(id: "future.engine", version: 1)
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        let definitions = fixture.tools.definitionRequests.count
        fixture.model.resume()
        fixture.model.regenerate("answer")
        fixture.model.resumeCreditPause()
        await fixture.model.endRecoveryRun()
        await fixture.model.checkAndContinueRecovery()
        #expect(fixture.model.error == L("ask.implementationUnavailable"))
        #expect(fixture.tools.definitionRequests.count == definitions)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.sends.isEmpty)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        #expect(await fixture.api.retryModels.isEmpty)
        #expect(try await fixture.cache.executions(conversationId: value.id, owner: "owner").isEmpty)
        #expect(await fixture.api.values[value.id]?.run?.status == status)
    }

    @Test(arguments: [false, true])
    func driveValidatesRefreshedRecordBeforeToolOrModel(inference: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation(model: inference)
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        value.revision += 1
        value.run?.agentBinding = .init(id: "future.engine", version: 1)
        await fixture.api.seed(value)
        fixture.model.resume()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.error != nil }
        #expect(fixture.model.error == L("ask.implementationUnavailable"))
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
        #expect(await fixture.api.inferenceResults.isEmpty)
        #expect(try await fixture.cache.executions(conversationId: value.id, owner: "owner").isEmpty)
    }

    @Test func stopWithoutOwnedWorkRejectsRefreshedUnsupportedBinding() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        value.revision += 1
        value.run?.agentBinding = .init(id: "future.engine", version: 1)
        await fixture.api.seed(value)
        fixture.model.stop()
        try await fixture.wait { fixture.model.error != nil }
        #expect(fixture.model.error == L("ask.implementationUnavailable"))
        #expect(fixture.tools.cancelledConversations.isEmpty)
        #expect(await fixture.api.values[value.id]?.run?.status == "waiting_tool")
    }

    private func startOwnedWork(_ fixture: AskTestFixture) async throws -> AskConversation {
        fixture.model.setPermissionMode(.strict, launcher: true)
        await fixture.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        fixture.model.launcherDraft.text = "Read page"
        fixture.model.submitLauncher()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        return try #require(fixture.model.selected)
    }

    private func waitForRead(_ fixture: AskTestFixture, id: String) async throws {
        for _ in 0..<1000 {
            if await fixture.api.waiting[id]?.isEmpty == false { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Stop did not reach the suspended read")
    }

    @Test(arguments: ["legacy", "default", "unsupported", "throw"])
    func stopInterruptsOwnedWorkBeforeNetworkCompletes(binding: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = try await startOwnedWork(fixture)
        if binding == "default" { value.run?.agentBinding = .default }
        if binding == "unsupported" { value.run?.agentBinding = .init(id: "future.engine", version: 1) }
        value.revision += 1
        await fixture.api.seed(value)
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        let call = try #require(value.run?.pending.first)
        let request = AskToolPolicy.request(call: call, owner: "owner", conversation: value.id,
                                            run: try #require(value.run?.id), step: "step",
                                            binding: .init(target: .init(kind: "browser_tab", id: "tab", version: "1"),
                                                           toolVersion: "1", summary: "Page", allowsReuse: true),
                                            risk: .read, reuseEnabled: true, now: .now)
        let grant = try #require(fixture.model.approvalStore.issue(request, reusable: true))
        await fixture.api.hold(value.id)
        fixture.model.stop()
        // These assertions execute before the stop Task can perform any network IO.
        #expect(fixture.tools.cancelledRuns == [.init(ownerId: "owner", conversationId: value.id, runId: value.run!.id)])
        #expect(fixture.model.approvalStore.auditScope(grant) == nil)
        await fixture.api.setTool(nil)
        try await waitForRead(fixture, id: value.id)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.pendingApprovals.isEmpty)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.model.selected?.run?.status == "waiting_tool")
        if binding == "throw" { await fixture.api.failGet(value.id) }
        await fixture.api.release(value.id)
        if binding == "unsupported" || binding == "throw" {
            try await fixture.wait { fixture.model.error != nil }
            #expect(await fixture.api.cancellations.isEmpty)
            #expect(await fixture.api.values[value.id]?.run?.status == "waiting_tool")
        } else {
            try await fixture.wait { fixture.model.selected?.run?.status == "cancelled" }
            #expect(await fixture.api.cancellations == [value.run!.id])
        }
    }

    @Test(arguments: ["account", "run"])
    func delayedStopCannotCancelReplacementWork(change: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = try await startOwnedWork(fixture)
        await fixture.api.hold(value.id)
        fixture.model.stop()
        try await waitForRead(fixture, id: value.id)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        if change == "account" {
            fixture.model.resetSession()
            fixture.sessionState.owner = "other"
            _ = fixture.model.credentials()
        }
        value.revision += 10
        value.run?.id = "replacement"
        await fixture.api.seed(value)
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        await fixture.api.release(value.id)
        await fixture.model.select(value.id)
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.resume()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        #expect(fixture.model.selected?.run?.id == "replacement")
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.tools.cancelledRuns.allSatisfy { $0.runId != "replacement" })
        #expect(fixture.tools.executions == 0)
    }

    @Test func delayedStopCannotCancelNewOperationOnSameRun() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let value = try await startOwnedWork(fixture)
        await fixture.api.hold(value.id)
        fixture.model.stop()
        try await waitForRead(fixture, id: value.id)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.resume()
        // The new generation is installed synchronously before the old read returns.
        await fixture.api.release(value.id)
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        #expect(fixture.model.selected?.run?.id == value.run?.id)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(fixture.tools.executions == 0)
    }

    @Test(arguments: ["default", "unsupported", "absent"])
    func stopCannotUseOldHandleToInterruptAnotherRun(binding: String) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = try await startOwnedWork(fixture)
        let ownedRunId = try #require(value.run?.id)
        value.revision += 10
        value.run?.id = "unknown-run"
        value.run?.agentBinding = binding == "default" ? .default : .init(id: "future.engine", version: 1)
        if binding == "absent" { value.run = nil }
        await fixture.api.seed(value)
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        fixture.model.stop()
        #expect(fixture.tools.cancelledRuns == [.init(ownerId: "owner", conversationId: value.id, runId: ownedRunId)])
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.pendingApprovals.isEmpty)
        #expect(fixture.tools.cancelledConversations.isEmpty)
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.cancellations.isEmpty)
        #expect(await fixture.api.values[value.id]?.run == value.run)
        #expect(fixture.model.selected?.run == value.run)
    }

    @Test func approvalReloadCannotAdmitUnsupportedRecord() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.setPermissionMode(.strict, launcher: true)
        await fixture.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        fixture.model.launcherDraft.text = "Read page"
        fixture.model.submitLauncher()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        var value = try #require(fixture.model.selected)
        value.revision += 1
        value.run?.agentBinding = .init(id: "future.engine", version: 1)
        await fixture.api.seed(value)
        fixture.model.approve(conversationId: value.id, allowed: true)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.error == L("ask.implementationUnavailable"))
        #expect(fixture.tools.executions == 0)
        #expect(await fixture.api.results.isEmpty)
        #expect(try await fixture.cache.executions(conversationId: value.id, owner: "owner").isEmpty)
    }
}

/// Deliberately ignores cancellation until released, like a transport that has
/// already dispatched. The handler proves Stop cancelled its caller immediately.
@MainActor
private final class CancellationGate {
    var entered = false
    var cancelled = false
    var returned = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuations.append($0); entered = true }
        } onCancel: {
            Task { @MainActor in self.cancelled = true }
        }
        returned = true
    }
    func release() { continuations.forEach { $0.resume() }; continuations = [] }
}

actor GatedConversationCache: AskCaching {
    let base: any AskCaching
    let beforeSave: @Sendable (AskConversation) async -> Void
    init(base: any AskCaching, beforeSave: @escaping @Sendable (AskConversation) async -> Void) {
        self.base = base; self.beforeSave = beforeSave
    }
    func save(_ conversation: AskConversation, owner: String) async throws {
        await beforeSave(conversation)
        try await base.save(conversation, owner: owner)
    }
    func execution(id: String, owner: String) async throws -> AskExecutionEntry? { try await base.execution(id: id, owner: owner) }
    func executions(conversationId: String, owner: String) async throws -> [AskExecutionEntry] { try await base.executions(conversationId: conversationId, owner: owner) }
    func claimExecution(_ audit: AskExecutionAudit, owner: String) async throws -> Bool { try await base.claimExecution(audit, owner: owner) }
    func saveRejectedToolReceipt(audit: AskExecutionAudit, receipt: AskToolResultRequest, owner: String) async throws { try await base.saveRejectedToolReceipt(audit: audit, receipt: receipt, owner: owner) }
    func saveReceipt(_ receipt: AskExecutionReceipt, identity: AskExecutionIdentity, owner: String) async throws { try await base.saveReceipt(receipt, identity: identity, owner: owner) }
    func recordExecution(id: String, event: AskExecutionAudit.Event, owner: String) async throws { try await base.recordExecution(id: id, event: event, owner: owner) }
    func load(id: String, owner: String) async throws -> AskConversation? { try await base.load(id: id, owner: owner) }
    func list(owner: String) async throws -> [AskConversationSummary] { try await base.list(owner: owner) }
    func delete(id: String, owner: String) async throws { try await base.delete(id: id, owner: owner) }
    func saveDraft(_ draft: AskDraft, key: String, owner: String) async throws { try await base.saveDraft(draft, key: key, owner: owner) }
    func draft(key: String, owner: String) async throws -> AskDraft? { try await base.draft(key: key, owner: owner) }
    func savedChatDrafts(owner: String) async throws -> [AskSavedChatDraft] { try await base.savedChatDrafts(owner: owner) }
    func associateTool(id: String, conversationId: String, owner: String) async throws { try await base.associateTool(id: id, conversationId: conversationId, owner: owner) }
    func claimTool(id: String, owner: String) async throws -> Bool { try await base.claimTool(id: id, owner: owner) }
    func saveToolResult(_ result: AskToolResultRequest, owner: String) async throws { try await base.saveToolResult(result, owner: owner) }
    func toolResult(id: String, owner: String) async throws -> AskToolResultRequest? { try await base.toolResult(id: id, owner: owner) }
}
