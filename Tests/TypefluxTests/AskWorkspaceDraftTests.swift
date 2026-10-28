import Foundation
import Testing
@testable import Typeflux

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceDraftTests {
    @Test(arguments: ["edit", "clear", "recording", "loading", "account", "cancel"])
    func delayedCheckpointCannotOverrideNewUserIntent(change: String) async throws {
        let base = try AskConversationCache.inMemory()
        var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        let cache = GatedConversationCache(base: base, beforeDraftRead: { key in
            guard key == AskConversationModel.workspaceDraftKey else { return }
            await withCheckedContinuation { pending in
                Task { @MainActor in continuation = pending; entered = true }
            }
        }, beforeSave: { _ in })
        let f = try AskTestFixture(cacheOverride: cache)
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        try await base.saveDraft(.init(text: "Checkpoint"), key: AskConversationModel.workspaceDraftKey, owner: "owner")
        let restore = Task { await f.model.restoreSavedChatDraftIfNeeded() }
        try await f.wait { entered }
        switch change {
        case "edit": f.model.draft.text = "New input"
        case "clear": f.model.newConversation()
        case "recording": f.model.recordingIsActive = { true }
        case "loading": f.model.attachmentLoads[f.model.visionDraftKey(launcher: false)] = 1
        case "account": f.sessionState.owner = "other"; _ = f.model.credentials()
        default: restore.cancel()
        }
        let expected = f.model.draft
        continuation?.resume()
        await restore.value
        #expect(f.model.draft == expected)
        #expect(await f.api.sends.isEmpty)
    }

    @Test(arguments: [false, true])
    func clearingRestoredInputSurvivesReopeningAndRestart(localOnly: Bool) async throws {
        let f = try AskTestFixture(localOnly: localOnly)
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        let owner = f.model.owner
        try await f.cache.saveDraft(.init(text: "Older backup"), key: "saved-chat:older", owner: owner)
        let incoming = AskDraft(text: "Question", screenshot: "image", source: "Editor", sourceBundleID: "test.editor")
        try await f.cache.saveDraft(incoming, key: "saved-chat:latest", owner: owner)
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft.text == "Question")
        f.model.draft.text = ""
        f.model.removeCapturedContent(.source, launcher: false)
        f.model.removeCapturedContent(.screenshot, launcher: false)
        let cleared = f.model.draft
        #expect(await f.model.flushFeatureDrafts())
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == cleared)
        f.model.resetSession()
        _ = f.model.credentials()
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == cleared)
        #expect(f.model.draft.text.isEmpty && !f.model.draft.includeScreenshot && f.model.draft.sourceOff == true)
        #expect(try await f.cache.draft(key: "saved-chat:older", owner: owner)?.text == "Older backup")
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
    }

    @Test func startingFreshDoesNotRestoreTheDisplacedBackup() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Displaced input"
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.newConversation())
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(!f.model.draft.hasChatInput)
        #expect(await f.model.flushFeatureDrafts())
        f.model.resetSession()
        _ = f.model.credentials()
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(!f.model.draft.hasChatInput)
        #expect(try await f.cache.savedChatDrafts(owner: "owner").contains { $0.draft.text == "Displaced input" })
    }

    @Test func workspaceCheckpointRestoresLatestEditsWithoutCreatingAnotherBackup() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        f.model.draft = .init(text: "New input", includeScreenshot: false,
            attachments: [.init(kind: .file, name: "notes.txt", text: "Notes")])
        #expect(await f.model.flushFeatureDrafts())
        let expected = f.model.draft
        f.model.resetSession()
        _ = f.model.credentials()
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == expected)
        f.model.draft.text = "Latest edits"
        #expect(await f.model.flushFeatureDrafts())
        #expect(try await f.cache.savedChatDrafts(owner: "owner").isEmpty)
        f.model.resetSession()
        _ = f.model.credentials()
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft.text == "Latest edits")
    }

    @Test func coldWindowSaveCannotOverwriteCheckpointBeforeRestore() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        let expected = AskDraft(text: "Saved before launch", includeScreenshot: false)
        try await f.cache.saveDraft(expected, key: AskConversationModel.workspaceDraftKey, owner: "owner")
        #expect(await f.model.flushFeatureDrafts())
        #expect(try await f.cache.draft(key: AskConversationModel.workspaceDraftKey, owner: "owner") == expected)
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == expected)
    }

    @Test func temporaryInputAndConversationFollowUpsNeverBecomeNewChatInput() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        f.model.newConversation(temporary: true)
        f.model.draft.text = "Private input"
        #expect(await f.model.flushFeatureDrafts())
        #expect(try await f.cache.draft(key: AskConversationModel.workspaceDraftKey, owner: "owner") == .followUp)
        f.model.newConversation()
        await f.api.seed(.init(id: "existing", title: "Existing", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("existing")
        f.model.draft.text = "Conversation follow-up"
        #expect(await f.model.flushFeatureDrafts())
        #expect(try await f.cache.draft(key: "existing", owner: "owner")?.text == "Conversation follow-up")
        #expect(try await f.cache.draft(key: AskConversationModel.workspaceDraftKey, owner: "owner") == .followUp)
    }
}
