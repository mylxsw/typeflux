import Foundation
import Testing
@testable import Typeflux

@Suite("Ask implementation admission", .exclusiveUIState)
@MainActor
struct AskAgentBindingInteractionTests {
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

    @Test func stopCannotUseOldHandleToInterruptAnotherRun() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = try await startOwnedWork(fixture)
        value.revision += 10
        value.run?.id = "unknown-run"
        value.run?.agentBinding = .init(id: "future.engine", version: 1)
        await fixture.api.seed(value)
        try await fixture.model.accept(value, route: #require(fixture.model.credentials(for: value.id)))
        fixture.model.stop()
        try await fixture.wait { fixture.model.error != nil }
        #expect(fixture.tools.cancelledRuns.isEmpty)
        #expect(fixture.tools.cancelledConversations.isEmpty)
        #expect(!fixture.model.pendingApprovals.isEmpty)
        #expect(await fixture.api.cancellations.isEmpty)
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
