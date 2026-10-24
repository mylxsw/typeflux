import Foundation
import Testing
@testable import Typeflux

@Suite("Central tool authorization", .serialized, .exclusiveUIState)
@MainActor
struct AskToolAuthorizationTests {
    private func call(_ tool: String, _ action: String = "*") -> AskToolCall {
        .init(id: "permission-test", function: .init(name: tool, arguments: "{\"action\":\"\(action)\"}"))
    }
    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "tool-permissions-" + UUID().uuidString)!)
    }
    private func definition(_ name: String, actions: [String]) -> AskToolDefinition {
        .init(name: name, description: "Test", parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject:
            ["type": "object", "properties": ["action": ["type": "string", "enum": actions]]], options: .sortedKeys)))
    }

    @Test func everyRegisteredOperationHasAUniquePolicyAndStandardReadsAreAutomatic() {
        let entries = AskToolAuthorization.builtins
        #expect(Set(entries.map(\.id)).count == entries.count)
        for entry in entries {
            #expect(entry.defaultPermission(.standard) ==
                    ([.read, .internalState].contains(entry.effect) ? .allow : .ask))
            #expect(entry.defaultPermission(.yolo) == .allow)
            let invocation = entry.tool == "web_browser" && entry.action == "new_tab"
                ? AskToolCall(id: "new", function: .init(name: "web_browser", arguments: #"{"action":"new_tab","url":"https://example.com"}"#))
                : call(entry.tool, entry.action)
            #expect(entry.risk == AskLocalTools.builtinRisk(invocation))
        }
        for action in AskEmbeddedBrowserTool.actions {
            #expect(AskToolAuthorization.entry(for: call("web_browser", action)).effect != .unknown)
        }
        for name in AskLocalTools.workflowChatNames {
            #expect(AskToolAuthorization.entry(for: call(name)).effect != .unknown)
        }
    }

    @Test func settingsPersistPerModeAndResetOnlyTheSelectedMode() {
        let store = settings()
        let entry = AskToolAuthorization.entry(for: call("notebook", "read"))
        let revision = store.toolPermissionRevision
        store.setToolPermission(.deny, entry: entry, mode: .standard)
        #expect(store.toolPermissionRevision != revision)
        store.setToolPermission(.allow, entry: entry, mode: .strict)
        let reloaded = SettingsStore(defaults: store.defaults)
        #expect(reloaded.toolPermission(entry, mode: .standard) == .deny)
        #expect(reloaded.toolPermission(entry, mode: .strict) == .allow)
        reloaded.resetToolPermissions(mode: .standard)
        #expect(reloaded.toolPermission(entry, mode: .standard) == .allow)
        #expect(reloaded.toolPermission(entry, mode: .strict) == .allow)
    }

    @Test func newToolsAndNewActionsAppearWithoutImplicitReadGrants() {
        let store = settings()
        store.registerToolPermissions([definition("files", actions: ["read", "delete"]),
                                       definition("mcp_find", actions: ["search", "send"])], identities: ["mcp_find": "server-a"])
        #expect(store.toolPermissionEntries.contains { $0.id == "files:delete" })
        #expect(store.toolPermissionEntries.contains { $0.id == "mcp_find:search" })
        for mode in AskPermissionMode.allCases {
            #expect(store.toolPermission(call("mcp_find", "search"), mode: mode) == .ask)
            #expect(store.toolPermission(call("files", "delete"), mode: mode) == .ask)
        }
        let entry = AskToolAuthorization.entry(for: call("mcp_find", "search"), discovered: store.discoveredToolPermissions)
        store.setToolPermission(.allow, entry: entry, mode: .standard)
        #expect(store.toolPermission(call("mcp_find", "search"), mode: .standard) == .allow)
        store.registerToolPermissions([definition("mcp_find", actions: ["search", "send", "delete"])],
                                      identities: ["mcp_find": "server-a"])
        #expect(store.toolPermission(call("mcp_find", "search"), mode: .standard) == .ask)
        let updated = AskToolAuthorization.entry(for: call("mcp_find", "search"), discovered: store.discoveredToolPermissions)
        store.setToolPermission(.allow, entry: updated, mode: .standard)
        store.registerToolPermissions([definition("mcp_find", actions: ["search", "send", "delete"])],
                                      identities: ["mcp_find": "server-b"])
        #expect(store.toolPermission(call("mcp_find", "search"), mode: .standard) == .ask)
    }

    @Test func rediscoveryIsStableAndDoesNotRevokeUnchangedPermissions() {
        let store = settings()
        let tool = definition("future_tool", actions: ["read"])
        store.registerToolPermissions([tool])
        let revision = store.toolPermissionRevision
        store.registerToolPermissions([tool])
        #expect(store.toolPermissionRevision == revision)
        #expect(store.toolPermissionEntries.filter { $0.tool == "future_tool" }.count == 1)
    }

    @Test(arguments: ["notebook", "files", "browser", "web_browser"])
    func standardReadsExecuteWithoutApproval(_ name: String) async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        await f.api.setTool(call(name, "read"))
        f.model.launcherDraft = AskDraft(text: "Read", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty || !f.model.pendingApprovals.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 1)
    }

    @Test(arguments: [("notebook", "update"), ("workflow_propose", "*"), ("web_browser", "fill"), ("run_command", "*")])
    func standardWritesWaitForApproval(_ tool: String, _ action: String) async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        await f.api.setTool(call(tool, action))
        f.model.launcherDraft = AskDraft(text: "Write", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        #expect(f.tools.executions == 0)
        f.model.approve(conversationId: try #require(f.model.selectedId), allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 1)
    }

    @Test func deniedOperationDoesNotOfferApprovalOrExecute() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        let tool = call("files", "read")
        f.model.modelLibrary.settings.setToolPermission(.deny, entry: AskToolAuthorization.entry(for: tool), mode: .standard)
        await f.api.setTool(tool)
        f.model.launcherDraft = AskDraft(text: "Read", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.pendingApprovals.isEmpty)
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.isError == true)
    }

    @Test func changedPermissionDuringPreparationRevokesExecution() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        let tool = call("files", "read")
        var count = 0
        f.tools.beforeBinding = {
            count += 1
            if count == 2 {
                f.model.modelLibrary.settings.setToolPermission(.ask, entry: AskToolAuthorization.entry(for: tool), mode: .standard)
            }
        }
        await f.api.setTool(tool)
        f.model.launcherDraft = AskDraft(text: "Read", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.isError == true)
    }

    @Test func changingAPendingPermissionCancelsTheOldApproval() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        let tool = call("files", "write")
        await f.api.setTool(tool)
        f.model.launcherDraft = AskDraft(text: "Write", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        f.model.modelLibrary.settings.setToolPermission(.deny, entry: AskToolAuthorization.entry(for: tool), mode: .standard)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(f.model.pendingApprovals.isEmpty)
    }

    @Test func deniedCloudToolCannotReceiveExecutionAuthorization() async throws {
        let f = try AskTestFixture(); defer { f.model.resetSession() }
        let tool = call("web_search")
        f.model.modelLibrary.settings.setToolPermission(.deny, entry: AskToolAuthorization.entry(for: tool), mode: .standard)
        await f.api.setCloudTools([definition("web_search", actions: [])])
        await f.api.setTool(tool)
        f.model.launcherDraft = AskDraft(text: "Search", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.results.first?.approveExecution != true)
        #expect(await f.api.results.first?.isError == true)
    }
}
