import Foundation

/// AI prompt results beyond the launcher: saved to the notes (⌘S), opened in a window
/// of their own (⌘O), and the notes window itself (⌘B); `docs/design/ai-command-results.md`.
extension AskConversationModel {
    /// Lets `session` save a result whose ⌘S came while it streamed.
    func connectNotes(to session: AskPluginSession) {
        session.saveNoteWhenDone = { [weak self] output in
            guard let draft = output.noteDraft else { return }
            self?.saveLauncherNote(draft)
        }
    }

    /// ⌘S on a result: saves it, or takes it out again unless the user has edited it
    /// since. While the result streams, it is saved once done.
    func toggleLauncherNote(_ draft: AskNoteDraft) {
        guard let notes else { return }
        if plugins.isRunning {
            plugins.toggleSaveNoteWhenDone()
            confirm(L(plugins.savesNoteWhenDone ? "ask.notes.saveWhenDone" : "ask.notes.saveWhenDone.cancelled"))
            return
        }
        if let saved = launcherNote, saved.body == draft.body, let note = notes.note(id: saved.id) {
            guard !note.isEdited else { confirm(L("ask.notes.editedKept")); return }
            notes.delete(ids: [note.id])
            launcherNote = nil
            plugins.showNoteSaved(false)
            confirm(L("ask.notes.removed"))
            return
        }
        saveLauncherNote(draft)
    }

    /// Saves a result shown in the launcher, with the app the launcher came from.
    @discardableResult
    func saveLauncherNote(_ draft: AskNoteDraft) -> UUID? {
        guard let notes, !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var sourced = draft
        if sourced.sourceApp == nil, let source = launcherDraft.source, !source.isEmpty {
            sourced.sourceApp = AskContextChips.sourceParts(source).app
        }
        if sourced.sourceBundleID == nil { sourced.sourceBundleID = launcherDraft.sourceBundleID }
        let note = AskNote(draft: sourced, at: Date())
        guard notes.save(note) else { return nil }
        launcherNote = (draft.body, note.id)
        plugins.showNoteSaved(true)
        confirm(L("ask.notes.saved"))
        return note.id
    }

    /// The note the shown result was saved as, when it is still that result.
    var launcherNoteID: UUID? {
        guard let saved = launcherNote, plugins.currentOutput?.body == saved.body else { return nil }
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
    func openNoteInWindow(_ id: UUID) -> Bool {
        guard let note = notes?.note(id: id) else { return false }
        finishPluginResult()
        openNoteWindow(note)
        return true
    }
}

extension AskPluginOutput {
    /// What ⌘S would save, when the result can be saved.
    var noteDraft: AskNoteDraft? {
        for action in actions { if case let .toggleNote(draft) = action.kind { return draft } }
        return nil
    }
}
