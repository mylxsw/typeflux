import Foundation

extension AskConversationModel {
    var isNoteCaptureMode: Bool {
        plugins.keyword?.pluginID == AskNoteCapturePlugin.id
    }

    func isNoteCaptureInput(_ text: String) -> Bool {
        switch AskKeywordMatcher.match(text, keywords: launcherKeywords) {
        case let .active(keyword, _), let .hint(keyword): keyword.pluginID == AskNoteCapturePlugin.id
        case nil: false
        }
    }

    /// Entering an empty capture restores its process-local draft, including a failed submission.
    func noteCaptureInput(_ argument: String) -> String {
        guard isNoteCaptureMode else { return argument }
        if noteCapture.saving || argument.isEmpty {
            return noteCapture.body
        }
        return argument
    }

    func clearNoteCapture() {
        guard isNoteCaptureMode, !noteCapture.saving else { return }
        noteCapture = AskNoteCaptureState()
        launcherDraft.text = ""
    }

    /// Returns the admitted task for tests and lifecycle ownership; closing the panel never cancels it.
    @discardableResult
    func submitNoteCapture() -> Task<Void, Never>? {
        guard isNoteCaptureMode, !noteCapture.saving,
              launcherKeywords.contains(where: { $0.enabled && $0 == plugins.keyword }) else { return nil }
        noteCapture.update(launcherDraft.text)
        guard noteCapture.hasContent else { return nil }
        guard let notes else { noteCapture.failure = L("ask.notes.storageUnavailable"); return nil }
        let retrying = noteCapture.submission != nil
        guard let note = noteCapture.begin(at: Date()) else { return nil }
        let generation = noteCapture.generation
        let account = owner
        let task = Task { [weak self] in
            let failure: String?
            var saved = note
            do {
                // An earlier attempt may have committed before reporting an error. Never replace
                // that note on retry: the user could already have edited or deleted it elsewhere.
                if retrying, let existing = try await notes.note(id: note.id) {
                    saved = existing
                    failure = existing.isDeleted ? L("ask.noteCapture.deleted") : nil
                } else {
                    failure = try await notes.save(note) ? nil : L("ask.notes.saveFailed")
                }
            } catch {
                // Store errors can contain paths or text. Only fixed messages cross the UI boundary.
                failure = L("ask.notes.storageUnavailable")
            }
            guard let self, owner == account, noteCapture.generation == generation else { return }
            noteCapture.complete(saved, failure: failure)
            noteCaptureTask = nil
            // Only this capture draft may be cleared, including when reopened during its save.
            guard isNoteCaptureMode,
                  launcherDraft.text == note.body else { return }
            if failure == nil {
                launcherDraft.text = ""
                plugins.update(text: "", selection: nil, language: AppLocalization.shared.language)
            }
        }
        noteCaptureTask = task
        return task
    }

    /// Save private input before folding its keyword, then remove it from the general launcher draft.
    @discardableResult
    func retainNoteCaptureOnDismissal() -> Bool {
        if isNoteCaptureMode, let keyword = plugins.keyword {
            noteCapture.update(launcherDraft.text)
            noteCapture.resumeKeyword = keyword
        } else if case let .active(keyword, argument) = AskKeywordMatcher.match(
            launcherDraft.text,
            keywords: launcherKeywords
        ),
            keyword.pluginID == AskNoteCapturePlugin.id {
            noteCapture.update(argument)
            noteCapture.resumeKeyword = keyword
        } else {
            return false
        }
        plugins.deactivate()
        launcherDraft.text = ""
        return true
    }

    func restoreNoteCaptureForPresentation() -> Bool {
        guard let keyword = noteCapture.resumeKeyword else { return false }
        noteCapture.resumeKeyword = nil
        guard launcherKeywords.contains(where: { $0.enabled && $0 == keyword }) else { return false }
        plugins.enter(keyword)
        var restored = newQuestionDraft()
        restored.text = noteCapture.body
        launcherDraft = restored
        plugins.update(text: launcherDraft.text, selection: nil, language: AppLocalization.shared.language)
        return true
    }
}
