import Foundation

/// AI prompt results beyond the launcher: saved to the notes (⌘S), opened in a window
/// of their own (⌘O), and the notes window itself (⌘B); `docs/design/ai-command-results.md`.
extension AskConversationModel {
    /// Lets `session` save a result whose ⌘S came while it streamed.
    func connectNotes(to session: AskPluginSession) {
        session.saveNoteWhenDone = { [weak self] output in
            guard let draft = output.noteDraft else { return }
            self?.performNotebookAction { [weak self] in _ = await self?.saveLauncherNote(draft) }
        }
    }

    /// ⌘S on a result: saves it, or takes it out again unless the user has edited it
    /// since. While the result streams, it is saved once done.
    func toggleLauncherNote(_ draft: AskNoteDraft) async {
        do {
            guard let notes else { return }
            if plugins.isRunning {
                plugins.toggleSaveNoteWhenDone()
                confirm(L(plugins.savesNoteWhenDone ? "ask.notes.saveWhenDone" : "ask.notes.saveWhenDone.cancelled"))
                return
            }
            if let saved = launcherNote, saved.body == draft.body, let note = try await notes.note(id: saved.id), !note.isDeleted {
                guard !note.isEdited else { confirm(L("ask.notes.editedKept")); return }
                guard await trashSavedNote(note) else { return }
                guard !Task.isCancelled, launcherNote?.id == saved.id else { return }
                launcherNote = nil
                plugins.showNoteSaved(false)
                confirm(L("ask.notes.removed"))
                return
            }
            await saveLauncherNote(draft)
        } catch {
            confirm(L("ask.notes.storageUnavailable"))

        }
    }

    /// Saves a result shown in the launcher, with the app the launcher came from.
    @discardableResult
    func saveLauncherNote(_ draft: AskNoteDraft) async -> UUID? {
        do {
            guard let notes, !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var sourced = draft
            if sourced.sourceApp == nil, let source = launcherDraft.source, !source.isEmpty {
                sourced.sourceApp = AskContextChips.sourceParts(source).app
            }
            if sourced.sourceBundleID == nil { sourced.sourceBundleID = launcherDraft.sourceBundleID }
            let session = plugins
            let generation = plugins.resultGeneration
            let note = AskNote(draft: sourced, at: Date())
            guard try await notes.save(note) else { confirm(L("ask.notes.saveFailed")); return nil }
            guard !Task.isCancelled, plugins === session, plugins.resultGeneration == generation else { return note.id }
            launcherNote = (draft.body, note.id)
            plugins.showNoteSaved(true)
            confirm(L("ask.notes.saved"))
            return note.id
        } catch {
            confirm(L("ask.notes.storageUnavailable"))
            return nil
        }
    }

    /// The note the shown result was saved as, when it is still that result.
    var launcherNoteID: UUID? {
        guard let saved = launcherNote, plugins.currentOutput?.body == saved.body,
              notes != nil else { return nil }
        return saved.id
    }

    /// ⌘O: the result (streaming or done) moves to a window and the launcher closes.
    func openLauncherResultInWindow() -> PluginActionOutcome {
        var document: AskResultDocument?
        guard let handoff = plugins.handOff(to: { event in document?.receive(event) }) else { return .stay }
        let source = launcherDraft.source.flatMap { $0.isEmpty ? nil : AskContextChips.sourceParts($0).app }
        let model = AskPluginRegistry.modelName(modelLibrary.settings)
        let opened = AskResultDocument(handoff: handoff, model: model == "AI" ? nil : model, sourceApp: source,
                                       sourceBundleID: launcherDraft.sourceBundleID, noteID: launcherNoteID,
                                       services: resultWindowServices)
        document = opened
        finishPluginResult()
        presentResultWindow(opened)
        return .close
    }

    /// Opens a saved note in a result window (`nb` keyword). False when it is gone.
    func openNoteInWindow(_ id: UUID) async -> Bool {
        let session = plugins
        let generation = plugins.resultGeneration
        do {
            guard let note = try await notes?.note(id: id), !note.isDeleted else { return false }
            guard !Task.isCancelled, plugins === session, plugins.resultGeneration == generation else { return false }
            finishPluginResult()
            openNoteWindow(note)
            return true
        } catch {
            confirm(L("ask.notes.storageUnavailable"))
            return false
        }
    }
}

