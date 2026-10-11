import Foundation

extension AskConversationModel {
    /// Opens a fresh, unsent question with a notebook snapshot attached.
    /// Preserve the displaced draft before changing the visible conversation.
    @discardableResult
    func openChat(referencing note: AskNote) async -> Bool {
        guard canOpenChatFromLauncher else { confirm(L("ask.openChat.wait")); return false }
        if session() != nil { _ = credentials() }
        let incoming = AskDraft(includeScreenshot: false, references: [AskReference(note: note)])
        guard incoming.referencesWithinLimit else { confirm(L("ask.input.tooLarge")); return false }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let account = owner, sessionOwner = session()?.owner
        let previous = draft, previousID = selectedId, generation = selectionGeneration
        do {
            let preserved = sendQueue.editing.flatMap { $0.conversationId == previousID ? $0.stash : nil } ?? previous
            if let previousID, !isLoadingSelection {
                try await cache.saveDraft(preserved, key: previousID, owner: cacheOwner(previousID))
            } else if previousID == nil, preserved.hasChatInput {
                let saved = AskSavedChatDraft(id: "saved-chat:" + UUID().uuidString, draft: preserved)
                try await cache.saveDraft(saved.draft, key: saved.id, owner: account)
                if owner == account, session()?.owner == sessionOwner { savedChatDrafts.append(saved) }
            }
            guard owner == account, session()?.owner == sessionOwner, draft == previous,
                  selectedId == previousID, selectionGeneration == generation,
                  !recordingIsActive(), !voiceInput.isOccupied, !capturing,
                  !isLoadingAttachments(launcher: true), !isLoadingAttachments(launcher: false) else { return false }
            newConversation()
            // Keep the new conversation's global memory, without unrelated captured content.
            draft.includeScreenshot = false
            draft.references = incoming.references
            persistDrafts()
            onShowConversation?()
            return true
        } catch {
            confirm(L("ask.cache.failed"))
            return false
        }
    }

    func locateReference(_ location: String) {
        if location.hasPrefix("note:"), let id = UUID(uuidString: String(location.dropFirst(5))) {
            openNotes(id)
        } else {
            referenceLocation = location
        }
    }
}
