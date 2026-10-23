import Foundation
import Testing
@testable import Typeflux

private actor HandoffGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitOnce() async {
        guard !entered else { return }
        await wait()
    }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskDraftHandoffTests {
    private func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0 ..< 300 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for draft handoff state")
    }

    @Test func acknowledgedTransferSurvivesReopenWithAttachmentsAndSourceContext() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let incoming = AskDraft(text: "Transfer this", includeScreenshot: false, selection: "Selection",
            source: "Editor", sourceBundleID: "example.editor", capturedAt: Date(), modelRef: "cloud:default",
            references: [.init(messageId: "message", text: "Quote")],
            attachments: [.init(kind: .file, name: "notes.txt", text: "Notes", localSourcePath: "/tmp/notes.txt")],
            skills: ["summarize"], mcpServers: ["docs"], storesLocally: false)
        f.model.launcherDraft = incoming
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        let reopened = try AskConversationCache(url: f.root.appendingPathComponent("cache.sqlite"))
        let saved = try #require(try await reopened.draft(key: key, owner: "owner"))
        #expect(saved.text == incoming.text && saved.attachments == incoming.attachments)
        #expect(saved.sourceBundleID == incoming.sourceBundleID && saved.references == incoming.references)
        #expect(saved.skills == incoming.skills && saved.mcpServers == incoming.mcpServers)
        await f.model.loadSavedChatDrafts()
        #expect(f.model.savedChatDrafts.isEmpty)
        f.model.resetSession()
        _ = f.model.credentials()
        await f.model.loadSavedChatDrafts()
        #expect(f.model.savedChatDrafts.map(\.id) == [key])
        #expect(await f.api.sends.isEmpty)
        #expect(try await reopened.savedChatDrafts(owner: "another-account").isEmpty)
    }

    @Test func failedIncomingSaveKeepsEditorsAndRetryReusesBothRecoveryIdentities() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.draft.text = "Displaced"
        f.model.launcherDraft.text = "Incoming"
        try await f.cache.execute("CREATE TRIGGER fail_handoff BEFORE INSERT ON ask_drafts WHEN NEW.id LIKE 'saved-chat:handoff:%' BEGIN SELECT RAISE(ABORT, 'held'); END", strings: [])
        #expect(await !(f.model.openChatFromLauncher()))
        let pending = try #require(f.model.pendingDraftHandoff)
        #expect(f.model.draft.text == "Displaced" && f.model.launcherDraft.text == "Incoming")
        #expect(f.model.activeChatDraftID == nil)
        try await f.cache.execute("DROP TRIGGER fail_handoff", strings: [])
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.activeChatDraftID == pending.id)
        let all = try await f.cache.savedChatDrafts(owner: "owner")
        #expect(all.count == 2)
        #expect(all.filter { $0.draft.text == "Displaced" }.count == 1)
    }

    @Test func editsAccountChangesAndCancellationInvalidateLateAcknowledgments() async throws {
        for change in ["edit", "account", "cancel"] {
            let base = try AskConversationCache.inMemory(), gate = HandoffGate()
            let cache = GatedConversationCache(base: base, beforeDraftSave: { key in
                if key.hasPrefix("saved-chat:handoff:") { await gate.wait() }
            }, beforeSave: { _ in })
            let f = try AskTestFixture(cacheOverride: cache)
            defer { f.model.resetSession() }
            f.model.launcherDraft.text = "Original"
            var shown = 0
            f.model.onShowConversation = { shown += 1 }
            let task = Task { await f.model.openChatFromLauncher() }
            try await wait { await gate.entered }
            #expect(f.model.launcherDraft.text == "Original")
            switch change {
            case "edit": f.model.launcherDraft.text = "Newer edit"
            case "account": f.sessionState.owner = "other"; f.model.resetSession()
            default: task.cancel()
            }
            await gate.release()
            #expect(await !(task.value))
            #expect(shown == 0 && f.model.activeChatDraftID == nil)
            if change == "edit" { #expect(f.model.launcherDraft.text == "Newer edit") }
            if change == "cancel" { #expect(f.model.launcherDraft.text == "Original") }
            #expect(try await base.savedChatDrafts(owner: "other").isEmpty)
            #expect(await f.api.sends.isEmpty)
        }
    }

    @Test func missingOrAlteredReadbackCannotAcknowledgeHandoff() async throws {
        let discarded = try AskTestFixture(cacheOverride: AskDiscardingCache())
        discarded.model.launcherDraft.text = "Keep me"
        #expect(await !(discarded.model.openChatFromLauncher()))
        #expect(discarded.model.launcherDraft.text == "Keep me")
        let base = try AskConversationCache.inMemory()
        let altered = GatedConversationCache(base: base, afterDraftSave: { key, owner in
            try await base.saveDraft(.init(text: "Different"), key: key, owner: owner)
        }, beforeSave: { _ in })
        let f = try AskTestFixture(cacheOverride: altered)
        f.model.launcherDraft.text = "Original"
        #expect(await !(f.model.openChatFromLauncher()))
        #expect(f.model.launcherDraft.text == "Original" && f.model.draft.text.isEmpty)
        f.model.resetSession(); discarded.model.resetSession()
    }

    @Test func privateDraftsNeverEnterRecoveryAndTemporaryChatSurvivesHandoff() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.draft = .init(text: "Private unsent", temporary: true)
        f.model.launcherDraft = .init(text: "Private incoming", temporary: true)
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.activeChatDraftID == nil)
        #expect(try await f.cache.savedChatDrafts(owner: "owner").isEmpty)
        f.model.draft.text = "Temporary conversation"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.run?.status == "completed" }
        let id = try #require(f.model.selectedId)
        f.model.draft.text = "Private follow-up"
        f.model.launcherDraft = .init(text: "Keep launcher input")
        #expect(await f.model.openChatFromLauncher())
        #expect(f.model.selectedId == nil && f.model.draft.text == "Keep launcher input")
        #expect(f.model.isTemporary(id))
        await f.model.select(id)
        #expect(f.model.draft.text == "Private follow-up")
        let saved = try await f.cache.savedChatDrafts(owner: "owner")
        #expect(!saved.contains { $0.draft.text.hasPrefix("Private") })
        #expect(await f.api.sends.count == 1)
    }

    @Test func editsUpdateRecoveryAndTemporarySwitchRemovesIt() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Initial"
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        f.model.draft.text = "Edited"
        f.model.persistDrafts()
        try await wait { try await f.cache.draft(key: key, owner: "owner")?.text == "Edited" }
        f.model.setTemporary(true, launcher: false)
        f.model.draft.text = "New private input"
        f.model.persistDrafts() // Must not cancel deletion scheduled by the privacy switch.
        try await wait { try await f.cache.draft(key: key, owner: "owner") == nil }
        #expect(f.model.activeChatDraftID == nil)
        await #expect(throws: AskRecoveryError.binding) {
            try await f.cache.saveDraft(.init(text: "Late stale write"), key: key, owner: "owner")
        }
    }

    @Test func failedSendKeepsRecoveryAndSuccessfulRetryConsumesOnlyItsMessage() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Send once"
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        await f.api.setFailSend(true)
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(try await f.cache.draft(key: key, owner: "owner")?.text == "Send once")
        #expect(f.model.activeChatDraftID == nil)
        let id = try #require(f.model.selectedId)
        await f.api.setFailSend(false)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(try await f.cache.draft(key: key, owner: "owner") == nil)
        #expect(try await f.cache.load(id: id, owner: "owner")?.messages.contains { $0.text == "Send once" } == true)
        #expect(f.model.chatDraftSubmissions.isEmpty)
    }

    @Test func navigationAndRestoreKeepADurableCopyWithoutDuplicatingIt() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "First"
        #expect(await f.model.openChatFromLauncher())
        let first = try #require(f.model.activeChatDraftID)
        f.model.launcherDraft.text = "Second"
        #expect(await f.model.openChatFromLauncher())
        await f.model.loadSavedChatDrafts()
        let saved = try #require(f.model.savedChatDrafts.first { $0.id == first })
        await f.model.restoreChatDraft(saved)
        #expect(f.model.activeChatDraftID == first && f.model.draft.text == "First")
        #expect(try await f.cache.draft(key: first, owner: "owner")?.text == "First")
        #expect(f.model.savedChatDrafts.map(\.draft.text) == ["Second"])
        await f.api.seed(.init(id: "existing", title: "Existing", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("existing")
        #expect(f.model.activeChatDraftID == nil)
        await f.model.loadSavedChatDrafts()
        #expect(Set(f.model.savedChatDrafts.map(\.draft.text)) == ["First", "Second"])
    }
}

