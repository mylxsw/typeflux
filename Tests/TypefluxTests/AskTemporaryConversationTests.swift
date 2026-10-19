import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// A temporary conversation (GUL-370) never enters history or memory, lives only in
/// memory on this Mac, and ends when the user leaves it unless they keep it.
@Suite("Ask temporary conversations", .serialized, .exclusiveUIState)
@MainActor
struct AskTemporaryConversationTests {
    /// A signed-in fixture with one of the user's own models, so a temporary chat can run on this Mac too.
    private func fixture(signedIn: Bool = true, workspaces: AskConversationWorkspaceStore? = nil) throws -> (AskTestFixture, String) {
        let suite = "ask-temporary-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = AskModelProfile(name: "My model", baseURL: "https://models.example/v1", model: "my-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let fixture = try AskTestFixture(localOnly: !signedIn, modelLibrary: library, workspaces: workspaces)
        return (fixture, profile.reference)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for temporary conversation state")
    }

    /// Starts a temporary chat and waits for its answer.
    private func startTemporary(_ fixture: AskTestFixture, model: String? = nil,
                                text: String = "Is this safe to take with wine?") async throws -> String {
        fixture.model.newConversation(temporary: true)
        fixture.model.draft.text = text
        if let model { fixture.model.draft.modelRef = model }
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        return try #require(fixture.model.selectedId)
    }

    // MARK: - Starting

    @Test func aCloudTemporaryChatStaysOutOfHistoryCacheMemoryAndTitles() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.newConversation(temporary: true)
        #expect(fixture.model.isTemporaryComposer(launcher: false))
        #expect(fixture.model.storageKind(launcher: false) == .temporary)
        #expect(fixture.model.draft.memory?.isEmpty != false, "a temporary draft offers no memory")
        // It may still use Cloud models.
        #expect(fixture.model.cloudAvailable)
        fixture.model.draft.memory = AskMemory(global: "Likes green tea")
        let id = try await startTemporary(fixture)

        let request = try #require(await fixture.api.sends.last)
        #expect(request.temporary == true)
        #expect(request.memory == nil)
        #expect(request.titlePolicy?.enabled == false)
        #expect(await fixture.localAPI.sends.isEmpty)
        #expect(fixture.model.temporaryConversation == AskTemporaryConversation(id: id, cloud: true))
        #expect(fixture.model.isTemporary(id) && fixture.model.showsTemporaryConversation)
        #expect(!fixture.model.isLocal(id))
        #expect(fixture.model.cacheOwner(id) == AskRoutedAPI.temporaryOwner)
        #expect(fixture.model.displayTitle(for: id) == L("ask.temporary.title"))
        #expect(fixture.model.displayTitle(for: "other") == nil)
        // Never listed, never written to the persistent cache under any owner.
        #expect(!fixture.model.conversations.contains { $0.id == id })
        #expect(try await fixture.cache.load(id: id, owner: fixture.sessionState.owner) == nil)
        #expect(try await fixture.cache.load(id: id, owner: AskRoutedAPI.temporaryOwner) == nil)
        #expect(try await fixture.cache.load(id: id, owner: AskRoutedAPI.localOwner) == nil)
        // The model still reads it back from its in-memory partition.
        #expect(try await fixture.model.cache.load(id: id, owner: AskRoutedAPI.temporaryOwner) != nil)
        await fixture.model.refreshHistory()
        #expect(!fixture.model.conversations.contains { $0.id == id })

