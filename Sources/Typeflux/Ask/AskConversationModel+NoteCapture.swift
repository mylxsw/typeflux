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
        noteCaptureSearchTask?.cancel()
        noteCaptureSearchTask = nil
        noteCapture = AskNoteCaptureState()
        launcherDraft.text = ""
    }

    /// Returns the admitted task for tests and lifecycle ownership; closing the panel never cancels it.
    @discardableResult
    func submitNoteCapture() -> Task<Void, Never>? {
        guard isNoteCaptureMode, !noteCapture.saving,
              launcherKeywords.contains(where: { $0.enabled && $0 == plugins.keyword }) else { return nil }
        noteCapture.update(launcherDraft.text)
        guard noteCapture.canSave else { return nil }
        guard let notes else { noteCapture.failure = L("ask.notes.storageUnavailable"); return nil }
        let retrying = noteCapture.submission != nil
        guard let note = noteCapture.begin(at: Date()) else { return nil }
        let before = noteCapture.submissionBase
        let input = noteCapture.body
        let generation = noteCapture.generation
        let account = owner
        let task = Task { [weak self] in
            let failure: String?
            var saved = note
            var review = false
            do {
                saved = try await AskNoteCaptureWriter(store: notes).save(note, replacing: before, retrying: retrying)
                failure = nil
            } catch {
                let detail = Self.noteCaptureFailure(error, appending: before != nil)
                failure = detail.message
                review = detail.review
            }
            guard let self, owner == account, noteCapture.generation == generation else { return }
            noteCapture.complete(saved, failure: failure)
            noteCapture.requiresReview = review
            noteCaptureTask = nil
            // Only this capture draft may be cleared, including when reopened during its save.
            guard isNoteCaptureMode,
                  launcherDraft.text == input else { return }
            if failure == nil {
                launcherDraft.text = ""
                plugins.update(text: "", selection: nil, language: AppLocalization.shared.language)
            }
        }
        noteCaptureTask = task
        return task
    }

    /// Store diagnostics may contain private paths or text; only fixed copy crosses this boundary.
    static func noteCaptureFailure(_ error: Error, appending: Bool) -> (message: String, review: Bool) {
        switch error {
        case AskNoteCaptureWriter.Failure.missing: (L("ask.noteCapture.deleted"), appending)
        case AskNoteCaptureWriter.Failure.conflict: (L("ask.noteCapture.conflict"), true)
        case AskNoteCaptureWriter.Failure.saveFailed: (L("ask.notes.saveFailed"), false)
        default: (L("ask.notes.storageUnavailable"), false)
        }
    }

    /// Save private input before folding its keyword, then remove it from the general launcher draft.
    @discardableResult
    func retainNoteCaptureOnDismissal() -> Bool {
        noteCaptureSearchTask?.cancel()
        noteCapture.searchID = UUID()
        noteCapture.choosingTarget = false
        noteCapture.searching = false
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
