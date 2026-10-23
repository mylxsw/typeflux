import Foundation
import Testing
@testable import Typeflux

/// Chat and Work (GUL-460): a chat never receives tools that act on this Mac,
/// work keeps them, and the kind is fixed by the opening message.
@Suite("Ask conversation kinds", .serialized, .exclusiveUIState)
@MainActor
struct AskConversationKindTests {
    private func definition(_ name: String) -> AskToolDefinition {
        .init(name: name, description: name, parameters: JSONValue(data: Data("{}".utf8)))
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for conversation state")
    }

    private func call(_ name: String) -> AskToolCall {
        .init(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: "{\"action\":\"read\"}"))
    }

    // MARK: - Pure rules

    @Test func unknownStoredKindReadsAsChat() {
        #expect(AskConversationKind(stored: "work") == .work)
        #expect(AskConversationKind(stored: "chat") == .chat)
        #expect(AskConversationKind(stored: "root") == .chat)
        #expect(AskConversationKind(stored: "") == .chat)
    }

    @Test func chatOffersOnlyToolsThatStayOffThisMac() {
        let names = ["computer", "browser", "files", "run_code", "run_command", "command_job", "project_files",
                     "project_terminal", "artifact", AskNotebookTool.name, AskEmbeddedBrowserTool.name, "mcp_github",
                     "skill", "memory", "generate_image"]
        let tools = names.map(definition)
        #expect(AskConversationKind.chat.offered(tools).map(\.name) == ["skill", "memory", "generate_image"])
        #expect(AskConversationKind.work.offered(tools).map(\.name) == names)
        let workflow = AskLocalTools.workflowChatNames.sorted()
        #expect(AskConversationKind.chat.offered(workflow.map(definition)).map(\.name) == workflow)
    }

    @Test func temporaryChatAlsoDropsMemory() {
        let tools = ["memory", "skill", "browser"].map(definition)
        #expect(AskConversationModel.offeredTools(tools, temporary: true, kind: .chat).map(\.name) == ["skill"])
        #expect(AskConversationModel.offeredTools(tools, temporary: false, kind: .chat).map(\.name) == ["memory", "skill"])
        #expect(AskConversationModel.offeredTools(tools, temporary: true, kind: .work).map(\.name) == ["skill", "browser"])
    }

    @Test func legacyConversationsInferTheirKindFromTheTranscript() {
        func message(_ tools: [String]) -> AskMessage {
            .init(id: UUID().uuidString, role: "assistant", text: "", toolCalls: tools.map(call), createdAt: Date())
        }
        var value = AskConversation(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: [])
        #expect(value.resolvedKind == .chat)
        value.messages = [message(["web_search", "update_plan", "read_conversation_history", "memory"])]
        #expect(value.resolvedKind == .chat, "engine and chat tools never touched this Mac")
        value.messages.append(message(["files"]))
        #expect(value.resolvedKind == .work)
        value.kind = "chat"
        #expect(value.resolvedKind == .chat, "a stored kind wins over inference")
    }

    @Test func onlyAStoredKindRefusesDispatch() {
        var value = AskConversation(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: [
            .init(id: "m", role: "assistant", text: "", toolCalls: [call("files")], createdAt: Date()),
        ])
        #expect(value.dispatchKind == .work, "a conversation from before kinds dispatches as before")
        value.kind = "chat"
        #expect(value.dispatchKind == .chat)
        value.kind = "root"
        #expect(value.dispatchKind == .chat, "an unknown stored kind never gains device tools")
    }

    @Test func summariesCarryTheKindAndFilterByIt() {
        var work = AskConversation(id: "w", title: "W", revision: 1, updatedAt: Date(), messages: [])
        work.kind = "work"
        let chat = AskConversation(id: "c", title: "C", revision: 1, updatedAt: Date(), messages: [])
        let legacy = AskConversationSummary(id: "l", title: "L")
        let items = [AskConversationSummary(work), AskConversationSummary(chat), legacy]
        #expect(items.map(\.kind) == ["work", "chat", nil])
        #expect(legacy.resolvedKind == .chat)
        #expect(items.filtered(kind: .work).map(\.id) == ["w"])
        #expect(items.filtered(kind: .chat).map(\.id) == ["c", "l"])
        #expect(items.filtered(kind: nil).count == 3)
    }

    @Test func kindSurvivesEncoding() throws {
        var draft = AskDraft()
        draft.kind = "work"
        let decoded = try AskCoding.decoder().decode(AskDraft.self, from: AskCoding.encoder().encode(draft))
        #expect(decoded.kind == "work")
        var conversation = AskConversation(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: [])
        conversation.kind = "chat"
        let copy = try AskCoding.decoder().decode(AskConversation.self, from: AskCoding.encoder().encode(conversation))
        #expect(copy.kind == "chat")
        // Snapshots written before kinds existed still decode.
        let legacy = try AskCoding.decoder().decode(AskConversation.self, from: Data(
            #"{"id":"a","title":"A","revision":1,"updated_at":"2026-10-01T00:00:00Z","messages":[]}"#.utf8))
        #expect(legacy.kind == nil)
    }

    // MARK: - Conversation model

    @Test func newConversationFollowsTheLastKindAndFixesItWhenSent() async throws {
        let f = try AskTestFixture()
        f.model.lastConversationKind = .chat
        f.model.newConversation()
        #expect(f.model.conversationKind(launcher: false) == .chat)
        #expect(f.model.canChangeConversationKind(launcher: false))
        f.model.setConversationKind(.work, launcher: false)
        #expect(f.model.draft.kind == "work")
        f.model.draft.text = "Tidy my downloads"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(await f.api.sends.last?.kind == "work")
        #expect(f.model.selected?.kind == "work")
        #expect(f.model.lastConversationKind == .work, "the next new conversation starts as work")
        #expect(f.model.conversations.first?.kind == "work")

        // A started conversation cannot change its kind, and follow-ups do not send one.
        #expect(!f.model.canChangeConversationKind(launcher: false))
        f.model.setConversationKind(.chat, launcher: false)
        #expect(f.model.conversationKind(launcher: false) == .work)
        f.model.draft.text = "And the desktop"
        f.model.submitDraft()
        try await eventually { await f.api.sends.count == 2 && f.model.busyIds.isEmpty }
        #expect(await f.api.sends.last?.kind == nil)
    }

    @Test func chatIsOfferedNoDeviceToolsWorkKeepsThem() async throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        f.model.setConversationKind(.chat, launcher: false)
        f.model.draft.text = "What is a capybara?"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        let chatTools = try #require(await f.api.sends.last?.tools)
        #expect(chatTools.isEmpty, "builtins are computer and browser only")
        #expect(f.model.selected?.kind == "chat")

        f.model.newConversation()
        f.model.setConversationKind(.work, launcher: false)
        f.model.draft.text = "Read this page"
        f.model.submitDraft()
        try await eventually { await f.api.sends.count == 2 && f.model.busyIds.isEmpty }
        #expect(await f.api.sends.last?.tools.map(\.name) == AskLocalTools.builtins.map(\.name))
    }

    @Test func launcherQuestionCarriesItsOwnKind() async throws {
        let f = try AskTestFixture()
        f.model.lastConversationKind = .work
        f.model.setConversationKind(.chat, launcher: true)
        #expect(f.model.conversationKind(launcher: true) == .chat)
        #expect(f.model.conversationKind(launcher: false) == .work, "the window's draft is untouched")
        f.model.launcherDraft.text = "Translate this"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(await f.api.sends.last?.kind == "chat")
        #expect(await f.api.sends.last?.tools.isEmpty == true)
    }

    @Test func chatRefusesADeviceToolTheModelNamesAnyway() async throws {
        let f = try AskTestFixture()
        f.model.setPermissionMode(.yolo, launcher: true)
        await f.api.setTool(call("browser"))
        f.model.setConversationKind(.chat, launcher: true)
        f.model.launcherDraft.text = "Read the page"
        f.model.submitLauncher()
        try await eventually { await !f.api.results.isEmpty && f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        #expect(f.model.pendingApprovals.isEmpty, "nothing to approve: the call is refused outright")
        let result = try #require(await f.api.results.first)
        #expect(result.isError)
        #expect(result.content.contains(L("ask.kind.chatToolRefused")))
    }

    @Test func workStillRunsDeviceTools() async throws {
        let f = try AskTestFixture()
        f.model.setPermissionMode(.yolo, launcher: true)
        await f.api.setTool(call("browser"))
        f.model.setConversationKind(.work, launcher: true)
        f.model.launcherDraft.text = "Read the page"
        f.model.submitLauncher()
        try await f.wait { f.tools.executions == 1 && f.model.busyIds.isEmpty }
        #expect(await f.api.results.first?.isError == false)
    }

    @Test func folderTurnsANewChatIntoWorkButNeverAStartedOne() async throws {
        let f = try AskTestFixture()
        let folder = AskAttachment(id: "f", kind: .folder, name: "Downloads")
        let file = AskAttachment(id: "d", kind: .file, name: "notes.txt", text: "note")

        f.model.newConversation()
        f.model.setConversationKind(.chat, launcher: false)
        f.model.applyAttachments(.init(items: [folder]), launcher: false)
        #expect(f.model.conversationKind(launcher: false) == .work)
        #expect(f.model.attachmentNotice == L("ask.kind.switchedToWork"))
        #expect(f.model.draft.attachments?.map(\.id) == ["f"])

        f.model.newConversation()
        f.model.setConversationKind(.chat, launcher: false)
        f.model.draft.text = "Hello"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        f.model.applyAttachments(.init(items: [folder, file]), launcher: false)
        #expect(f.model.conversationKind(launcher: false) == .chat)
        #expect(f.model.draft.attachments?.map(\.id) == ["d"])
        #expect(f.model.attachmentNotice == L("ask.kind.chatFolderRefused"))
    }

    @Test func switchingBackToChatDropsFolders() throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        f.model.setConversationKind(.work, launcher: false)
        f.model.draft.attachments = [AskAttachment(id: "f", kind: .folder, name: "Downloads"),
                                     AskAttachment(id: "d", kind: .file, name: "a.txt", text: "a")]
        f.model.setConversationKind(.chat, launcher: false)
        #expect(f.model.draft.attachments?.map(\.id) == ["d"])
        #expect(f.model.attachmentNotice == L("ask.kind.foldersRemoved"))

        f.model.launcherDraft.kind = "work"
        f.model.launcherDraft.attachments = [AskAttachment(id: "f", kind: .folder, name: "Downloads")]
        f.model.setConversationKind(.chat, launcher: true)
        #expect(f.model.launcherDraft.attachments == nil)
        #expect(f.model.launcherAttachmentNotice == L("ask.kind.foldersRemoved"))
    }

    // MARK: - Engine

    @Test func localEngineFixesTheKindOnTheOpeningMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-kind-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        var request = AskSendRequest(id: UUID().uuidString, deviceId: "d", text: "Hi", tools: [], modelRef: "custom:model")
        request.kind = "work"
        let id = UUID().uuidString.lowercased()
        let opened = try await engine.send(conversationId: id, request: request, token: "")
        #expect(opened.kind == "work")
        #expect(try await engine.list(token: "", offset: 0).first?.kind == "work")
        // An unknown kind from a newer client is stored as chat, never trusted as work.
        request.kind = "root"; request.id = UUID().uuidString
        let other = UUID().uuidString.lowercased()
        #expect(try await engine.send(conversationId: other, request: request, token: "").kind == "chat")
    }
}