        // A follow-up stays in the same temporary conversation.
        fixture.model.draft.text = "And with coffee?"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.messages.count == 4 }
        #expect(await fixture.api.sends.count == 2)
        #expect(await fixture.api.sends.last?.temporary == nil)
        #expect(fixture.model.selectedId == id)
        #expect(!fixture.model.conversations.contains { $0.id == id })
        #expect(fixture.model.storageKind(launcher: false) == .temporary)
        #expect(!fixture.model.canChooseStorage(launcher: false))
    }

    @Test func anOwnModelTemporaryChatRunsOnThisMacOnly() async throws {
        let (fixture, own) = try fixture()
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture, model: own)
        #expect(await fixture.localAPI.sends.count == 1)
        #expect(await fixture.localAPI.sends.first?.temporary == true)
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.temporaryConversation?.cloud == false)
        #expect(fixture.model.isLocal(id))
        #expect(fixture.model.localConversationIds.isEmpty)
        #expect(fixture.model.credentials(for: id)?.token == "")
        #expect(fixture.model.credentials(for: id)?.owner == AskRoutedAPI.temporaryOwner)
        #expect(try await fixture.cache.load(id: id, owner: AskRoutedAPI.localOwner) == nil)
    }

    @Test func signedOutATemporaryChatRunsOnTheUsersModel() async throws {
        let (fixture, own) = try fixture(signedIn: false)
        defer { fixture.model.resetSession() }
        #expect(AskLocalModeStatus.make(model: fixture.model, signedIn: false).choices == [.local, .temporary])
        fixture.model.chooseStorage(.temporary, launcher: false)
        #expect(fixture.model.isTemporaryComposer(launcher: false))
        fixture.model.chooseStorage(.cloud, launcher: false)
        #expect(!fixture.model.isTemporaryComposer(launcher: false), "signed out, Cloud falls back to this Mac")
        let id = try await startTemporary(fixture, model: own)
        #expect(fixture.model.temporaryConversation?.cloud == false)
        #expect(await fixture.api.sends.first?.temporary == true)
        await fixture.model.refreshHistory()
        #expect(!fixture.model.conversations.contains { $0.id == id })
    }

    @Test func theMemoryToolIsNeverOfferedToATemporaryChat() {
        let tools = [AskToolDefinition(name: "memory", description: "", parameters: .init(data: Data(#"{"type":"object"}"#.utf8))),
                     AskToolDefinition(name: "browser", description: "", parameters: .init(data: Data(#"{"type":"object"}"#.utf8)))]
        #expect(AskConversationModel.offeredTools(tools, temporary: true).map(\.name) == ["browser"])
        #expect(AskConversationModel.offeredTools(tools, temporary: false).map(\.name) == ["memory", "browser"])
    }

    // MARK: - Leaving

    @Test func leavingAsksAndCancelKeepsTheTemporaryChat() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture)
        var asked = 0
        fixture.model.confirmTemporaryLeave = { asked += 1; return .init(choice: .cancel) }
        fixture.model.newConversation()
        #expect(asked == 1)
        #expect(fixture.model.selectedId == id)
        #expect(fixture.model.temporaryConversation?.id == id)
        await fixture.api.seed(.init(id: "other", title: "Other", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.select("other")
        #expect(asked == 2)
        #expect(fixture.model.selectedId == id)
        // Re-selecting itself is not leaving.
        await fixture.model.select(id, reload: true)
        #expect(asked == 2)
    }

    @Test func endingDeletesEveryCopyAndForgetsTheConversation() async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-temporary-workspaces-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspaces = AskConversationWorkspaceStore(rootURL: workspaceRoot)
        let (fixture, _) = try fixture(workspaces: workspaces)
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture)
        let folder = try await workspaces.ensure(owner: fixture.sessionState.owner, conversationId: id)
        try Data("temporary".utf8).write(to: folder.appendingPathComponent("work/notes.txt"))
        fixture.model.confirmTemporaryLeave = { .init(choice: .end) }
        await fixture.api.seed(.init(id: "other", title: "Other", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.select("other")
        #expect(fixture.model.selectedId == "other")
        #expect(fixture.model.temporaryConversation == nil)
        #expect(!fixture.model.isTemporary(id))
        try await eventually { await fixture.api.deletes.contains(id) }
        try await eventually { !FileManager.default.fileExists(atPath: folder.path) }
        try await eventually { (try? await fixture.model.cache.load(id: id, owner: AskRoutedAPI.temporaryOwner)) == nil }
        #expect(await fixture.api.values[id] == nil)
        #expect(!fixture.model.conversations.contains { $0.id == id })
    }

    @Test func dontAskAgainTurnsTheConfirmationOff() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        var asked = 0
        fixture.model.confirmTemporaryLeave = { asked += 1; return .init(choice: .end, suppress: true) }
        _ = try await startTemporary(fixture)
        fixture.model.newConversation()
        #expect(asked == 1)
        #expect(!fixture.model.modelLibrary.settings.askConfirmLeavingTemporary)
        let second = try await startTemporary(fixture)
        fixture.model.newConversation()
        #expect(asked == 1, "no longer asked")
        #expect(fixture.model.temporaryConversation == nil)
        try await eventually { await fixture.api.deletes.contains(second) }
        fixture.model.modelLibrary.settings.askConfirmLeavingTemporary = true
    }

    @Test func anEmptyTemporaryDraftIsLeftWithoutAsking() throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        var asked = 0
        fixture.model.confirmTemporaryLeave = { asked += 1; return .init(choice: .cancel) }
        fixture.model.newConversation(temporary: true)
        fixture.model.newConversation()
        #expect(asked == 0)
        #expect(!fixture.model.isTemporaryComposer(launcher: false))
    }

    @Test func endingFromTheHeaderNeedsNoConfirmation() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture)
        fixture.model.confirmTemporaryLeave = { Issue.record("must not ask"); return .init(choice: .cancel) }
        fixture.model.endTemporaryConversation()
        #expect(fixture.model.selectedId == nil)
        #expect(fixture.model.temporaryConversation == nil)
        #expect(fixture.model.commandFeedback == L("ask.temporary.ended"))
        try await eventually { await fixture.api.deletes.contains(id) }
    }

    // MARK: - Keeping

    @Test func keepingACloudChatListsItAndMovesItToTheAccount() async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-kept-workspaces-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspaces = AskConversationWorkspaceStore(rootURL: workspaceRoot)
        let (fixture, _) = try fixture(workspaces: workspaces)
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture)
        let folder = try await workspaces.ensure(owner: fixture.sessionState.owner, conversationId: id)
        fixture.model.keepTemporaryConversation()
        try await fixture.wait { fixture.model.temporaryConversation == nil }
        #expect(await fixture.api.keeps == [id])
        #expect(fixture.model.conversations.first?.id == id)
        #expect(!fixture.model.isLocal(id))
        #expect(fixture.model.selectedId == id)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(fixture.model.commandFeedback == L("ask.temporary.kept.cloud"))
        #expect(try await fixture.cache.load(id: id, owner: fixture.sessionState.owner) != nil)
        #expect(try await fixture.model.cache.load(id: id, owner: AskRoutedAPI.temporaryOwner) == nil)
        await fixture.model.refreshHistory()
        #expect(fixture.model.conversations.contains { $0.id == id })
        // Ordinary now: leaving it asks nothing and deletes nothing.
        fixture.model.confirmTemporaryLeave = { Issue.record("must not ask"); return .init(choice: .cancel) }
        fixture.model.newConversation()
        #expect(await fixture.api.deletes.contains(id) == false)
    }

    @Test func keepingAnOwnModelChatMakesItPrivate() async throws {
        let (fixture, own) = try fixture()
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture, model: own)
        fixture.model.confirmTemporaryLeave = { .init(choice: .keep) }
        fixture.model.newConversation()
        #expect(fixture.model.selectedId == nil)
        try await fixture.wait { fixture.model.conversations.contains { $0.id == id } }
        #expect(await fixture.localAPI.keeps == [id])
        #expect(fixture.model.localConversationIds.contains(id))
        #expect(fixture.model.isLocal(id))
        #expect(fixture.model.temporaryConversation == nil)
        #expect(fixture.model.commandFeedback == L("ask.temporary.kept.local"))
        #expect(try await fixture.cache.load(id: id, owner: AskRoutedAPI.localOwner) != nil)
        #expect(await fixture.localAPI.deletes.contains(id) == false)
    }

    @Test func aFailedKeepReportsAndLeavesItTemporary() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        let id = try await startTemporary(fixture)
        await fixture.api.setFailKeep(true)
        fixture.model.keepTemporaryConversation()
        try await fixture.wait { fixture.model.error == L("ask.temporary.keepFailed") }
        #expect(fixture.model.temporaryConversation?.id == id)
        #expect(!fixture.model.conversations.contains { $0.id == id })
    }

    @Test func aChatBeingKeptIsNeverDeletedByTheNextTemporaryChat() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        let first = try await startTemporary(fixture)
        fixture.model.confirmTemporaryLeave = { .init(choice: .keep) }
        fixture.model.newConversation(temporary: true)
        // The next one starts before the keep request has answered.
        fixture.model.draft.text = "Another question"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.conversations.contains { $0.id == first } }
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        #expect(await fixture.api.deletes.contains(first) == false)
        #expect(fixture.model.temporaryConversation?.id == fixture.model.selectedId)
        #expect(fixture.model.temporaryConversation?.id != first)
    }

    // MARK: - Launcher, commands and the storage card

    @Test func aTemporaryLauncherQuestionLeavesNoInputHistory() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.toggleTemporary(launcher: true)
        #expect(fixture.model.isTemporaryComposer(launcher: true))
        #expect(fixture.model.storageKind(launcher: true) == .temporary)
        #expect(!fixture.model.storesLocally(launcher: true))
        fixture.model.launcherDraft.text = "Translate this clause"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        #expect(fixture.model.launcherInputHistory.history.entries.isEmpty)
        #expect(await fixture.api.sends.last?.temporary == true)
        #expect(fixture.model.showsTemporaryConversation)
        // The next launcher question is ordinary again.
        #expect(!fixture.model.isTemporaryComposer(launcher: true))
        // The launcher's home offers no conversations to resume while temporary.
        await fixture.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.refreshHistory()
        #expect(!fixture.model.launcherHomeContext().conversations.isEmpty)
        fixture.model.toggleTemporary(launcher: true)
        #expect(fixture.model.launcherHomeContext().conversations.isEmpty)
    }

    @Test func anOrdinaryLauncherQuestionIsStillRecorded() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.text = "Remember me"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        #expect(fixture.model.launcherInputHistory.history.entries.count == 1)
        #expect(await fixture.api.sends.last?.temporary == nil)
    }

    @Test func theTempCommandTogglesAndLocksOnceStarted() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.newConversation()
        let context = fixture.model.commandContext(launcher: false)
        #expect(!context.temporaryMode && context.temporaryLocked == nil)
        let command = try #require(AskCommandCatalog.commands(context).first { $0.action == .temporaryMode })
        #expect(command.name == "temp")
        fixture.model.runCommand(command, launcher: false)
        #expect(fixture.model.isTemporaryComposer(launcher: false))
        #expect(fixture.model.commandFeedback == L("ask.command.temporaryOn"))
        // Memory cannot be switched on for it.
        let memory = try #require(AskCommandCatalog.commands(fixture.model.commandContext(launcher: false))
            .first { $0.action == .memory })
        #expect(memory.disabledReason == L("ask.temporary.noMemory"))
        fixture.model.runCommand(command, launcher: false)
        #expect(!fixture.model.isTemporaryComposer(launcher: false))
        #expect(fixture.model.commandFeedback == L("ask.command.temporaryOff"))
        // /local on a temporary draft makes it an ordinary private one.
        fixture.model.setTemporary(true, launcher: false)
        fixture.model.setStoresLocally(true, launcher: false)
        #expect(!fixture.model.isTemporaryComposer(launcher: false))
        #expect(fixture.model.storesLocally(launcher: false))

        _ = try await startTemporary(fixture)
        let locked = fixture.model.commandContext(launcher: false)
        #expect(locked.temporaryMode)
        #expect(locked.temporaryLocked == L("ask.storage.locked"))
        fixture.model.runCommand(command, launcher: false)
        #expect(fixture.model.isTemporaryComposer(launcher: false))
        fixture.model.setTemporary(false, launcher: false)
        #expect(fixture.model.isTemporaryComposer(launcher: false), "a started conversation keeps its kind")
        // The launcher can still choose.
        #expect(fixture.model.commandContext(launcher: true).temporaryLocked == nil)
    }

    @Test func theStorageCardOffersThreeKindsAndLocksOnceStarted() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        let open = AskLocalModeStatus.make(model: fixture.model, signedIn: true)
        #expect(open.choices == [.cloud, .local, .temporary])
        #expect(open.kind == .cloud)
        fixture.model.chooseStorage(.local, launcher: false)
        #expect(AskLocalModeStatus.make(model: fixture.model, signedIn: true).kind == .local)
        fixture.model.chooseStorage(.temporary, launcher: false)
        let chosen = AskLocalModeStatus.make(model: fixture.model, signedIn: true)
        #expect(chosen.kind == .temporary && chosen.changeable)
        #expect(chosen.summaryKey == "ask.storage.card.choose")
        fixture.model.chooseStorage(.cloud, launcher: false)
        #expect(fixture.model.storageKind(launcher: false) == .cloud)
        fixture.model.chooseStorage(.temporary, launcher: false)

        _ = try await startTemporary(fixture)
        let locked = AskLocalModeStatus.make(model: fixture.model, signedIn: true)
        #expect(locked.kind == .temporary && !locked.changeable && locked.choices.isEmpty)
        #expect(locked.summaryKey == "ask.storage.card.lockedTemporary")
        fixture.model.chooseStorage(.cloud, launcher: false)
        #expect(fixture.model.storageKind(launcher: false) == .temporary)
        // The sidebar's identity card only describes the session.
        #expect(AskLocalModeStatus.make(model: fixture.model, signedIn: false, offersChoice: false).choices.isEmpty)
    }

    @Test func theStorageKindsDescribeThemselves() {
        #expect(AskStorageKind.temporary.symbol == "hourglass")
        #expect(AskStorageKind.temporary.titleKey == "ask.storage.temporary")
        #expect(AskStorageKind.temporary.detailKey == "ask.storage.temporary.detail")
        #expect(AskStorageKind.cloud.symbol == "cloud" && AskStorageKind.local.symbol == "lock")
        #expect(AskStorageButton.iconColor(.temporary, active: false) == AskTheme.temporaryTint)
        #expect(AskStorageButton.wellFill(.temporary, active: false) == .clear)
        #expect(AskStorageButton.wellFill(.temporary, active: true) == .clear)
        #expect(AskLocalModeCard.tint(.temporary) == AskTheme.temporaryTint)
        #expect(AskLocalModeCard.tint(.local) == AskTheme.privateTint)
        #expect(AskLocalModeCard.tint(.cloud) == AskTheme.cloudTint)
    }

    @Test func theLeaveDialogMapsItsButtons() {
        #expect(AskTemporaryLeaveConfirmation.decision(for: .alertFirstButtonReturn, suppress: true)
            == .init(choice: .end, suppress: true))
        #expect(AskTemporaryLeaveConfirmation.decision(for: .alertSecondButtonReturn, suppress: false)
            == .init(choice: .keep))
        #expect(AskTemporaryLeaveConfirmation.decision(for: .alertThirdButtonReturn, suppress: true)
            == .init(choice: .cancel), "cancelling never stores don't ask again")
    }

    @Test func theNewConversationMenuStartsEachKind() async throws {
        let signedIn = AskNewConversationMenu.items(signedIn: true, privateByDefault: false)
        #expect(signedIn.map(\.kind) == [.cloud, .local, .temporary])
        #expect(signedIn.map(\.shortcut) == ["⌘N", "⇧⌘N", "⌥⌘N"])
        let allEnabled = signedIn.allSatisfy { $0.enabled }
        #expect(allEnabled)
        let privateDefault = AskNewConversationMenu.items(signedIn: true, privateByDefault: true)
        #expect(privateDefault.map(\.shortcut) == ["", "⌘N", "⌥⌘N"])
        let signedOut = AskNewConversationMenu.items(signedIn: false, privateByDefault: false)
        #expect(signedOut.map(\.enabled) == [false, true, true])
        #expect(AskNewConversationMenu.detailKey(.cloud, signedIn: false) == "ask.new.cloud.signedOut")
        #expect(AskNewConversationMenu.detailKey(.temporary, signedIn: true) == "ask.storage.temporary.detail")
        #expect(AskNewConversationMenu.titleKey(.cloud) == "ask.new.cloud")

        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        AskNewConversationMenu.start(.temporary, model: fixture.model)
        #expect(fixture.model.isTemporaryComposer(launcher: false))
        AskNewConversationMenu.start(.local, model: fixture.model)
        #expect(fixture.model.storageKind(launcher: false) == .local)
        AskNewConversationMenu.start(.cloud, model: fixture.model)
        #expect(fixture.model.storageKind(launcher: false) == .cloud)
    }

    @Test func signingOutForgetsTheTemporaryChat() async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-signed-out-workspaces-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspaces = AskConversationWorkspaceStore(rootURL: workspaceRoot)
        let (fixture, _) = try fixture(workspaces: workspaces)
        let id = try await startTemporary(fixture)
        let folder = try await workspaces.ensure(owner: fixture.sessionState.owner, conversationId: id)
        fixture.model.resetSession()
        #expect(fixture.model.temporaryConversation == nil)
        #expect(!fixture.model.isTemporary(id))
        try await eventually { !FileManager.default.fileExists(atPath: folder.path) }
    }

    @Test func quittingWaitsForTemporaryWorkspaceRemoval() async throws {
        let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ask-quitting-workspaces-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspaces = AskConversationWorkspaceStore(rootURL: workspaceRoot)
        let (fixture, _) = try fixture(workspaces: workspaces)
        let id = try await startTemporary(fixture)
        let folder = try await workspaces.ensure(owner: fixture.sessionState.owner, conversationId: id)
        await fixture.model.discardTemporaryConversationForTermination()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(fixture.model.temporaryConversation == nil)
    }

    @Test func theDraftRemembersItIsTemporary() throws {
        var draft = AskDraft(text: "hi")
        draft.temporary = true
        let decoded = try AskCoding.decoder().decode(AskDraft.self, from: AskCoding.encoder().encode(draft))
        #expect(decoded.temporary == true)
        let legacy = try AskCoding.decoder().decode(AskDraft.self, from: Data(#"{"text":"old","includeScreenshot":false}"#.utf8))
        #expect(legacy.temporary == nil)
    }

    @Test func temporaryViewsRender() throws {
        let (fixture, _) = try fixture()
        defer { fixture.model.resetSession() }
        fixture.model.newConversation(temporary: true)
        func size(_ view: some View) -> CGSize {
            let host = NSHostingView(rootView: view.environment(\.interfaceStyle, .liquidGlass))
            return host.fittingSize
        }
        #expect(size(AskNewConversationMenu(model: fixture.model) {}).height > 100)
        #expect(size(AskTemporaryHistoryRow()).height >= 32)
        #expect(size(AskTemporaryChip(model: fixture.model)).width > 40)
        #expect(size(AskLocalModeCard(status: .make(model: fixture.model, signedIn: true),
                                      onSignIn: {})).height > 120)
        #expect(size(AskTemporarySettingsView(settings: fixture.model.modelLibrary.settings)).height > 40)
    }
}

