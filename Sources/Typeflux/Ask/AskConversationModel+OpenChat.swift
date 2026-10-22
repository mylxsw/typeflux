import Foundation

extension AskConversationModel {
    var canOpenChatFromLauncher: Bool {
        !isOpeningChat && !recordingIsActive() && !voiceInput.isOccupied && !capturing
            && !isLoadingAttachments(launcher: true) && !isLoadingAttachments(launcher: false)
    }

    /// All three launcher entries meet here. Saving finishes before navigation;
    /// edits or account changes during that await abort the handoff intact.
    @discardableResult
    func openChatFromLauncher() async -> Bool {
        if !FeatureProcess.owns(.chat) { return await openFeatureChat() }
        if plugins.keyword?.pluginID == AskQuickAskPlugin.id, quickAsk?.conversationId != nil {
            return await openQuickAskInChat()
        }
        guard !Task.isCancelled, canOpenChatFromLauncher else { confirm(L("ask.openChat.wait")); return false }
        if session() != nil { _ = credentials() }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let account = owner, sessionOwner = session()?.owner
        let source = launcherDraft, previous = draft, previousID = selectedId
        let generation = selectionGeneration
        let keyword = plugins.keyword
        var incoming = source
        var otherPlugin = keyword.map { ![AskOpenChatPlugin.id, AskQuickAskPlugin.id].contains($0.pluginID) } ?? false
        if keyword == nil {
            switch AskKeywordMatcher.match(source.text, keywords: launcherKeywords) {
            case let .hint(found) where found.pluginID == AskOpenChatPlugin.id: incoming.text = ""
            case let .active(found, argument) where found.pluginID == AskOpenChatPlugin.id: incoming.text = argument
            case .active: otherPlugin = true
            default: break
            }
        }
        let transfers = !otherPlugin && incoming.hasChatInput
        let handoffID = transfers && incoming.temporary != true ? reserveChatDraft(incoming, account: account).id : nil
        do {
            if transfers {
                // The queued editor's underlying draft is restored by newConversation().
                let preserved = sendQueue.editing.flatMap { $0.conversationId == selectedId ? $0.stash : nil } ?? previous
                if let previousID, !isLoadingSelection {
                    try await cache.saveDraft(preserved, key: previousID, owner: cacheOwner(previousID))
                } else if previousID == nil, preserved.hasChatInput, preserved.temporary != true {
                    let saved = displacedChatDraft(preserved, handoffID: handoffID)
                    try await saveChatDraft(saved.draft, key: saved.id, account: account)
                    if owner == account, session()?.owner == sessionOwner { savedChatDrafts.append(saved) }
                }
            }
            let recoveryKey = transfers ? try await stageChatDraft(incoming, account: account) : nil
            guard !Task.isCancelled, owner == account, session()?.owner == sessionOwner, source == launcherDraft,
                  previous == draft, generation == selectionGeneration, plugins.keyword == keyword,
                  !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false) else { return false }
            if transfers {
                let mode = launcherPermissionMode
                guard newConversation() else { return false }
                activeChatDraftID = recoveryKey
                pendingDraftHandoff = nil
                draftPermissionMode = mode; launcherPermissionMode = .standard
                draft = incoming
                clearCapturedContentFeedback(launcher: true)
                launcherDraft = newQuestionDraft()
                restoreLauncherContextMarker(false)
            }
            // Invalidate an in-flight cache restore even on an empty open.
            captureGeneration = UUID()
            if !otherPlugin {
                plugins.deactivate()
                if !transfers { launcherDraft.text = "" }
            }
            persistDrafts()
            onShowConversation?()
            return true
        } catch is CancellationError { return false } catch {
            confirm(L("ask.cache.failed"))
            return false
        }
    }

    func loadSavedChatDrafts() async {
        let account = owner, sessionOwner = session()?.owner
        guard let saved = try? await cache.savedChatDrafts(owner: account),
              owner == account, session()?.owner == sessionOwner else { return }
        savedChatDrafts = saved.filter { $0.id != activeChatDraftID }
    }

    /// Restoring preserves the visible unsent draft before replacing it.
    /// Existing conversation drafts stay with their conversations.
    func restoreChatDraft(_ saved: AskSavedChatDraft) async {
        guard canOpenChatFromLauncher, savedChatDrafts.contains(saved) else { return }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let account = owner, previous = draft, generation = selectionGeneration, sessionOwner = session()?.owner
        do {
            if let id = selectedId, !isLoadingSelection {
                let preserved = sendQueue.editing.flatMap { $0.conversationId == id ? $0.stash : nil } ?? draft
                try await cache.saveDraft(preserved, key: id, owner: cacheOwner(id))
            }
            guard owner == account, session()?.owner == sessionOwner, draft == previous, generation == selectionGeneration else { return }
            let replacement = selectedId == nil ? draft : .followUp
            // Save the displaced draft separately before touching the visible composer.
            if replacement.hasChatInput, replacement.temporary != true {
                let displaced = displacedChatDraft(replacement)
                try await saveChatDraft(displaced.draft, key: displaced.id, account: account)
            }
            guard owner == account, session()?.owner == sessionOwner, draft == previous, generation == selectionGeneration,
                  !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false) else { return }
            guard !Task.isCancelled, newConversation() else { return }
            activeChatDraftID = saved.id
            draft = saved.draft
            guard owner == account, session()?.owner == sessionOwner else { return }
            await loadSavedChatDrafts()
            persistDrafts()
        } catch { confirm(L("ask.cache.failed")) }
    }
}