extension AskDraftHandoffTests {
    @Test(arguments: [false, true])
    func emptyWorkspaceAutomaticallyRestoresNewestSavedDraftWithoutSending(localOnly: Bool) async throws {
        let f = try AskTestFixture(localOnly: localOnly)
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        let account = f.model.owner
        try await f.cache.saveDraft(.init(text: "Older"), key: "saved-chat:z", owner: account)
        let incoming = AskDraft(text: "Latest", includeScreenshot: false, modelRef: "custom:test",
            references: [.init(messageId: "message", text: "Quote")],
            attachments: [.init(kind: .file, name: "notes.txt", text: "Notes")], storesLocally: true)
        try await f.cache.saveDraft(incoming, key: "saved-chat:a", owner: account)
        try await f.cache.saveDraft(.init(text: "Other account"), key: "saved-chat:other", owner: "another")
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == incoming)
        #expect(f.model.activeChatDraftID == "saved-chat:a")
        #expect(f.model.savedChatDrafts.map(\.draft.text) == ["Older"])
        #expect(try await f.cache.draft(key: "saved-chat:a", owner: account) == incoming)
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == incoming)
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
    }

    @Test(arguments: ["empty", "text", "attachment", "temporary", "selection", "recording", "loading"])
    func automaticRestorePreservesCurrentWorkspace(state: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        if state != "empty" {
            try await f.cache.saveDraft(.init(text: "Saved"), key: "saved-chat:test", owner: "owner")
        }
        switch state {
        case "text": f.model.draft.text = "New input"
        case "attachment": f.model.draft.attachments = [.init(kind: .file, name: "new.txt", text: "New")]
        case "temporary": f.model.newConversation(temporary: true)
        case "selection":
            await f.api.seed(.init(id: "existing", title: "Existing", revision: 1, updatedAt: Date(), messages: []))
            await f.model.select("existing")
        case "recording": f.model.recordingIsActive = { true }
        case "loading": f.model.attachmentLoads[f.model.visionDraftKey(launcher: false)] = 1
        default: break
        }
        let previous = f.model.draft, selection = f.model.selectedId
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft == previous && f.model.selectedId == selection)
        #expect(f.model.activeChatDraftID == nil)
        #expect(await f.api.sends.isEmpty)
    }

    @Test(arguments: ["edit", "navigate", "account", "cancel"])
    func lateAutomaticRestoreCannotReplaceNewerUserIntent(change: String) async throws {
        let base = try AskConversationCache.inMemory(), gate = HandoffGate()
        let cache = GatedConversationCache(base: base, beforeSavedDraftsRead: { await gate.waitOnce() }, beforeSave: { _ in })
        let f = try AskTestFixture(cacheOverride: cache)
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        try await base.saveDraft(.init(text: "Saved"), key: "saved-chat:test", owner: "owner")
        let task = Task { await f.model.restoreSavedChatDraftIfNeeded() }
        try await wait { await gate.entered }
        switch change {
        case "edit": f.model.draft.text = "Newer input"
        case "navigate": f.model.newConversation()
        case "account": f.sessionState.owner = "other"; _ = f.model.credentials()
        default: task.cancel()
        }
        let previous = f.model.draft
        await gate.release()
        await task.value
        #expect(f.model.draft == previous)
        #expect(f.model.activeChatDraftID == nil)
        #expect(try await base.draft(key: "saved-chat:test", owner: "owner")?.text == "Saved")
        #expect(await f.api.sends.isEmpty)
    }

    @Test func failedAutomaticReadDoesNotRestoreAStaleInMemoryBackup() async throws {
        let unavailable = RecoveringAskConversationCache(factory: { throw CocoaError(.fileReadNoPermission) })
        let f = try AskTestFixture(cacheOverride: unavailable)
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        f.model.savedChatDrafts = [.init(id: "saved-chat:stale", draft: .init(text: "Stale"))]
        await f.model.restoreSavedChatDraftIfNeeded()
        #expect(f.model.draft.text.isEmpty && f.model.activeChatDraftID == nil)
        #expect(await f.api.sends.isEmpty)
        await unavailable.shutdown()
    }

    @Test func successfulSendConsumesBackupOnlyAfterDestinationIsDurable() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Accepted"
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(try await f.cache.draft(key: key, owner: "owner") == nil)
        let id = try #require(f.model.selectedId)
        #expect(try await f.cache.load(id: id, owner: "owner")?.messages.first?.text == "Accepted")
        #expect(await f.api.sends.count == 1)
    }

    @Test func cleanupFailureKeepsRecoveryWithoutBlockingAcceptedRun() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Accepted despite cleanup"
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        try await f.cache.execute("CREATE TRIGGER fail_delete BEFORE DELETE ON ask_drafts BEGIN SELECT RAISE(ABORT, 'held'); END", strings: [])
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        #expect(try await f.cache.draft(key: key, owner: "owner") != nil)
        #expect(await f.api.sends.count == 1)
        #expect(f.model.chatDraftSubmissions.count == 1)
    }

    @Test func unrelatedResponseCannotConsumeRecovery() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.launcherDraft.text = "Bound to one message"
        #expect(await f.model.openChatFromLauncher())
        let key = try #require(f.model.activeChatDraftID)
        f.model.chatDraftSubmissions["chat"] = .init(key: key, owner: "owner", messageID: "expected")
        let response = AskConversation(id: "chat", title: "Chat", revision: 1, updatedAt: Date(), messages: [])
        await f.model.acknowledgeChatDraft(response, route: .init(account: "owner", owner: "owner", token: "token"))
        #expect(try await f.cache.draft(key: key, owner: "owner") != nil)
        #expect(f.model.chatDraftSubmissions.count == 1)
    }
}