/// Answers saved from a conversation to the notebook (`docs/design/notebook-redesign.md` §5).
extension AskConversationModel {
    /// Saves an answer, or the selected part of it, as a note. The whole answer again takes it
    /// out, unless the note has been edited since.
    func toggleAnswerNote(_ message: AskMessage, excerpt: String? = nil) async {
        do {
            guard let notes, message.role == "assistant", let selected,
                  selected.id == selectedId, selected.messages.contains(where: { $0.id == message.id }) else { return }
            guard await refreshAnswerNotes().value else { return }
            guard selectedId == selected.id, !Task.isCancelled else { return }
            if excerpt == nil, let id = answerNoteIDs[message.id], let note = try await notes.note(id: id), !note.isDeleted {
                guard !note.isEdited else { confirm(L("ask.notes.editedKept")); return }
                guard await trashSavedNote(note) else { return }
                guard selectedId == selected.id, !Task.isCancelled else { return }
                answerNoteIDs[message.id] = nil
                confirm(L("ask.notes.removed"))
                return
            }
            let text = excerpt ?? message.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let draft = AskNoteDraft(command: "", keyword: "", input: question(before: message), body: text,
                                     source: .chat, conversationID: selectedId,
                                     messageID: excerpt == nil ? message.id : nil)
            let note = AskNote(draft: draft, at: Date())
            guard try await notes.save(note) else { confirm(L("ask.notes.saveFailed")); return }
            guard selectedId == selected.id, !Task.isCancelled else { return }
            if excerpt == nil { answerNoteIDs[message.id] = note.id }
            confirm(L("ask.notes.saved"))
        } catch {
            confirm(L("ask.notes.storageUnavailable"))

        }
    }

    /// All save entry points use Recently Deleted and preserve concurrent changes.
    private func trashSavedNote(_ note: AskNote) async -> Bool {
        do {
            var removed = note
            removed.deletedAt = Date()
            guard try await notes?.save(removed, replacing: note, revisionAt: nil) == true else {
                confirm(L("ask.notes.saveFailed"))
                return false
            }
            return true
        } catch {
            confirm(L("ask.notes.storageUnavailable"))
            return false
        }
    }

    /// The user's question an answer replied to, for the note's title and origin.
    func question(before message: AskMessage) -> String {
        guard let messages = selected?.messages,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return "" }
        return messages[..<index].last { $0.role == "user" }?.text ?? ""
    }

    /// Reads which answers of the shown conversation are saved.
    @discardableResult
    func refreshAnswerNotes() -> Task<Bool, Never> {
        notebookReadTask?.cancel()
        let id = selectedId
        let store = notes
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            guard let store, let id else { self.answerNoteIDs = [:]; return false }
            do {
                var saved: [String: UUID] = [:]
                var offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await store.list(AskNoteQuery(scope: .source(.chat), limit: 500,
                                                                 offset: offset, conversationID: id))
                    for note in page {
                        if let messageID = note.messageID, saved[messageID] == nil { saved[messageID] = note.id }
                    }
                    guard page.count == 500 else { break }
                    offset += page.count
                }
                guard !Task.isCancelled, self.selectedId == id else { return false }
                self.answerNoteIDs = saved
                return true
            } catch {
                guard !Task.isCancelled, self.selectedId == id else { return false }
                self.confirm(L("ask.notes.storageUnavailable"))
                return false
            }
        }
        notebookReadTask = task
        return task
    }

    /// At most one admitted notebook mutation per launcher. Dropped repeated keys are never replayed.
    func performNotebookAction(_ action: @escaping @MainActor () async -> Void) {
        guard notebookTask == nil else { return }
        notebookTask = Task { [weak self] in
            defer { self?.notebookTask = nil }
            await action()
        }
    }

}

extension AskPluginOutput {
    /// What ⌘S would save, when the result can be saved.
    var noteDraft: AskNoteDraft? {
        for action in actions { if case let .toggleNote(draft) = action.kind { return draft } }
        return nil
    }
}
