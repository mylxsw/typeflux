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

    @Test func stopLoadsBindingBeforeCancellingHostProcesses() async throws {
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