extension AskDraftHandoffTests {
    @Test func lateCancelledWriteCannotOverwriteANewerRecoveryCopy() async throws {
        let base = try AskConversationCache.inMemory(), gate = HandoffGate()
        let cache = GatedConversationCache(base: base, beforeDraftSave: { key in
            if key == "saved-chat:ordered" { await gate.waitOnce() }
        }, beforeSave: { _ in })
        let f = try AskTestFixture(cacheOverride: cache)
        defer { f.model.resetSession() }
        let first = Task { try await f.model.saveChatDraft(.init(text: "Old"), key: "saved-chat:ordered", account: "owner") }
        try await wait { await gate.entered }
        first.cancel()
        let second = Task { try await f.model.saveChatDraft(.init(text: "New"), key: "saved-chat:ordered", account: "owner") }
        // Another account/key can complete while this copy's storage call is held.
        try await f.model.saveChatDraft(.init(text: "Independent"), key: "saved-chat:other", account: "other")
        #expect(try await base.draft(key: "saved-chat:other", owner: "other")?.text == "Independent")
        await gate.release()
        _ = try? await first.value
        try await second.value
        #expect(try await base.draft(key: "saved-chat:ordered", owner: "owner")?.text == "New")
        #expect(f.model.chatDraftWrites.isEmpty)
    }
}