/// The local engine keeps a temporary conversation in memory only.
@Suite("Ask local engine temporary conversations")
struct AskLocalEngineTemporaryTests {
    private func request(_ text: String, temporary: Bool? = nil) -> AskSendRequest {
        AskSendRequest(id: UUID().uuidString, deviceId: "device", text: text, selection: nil, source: nil, image: nil,
                       tools: [], modelRef: "custom:model", memory: AskMemory(global: "soul"), temporary: temporary)
    }

    @Test func temporaryConversationsNeverReachTheDiskUntilKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-temp-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory)
        let id = UUID().uuidString.lowercased()
        let started = try await engine.send(conversationId: id, request: request("secret", temporary: true), token: "")
        #expect(started.memory == nil)
        #expect(await engine.isTemporary(id))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.isEmpty)
        #expect(try await engine.list(token: "", offset: 0).isEmpty)
        #expect(try await engine.conversation(id: id, token: "").id == id)

        let ordinary = UUID().uuidString.lowercased()
        let saved = try await engine.send(conversationId: ordinary, request: request("ordinary"), token: "")
        #expect(saved.memory != nil)
        #expect(try await engine.list(token: "", offset: 0).map(\.id) == [ordinary])

        let kept = try await engine.keep(conversationId: id, token: "")
        #expect(kept.id == id)
        #expect(await engine.isTemporary(id) == false)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".json").path))
        let listed = try await engine.list(token: "", offset: 0).map(\.id)
        #expect(Set(listed) == [id, ordinary])
        // Keeping again changes nothing.
        _ = try await engine.keep(conversationId: id, token: "")
        await #expect(throws: AskLocalError.self) { try await engine.keep(conversationId: "missing", token: "") }
    }

    @Test func deletingATemporaryConversationLeavesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-temp-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AskLocalEngine(directory: directory)
        let id = UUID().uuidString.lowercased()
        let started = try await engine.send(conversationId: id, request: request("secret", temporary: true), token: "")
        _ = try await engine.cancel(conversationId: id, runId: try #require(started.run?.id), token: "")
        let renamed = try await engine.updateTitle(id: id, request: AskTitleRequest(action: "rename", title: "Renamed"), token: "")
        #expect(renamed.title == "Renamed")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
        try await engine.delete(conversationId: id, token: "")
        #expect(await engine.isTemporary(id) == false)
        await #expect(throws: AskLocalError.self) { try await engine.conversation(id: id, token: "") }
    }
}

