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
        guard canOpenChatFromLauncher else { confirm(L("ask.openChat.wait")); return false }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let account = owner, sessionOwner = session()?.owner
        let source = launcherDraft, previous = draft, previousID = selectedId
        let generation = selectionGeneration
        let keyword = plugins.keyword
        var incoming = source
        var otherPlugin = keyword.map { $0.pluginID != AskOpenChatPlugin.id } ?? false
        if keyword == nil {
            switch AskKeywordMatcher.match(source.text, keywords: launcherKeywords) {
            case let .hint(found) where found.pluginID == AskOpenChatPlugin.id: incoming.text = ""
            case let .active(found, argument) where found.pluginID == AskOpenChatPlugin.id: incoming.text = argument
            case .active: otherPlugin = true
            default: break
            }
        }
        let transfers = !otherPlugin && incoming.hasChatInput
        do {
            if transfers {
                // The queued editor's underlying draft is restored by newConversation().
                let preserved = sendQueue.editing.flatMap { $0.conversationId == selectedId ? $0.stash : nil } ?? previous
                if let previousID, !isLoadingSelection {
                    try await cache.saveDraft(preserved, key: previousID, owner: cacheOwner(previousID))
                } else if previousID == nil, preserved.hasChatInput {
                    let saved = AskSavedChatDraft(id: "saved-chat:" + UUID().uuidString, draft: preserved)
                    try await cache.saveDraft(saved.draft, key: saved.id, owner: account)
                    if owner == account, session()?.owner == sessionOwner { savedChatDrafts.append(saved) }
                }
            }
            guard owner == account, session()?.owner == sessionOwner, source == launcherDraft,
                  previous == draft, generation == selectionGeneration, plugins.keyword == keyword,
                  !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false) else { return false }
            if transfers {
                newConversation()
                draft = incoming
                clearCapturedContentFeedback(launcher: true)
                launcherDraft = AskDraft()
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
        } catch {
            confirm(L("ask.cache.failed"))
            return false
        }
    }

    func loadSavedChatDrafts() async {
        let account = owner, sessionOwner = session()?.owner
        guard let saved = try? await cache.savedChatDrafts(owner: account),
              owner == account, session()?.owner == sessionOwner else { return }
        savedChatDrafts = saved
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
            if replacement.hasChatInput {
                let displaced = AskSavedChatDraft(id: "saved-chat:" + UUID().uuidString, draft: replacement)
                try await cache.saveDraft(displaced.draft, key: displaced.id, owner: account)
            }
            guard owner == account, session()?.owner == sessionOwner, draft == previous, generation == selectionGeneration,
                  !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false) else { return }
            newConversation()
            draft = saved.draft
            try await cache.saveDraft(.followUp, key: saved.id, owner: account)
            guard owner == account, session()?.owner == sessionOwner else { return }
            await loadSavedChatDrafts()
            persistDrafts()
        } catch { confirm(L("ask.cache.failed")) }
    }
}
