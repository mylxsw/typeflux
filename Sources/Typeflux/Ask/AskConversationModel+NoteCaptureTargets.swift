import Foundation

extension AskConversationModel {
    func noteCaptureKey(_ key: AskCommandKey) -> Bool {
        guard isNoteCaptureMode else { return false }
        switch key {
        case .enter: activateNoteCapture()
        case .up, .down:
            guard noteCapture.choosingTarget else { return false }
            moveNoteCaptureTarget(key == .up ? -1 : 1)
        case .escape:
            guard noteCapture.choosingTarget else { return false }
            cancelNoteCaptureTargetSearch()
        case .commandEnter, .commandR, .commandS: break
        default: return false
        }
        return true
    }

    func chooseNoteCaptureTarget() {
        guard isNoteCaptureMode, !noteCapture.saving else { return }
        noteCapture.choosingTarget = true
        noteCapture.targetQuery = ""
        searchNoteCaptureTargets()
    }

    func cancelNoteCaptureTargetSearch() {
        noteCaptureSearchTask?.cancel()
        noteCapture.searchID = UUID()
        noteCapture.choosingTarget = false
        noteCapture.searching = false
        launcherHistoryFillID = UUID()
    }

    func searchNoteCaptureTargets() {
        noteCaptureSearchTask?.cancel()
        guard isNoteCaptureMode, noteCapture.choosingTarget, !noteCapture.saving else { return }
        let id = UUID(), generation = noteCapture.generation, account = owner
        let query = String(noteCapture.targetQuery.prefix(256))
        let store = notes
        noteCapture.searchID = id
        noteCapture.searching = true
        noteCapture.matches = []
        noteCapture.searchFailure = nil
        noteCapture.highlightedTarget = 0
        noteCaptureSearchTask = Task { [weak self] in
            let matches: [AskNote]
            let failure: String?
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard let store else { throw LocalStoreFailure.unavailable }
                matches = try await store.list(AskNoteQuery(text: query, limit: 20))
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                matches = []
                failure = L("ask.notes.storageUnavailable")
            }
            guard let self, !Task.isCancelled, owner == account, noteCapture.generation == generation,
                  noteCapture.searchID == id, noteCapture.choosingTarget else { return }
            noteCapture.matches = matches.filter { !$0.isDeleted }
            noteCapture.searchFailure = failure
            noteCapture.searching = false
            noteCaptureSearchTask = nil
        }
    }

    func selectNoteCaptureTarget(_ note: AskNote?) {
        guard isNoteCaptureMode, !noteCapture.saving, note?.isDeleted != true else { return }
        noteCaptureSearchTask?.cancel()
        noteCapture.selectTarget(note)
        launcherHistoryFillID = UUID()
    }

    /// Return in the picker only selects; a separate Return explicitly commits the reviewed addition.
    func activateNoteCapture() {
        if noteCapture.choosingTarget {
            if !noteCapture.searching, let selected = noteCapture.highlighted {
                selectNoteCaptureTarget(selected)
            }
        } else {
            submitNoteCapture()
        }
    }

    func moveNoteCaptureTarget(_ delta: Int) {
        guard noteCapture.choosingTarget, !noteCapture.matches.isEmpty else { return }
        noteCapture.highlightedTarget = min(
            max(0, noteCapture.highlightedTarget + delta),
            noteCapture.matches.count - 1
        )
    }

    @discardableResult
    func reloadNoteCaptureTarget() -> Task<Void, Never>? {
        guard isNoteCaptureMode, !noteCapture.saving, let target = noteCapture.target, let notes else { return nil }
        let generation = noteCapture.generation, account = owner
        noteCapture.saving = true
        let task = Task { [weak self] in
            let note: AskNote?
            do {
                note = try await notes.note(id: target.id)
            } catch {
                guard let self, owner == account, noteCapture.generation == generation else { return }
                noteCapture.saving = false
                noteCapture.failure = L("ask.notes.storageUnavailable")
                noteCaptureTask = nil
                return
            }
            guard let self, owner == account, noteCapture.generation == generation else { return }
            noteCapture.saving = false
            noteCaptureTask = nil
            guard let note, !note.isDeleted else { noteCapture.failure = L("ask.noteCapture.deleted"); return }
            noteCapture.selectTarget(note)
            if isNoteCaptureMode {
                launcherHistoryFillID = UUID()
            }
        }
        noteCaptureTask = task
        return task
    }

    @discardableResult
    func undoNoteCapture() -> Task<Void, Never>? {
        guard isNoteCaptureMode, !noteCapture.saving, let receipt = noteCapture.undo, let notes else { return nil }
        let generation = noteCapture.generation, account = owner
        noteCapture.saving = true
        let task = Task { [weak self] in
            let failure: String?
            do {
                try await AskNoteCaptureWriter(store: notes).undo(receipt, at: Date())
                failure = nil
            } catch AskNoteCaptureWriter.Failure.conflict {
                failure = L("ask.noteCapture.undoConflict")
            } catch {
                failure = L("ask.notes.storageUnavailable")
            }
            guard let self, owner == account, noteCapture.generation == generation else { return }
            noteCapture.saving = false
            noteCapture.failure = failure
            noteCaptureTask = nil
            if failure == nil {
                noteCapture.saved = nil
                noteCapture.undo = nil
                noteCapture.undone = true
            }
        }
        noteCaptureTask = task
        return task
    }
}