/// Only the temporary owner's copies go to memory; every other owner keeps the persistent cache.
@Suite("Ask temporary cache")
struct AskTemporaryCacheTests {
    @Test func routesByOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-temp-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let cache = AskTemporaryCache(base: base)
        let value = AskConversation(id: "c", title: "T", revision: 1, updatedAt: Date(), messages: [])
        try await cache.save(value, owner: AskRoutedAPI.temporaryOwner)
        try await cache.save(value, owner: "owner")
        #expect(try await base.load(id: "c", owner: AskRoutedAPI.temporaryOwner) == nil)
        #expect(try await cache.load(id: "c", owner: AskRoutedAPI.temporaryOwner) != nil)
        #expect(try await base.load(id: "c", owner: "owner") != nil)
        #expect(try await cache.list(owner: AskRoutedAPI.temporaryOwner).map(\.id) == ["c"])

        try await cache.saveDraft(AskDraft(text: "d"), key: "c", owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.draft(key: "c", owner: AskRoutedAPI.temporaryOwner)?.text == "d")
        #expect(try await base.draft(key: "c", owner: AskRoutedAPI.temporaryOwner) == nil)
        try await cache.saveDraft(AskDraft(text: "saved"), key: "saved-chat:1", owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.savedChatDrafts(owner: AskRoutedAPI.temporaryOwner).map(\.draft.text) == ["saved"])
        #expect(try await base.savedChatDrafts(owner: AskRoutedAPI.temporaryOwner).isEmpty)

