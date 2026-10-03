import Foundation
import Testing
@testable import Typeflux

@Suite("Ask scoped approval integration")
@MainActor
struct AskScopedApprovalTests {
    func call(_ name: String = "browser", _ action: String = "read", id: String = "call") -> AskToolCall {
        .init(id: id, function: .init(name: name, arguments: "{\"action\":\"\(action)\"}"))
    }

    func start(_ f: AskTestFixture, call: AskToolCall) async throws -> String {
        await f.api.setTool(call)
        f.model.launcherDraft.text = "Perform the requested action"
        f.model.launcherDraft.includeScreenshot = false
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        return try #require(f.model.selected?.id)
    }

    @Test func approvalCopyExistsInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let bundle = try #require(language.bundleLocalizationCandidates.lazy
                .compactMap { Bundle.appResources.path(forResource: $0, ofType: "lproj") }.first.flatMap(Bundle.init(path:)))
            for key in ["changed", "allowExact", "exactScope", "singleUse"].map({ "ask.approval." + $0 }) {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key)
            }
        }
    }

    @Test func legacyPeerNeverOffersSessionGrants() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call())
        await f.api.queueFollowUpTools([call(id: "next")])
        #expect(!f.model.canAllowForConversation(id))
        f.model.approveForConversation(id)
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: id, allowed: true)
        try await f.wait { f.model.pendingApprovals[id]?.id == "next" }
        #expect(f.tools.executions == 1)
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
    }

    @Test(arguments: ["memory", "files", "run_code", "mcp_send", "computer"])
    func everyMutationUsesTheSameSingleUseGate(_ name: String) async throws {
        let f = try AskTestFixture(approvalReuseEnabled: true)
        defer { f.model.resetSession() }
        let id = try await start(f, call: call(name, "write"))
        await f.api.queueFollowUpTools([call(name, "write", id: "next")])
        #expect(!f.model.canAllowForConversation(id))
        let oldID = try #require(f.model.approvalID(id))
        f.model.approve(conversationId: id, allowed: true, expectedApprovalID: oldID)
        try await f.wait { f.model.pendingApprovals[id]?.id == "next" }
        #expect(f.tools.executions == 1)
        f.model.approve(conversationId: id, allowed: true, expectedApprovalID: oldID)
        #expect(f.tools.executions == 1)
        #expect(f.model.pendingApprovals[id]?.id == "next")
        f.model.approve(conversationId: id, allowed: false)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.results.map(\.isError) == [false, true])
    }

    @Test(arguments: ["target", "schema", "expiry", "revocation"])
    func changedEvidenceAfterApprovalDeniesExecution(_ change: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call())
        await f.api.hold(id)
        f.model.approve(conversationId: id, allowed: true)
        switch change {
        case "target": f.tools.targetID = "other-window"
        case "schema": f.tools.bindingVersion = "replacement-schema"
        case "expiry": f.model.approvalStore.now = { .now.addingTimeInterval(301) }
        default: f.model.approvalStore.revoke(conversation: id)
        }
        await f.api.release(id)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.isError == true)
    }

    @Test func sameCallIDWithChangedArgumentsCannotUseOldApproval() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call())
        var value = try #require(f.model.selected)
        value.run?.pending[0].function.arguments = "{\"action\":\"click\",\"selector\":\"#pay\"}"
        value.revision += 1
        await f.api.seed(value)
        f.model.approve(conversationId: id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.isEmpty)
    }

    @Test func cancelledApprovalCannotAuthorizeALaterCall() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call("run_code", "invoke"))
        let approvalID = try #require(f.model.approvalID(id))
        f.model.stop(id: id)
        f.model.approve(conversationId: id, allowed: true, expectedApprovalID: approvalID)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
    }

    @Test func accountChangeDuringApprovalDeniesExecution() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call("memory", "remember"))
        f.sessionState.owner = "other-account"
        f.model.approve(conversationId: id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
    }

    @Test func consumedGrantCanStillBeRevokedBeforeDispatch() throws {
        let time = Date.now
        let request = AskToolPolicy.request(call: call(), owner: "owner", conversation: "c", run: "r", step: "s",
                                           binding: .init(target: .init(kind: "workspace", id: "target"), toolVersion: "v1", summary: "Target"),
                                           risk: .read, now: time)
        let store = AskApprovalStore(); store.now = { time }
        let id = try #require(store.issue(request))
        #expect(!store.validateDispatch(id, for: request))
        #expect(store.consume(id, for: request))
        #expect(store.validateDispatch(id, for: request))
        store.revoke(conversation: "c")
        #expect(!store.validateDispatch(id, for: request))
    }

    @Test func revocationDuringExecutorPreparationStillPreventsDispatch() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession(); f.tools.beforeBinding = nil }
        let id = try await start(f, call: call("memory", "remember"))
        var checks = 0
        f.tools.beforeBinding = {
            checks += 1
            if checks == 2 { f.model.approvalStore.revoke(conversation: id) }
        }
        f.model.approve(conversationId: id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(checks == 2)
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.isError == true)
    }

    @Test func steeringInvalidatesThePendingApproval() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let id = try await start(f, call: call("computer", "click"))
        let approvalID = try #require(f.model.approvalID(id))
        await f.api.setDeliverSteers(true)
        f.model.commandSources = AskCommandSources(skills: {
            [AskSkill(name: "inspect", description: "Inspect", body: "Inspect before acting.")]
        })
        f.model.draft.text = "Stop that action and inspect the new target"
        f.model.draft.skills = ["inspect"]
        f.model.draft.attachments = [.init(kind: .file, name: "target.txt", text: "New target")]
        f.model.draft.mcpServers = ["local-tools"]
        f.model.submitDraft()
        let queued = try #require(f.model.queuedMessages.first)
        f.model.steerQueued(queued.id)
        f.model.approve(conversationId: id, allowed: true, expectedApprovalID: approvalID)
        try await f.wait { f.model.steeringIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.steers.count == 1)
        let request = try #require(await f.api.steers.first)
        #expect(request.skills == [AskSkillUse(name: "inspect", instructions: "Inspect before acting.")])
        #expect(request.attachments?.first?.text == "New target")
        #expect(request.mcpServers == ["local-tools"])
    }
}
