import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask permission modes", .serialized)
@MainActor
struct AskPermissionModeTests {
    private func call(_ name: String, _ action: String = "read", id: String = "call") -> AskToolCall {
        .init(id: id, function: .init(name: name, arguments: "{\"action\":\"\(action)\"}"))
    }

    @Test func policyMatrixAndExactCommands() {
        for risk in [AskToolRisk.none, .read, .write, .destructive] {
            #expect(!AskPermissionMode.strict.automaticallyAllows(risk))
            #expect(AskPermissionMode.standard.automaticallyAllows(risk) == (risk < .write))
            #expect(AskPermissionMode.yolo.automaticallyAllows(risk))
        }
        for mode in AskPermissionMode.allCases {
            #expect(AskPermissionMode.command("  /mode \(mode.rawValue) \n").mode == mode)
            #expect(!mode.title.isEmpty && !mode.detail.isEmpty && !mode.symbol.isEmpty)
        }
        for text in ["/mode", "/mode unknown", "/mode yolo send everything", "/mode YOLO"] {
            #expect(AskPermissionMode.command(text).recognized)
            #expect(AskPermissionMode.command(text).mode == nil)
        }
        for text in ["Please use /mode yolo", "/model yolo", "`/mode yolo`", ""] {
            #expect(!AskPermissionMode.command(text).recognized)
        }
    }

    @Test func commandsStayLocalAndNewConversationsReset() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        #expect(f.model.permissionMode(launcher: false) == .standard)
        f.model.draft.text = "/mode yolo"
        f.model.submitDraft()
        #expect(f.model.permissionMode(launcher: false) == .yolo)
        #expect(f.model.draft.text.isEmpty)
        #expect(await f.api.sends.isEmpty)
        f.model.newConversation()
        #expect(f.model.permissionMode(launcher: false) == .standard)
        f.model.launcherDraft.text = "/mode strict"
        f.model.submitLauncher()
        #expect(f.model.permissionMode(launcher: true) == .strict)
        f.model.launcherDraft.text = "/mode invalid"
        f.model.submitLauncher()
        #expect(f.model.launcherDraft.text == "/mode invalid")
        #expect(f.model.commandFeedback == L("ask.mode.usage"))
        #expect(await f.api.sends.isEmpty)
        f.model.resetSession()
        #expect(f.model.permissionMode(launcher: true) == .standard)
    }

    @Test func initialModeSelectionPreservesUnsentContextAndStorageChoice() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.newConversation(storesLocally: true)
        f.model.draft.text = "Keep this draft"
        f.model.draft.selection = "Selected text"
        f.model.setPermissionMode(.strict, launcher: false)
        #expect(f.model.draft.text == "Keep this draft")
        #expect(f.model.draft.selection == "Selected text")
        #expect(f.model.storesLocally(launcher: false))
        #expect(f.model.permissionMode(launcher: false) == .strict)
    }

    @Test(arguments: AskPermissionMode.allCases)
    func differentReadCallsFollowMode(_ mode: AskPermissionMode) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.setPermissionMode(mode, launcher: true)
        await f.api.setTool(call("files"))
        await f.api.queueFollowUpTools([call("memory", "list", id: "second")])
        f.model.launcherDraft = AskDraft(text: "Read files", includeScreenshot: false)
        f.model.submitLauncher()
        if mode == .strict {
            try await f.wait { !f.model.pendingApprovals.isEmpty }
            let id = try #require(f.model.selectedId)
            #expect(f.tools.executions == 0)
            f.model.approve(conversationId: id, allowed: true)
            try await f.wait { f.model.pendingApprovals[id]?.id == "second" }
            #expect(f.tools.executions == 1)
            f.model.approve(conversationId: id, allowed: true)
        }
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 2)
        #expect(f.model.permissionMode(launcher: true) == .standard)
        #expect(f.model.permissionMode(launcher: false) == mode)
    }

    @Test(arguments: ["files", "run_code", "mcp_unknown", "generate_image"])
    func yoloResumesPendingWritesAndUnknownTools(_ tool: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(call(tool, "write"))
        f.model.launcherDraft = AskDraft(text: "Perform task", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        #expect(f.tools.executions == 0)
        f.model.draft.text = "/mode yolo"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 1)
        #expect(await f.api.sends.count == 1)
        #expect(f.model.sendQueue.messages( f.model.selectedId ?? "").isEmpty)
        f.model.stop()
        #expect(f.model.permissionMode(launcher: false) == .standard)
    }

    @Test func downgradeDuringPreparationRevokesAutomaticGrant() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.setPermissionMode(.yolo, launcher: true)
        await f.api.setTool(call("files", "write"))
        var bindings = 0
        f.tools.beforeBinding = {
            bindings += 1
            if bindings == 2 { f.model.setPermissionMode(.strict, launcher: false) }
        }
        f.model.launcherDraft = AskDraft(text: "Write", includeScreenshot: false)
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.isError == true)
    }

    @Test func modePaletteWorksWhileBusyAndDoesNotTrustMCPAnnotations() throws {
        var context = AskCommandContext(); context.busy = true; context.permissionMode = .yolo
        let command = try #require(AskCommandCatalog.commands(context).first { $0.name == "mode" })
        #expect(command.enabled)
        let choices = AskCommandCatalog.submenu(command.action, context: context)
        #expect(choices.map(\.name) == ["strict", "standard", "yolo"])
        #expect(choices.last?.selected == true)
        let f = try AskTestFixture()
        f.model.runCommand(choices[2], launcher: false)
        #expect(f.model.permissionMode(launcher: false) == .yolo)
        f.model.newConversation()
        #expect(f.model.permissionMode(launcher: false) == .standard)
        #expect(f.model.toolRisk(call("mcp_read"), cloudDefinition: nil) == .destructive)
        f.model.resetSession()
    }

    @Test(arguments: AskPermissionMode.allCases)
    func cloudSearchUsesTheSameLocalPolicy(_ mode: AskPermissionMode) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let definition = AskToolDefinition(name: "web_search", description: "Search", parameters: JSONValue(data: Data("{}".utf8)))
        await f.api.setCloudTools([definition])
        await f.api.setTool(call("web_search"))
        f.model.setPermissionMode(mode, launcher: true)
        f.model.launcherDraft = AskDraft(text: "Search", includeScreenshot: false)
        f.model.submitLauncher()
        if mode == .strict {
            try await f.wait { !f.model.pendingApprovals.isEmpty }
            #expect(await f.api.results.isEmpty)
            f.model.approve(conversationId: try #require(f.model.selectedId), allowed: true)
        }
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(await f.api.results.first?.approveExecution == true)
        #expect(f.model.cloudApprovals.isEmpty)
    }

    @Test func accountSwitchRevokesModes() throws {
        let f = try AskTestFixture()
        f.model.setPermissionMode(.yolo, launcher: true)
        f.sessionState.owner = "another-owner"
        _ = f.model.credentials()
        #expect(f.model.permissionMode(launcher: true) == .standard)
        #expect(f.model.permissionModes.isEmpty)
        f.model.resetSession()
    }
}