        try await cache.associateTool(id: "c/call", conversationId: "c", owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.claimTool(id: "c/call", owner: AskRoutedAPI.temporaryOwner))
        let result = AskToolResultRequest(runId: "c", deviceId: "d", toolCallId: "call", content: "x", isError: false)
        try await cache.saveToolResult(result, owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.toolResult(id: "c/call", owner: AskRoutedAPI.temporaryOwner)?.content == "x")
        #expect(try await base.toolResult(id: "c/call", owner: AskRoutedAPI.temporaryOwner) == nil)
        _ = try await cache.executions(conversationId: "c", owner: AskRoutedAPI.temporaryOwner)
        #expect(try await base.executions(conversationId: "c", owner: AskRoutedAPI.temporaryOwner).isEmpty)
        #expect(try await cache.execution(id: "x", owner: AskRoutedAPI.temporaryOwner) == nil)

        try await cache.delete(id: "c", owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.load(id: "c", owner: AskRoutedAPI.temporaryOwner) == nil)
        #expect(try await base.load(id: "c", owner: "owner") != nil)
    }

    @Test func theDiscardingFallbackKeepsNothing() async throws {
        let cache = AskTemporaryCache(base: AskDiscardingCache(), temporary: AskDiscardingCache())
        let value = AskConversation(id: "c", title: "T", revision: 1, updatedAt: Date(), messages: [])
        try await cache.save(value, owner: AskRoutedAPI.temporaryOwner)
        #expect(try await cache.load(id: "c", owner: AskRoutedAPI.temporaryOwner) == nil)
        #expect(try await cache.list(owner: "o").isEmpty)
        try await cache.saveDraft(AskDraft(), key: "k", owner: "o")
        #expect(try await cache.draft(key: "k", owner: "o") == nil)
        #expect(try await cache.savedChatDrafts(owner: "o").isEmpty)
        try await cache.delete(id: "c", owner: "o")
        try await cache.associateTool(id: "t", conversationId: "c", owner: "o")
        #expect(try await cache.claimTool(id: "t", owner: "o"))
        try await cache.saveToolResult(.init(runId: "r", deviceId: "d", toolCallId: "t", content: "", isError: false), owner: "o")
        #expect(try await cache.toolResult(id: "t", owner: "o") == nil)
        #expect(try await cache.executions(conversationId: "c", owner: "o").isEmpty)
        #expect(try await cache.execution(id: "e", owner: "o") == nil)
    }
}
