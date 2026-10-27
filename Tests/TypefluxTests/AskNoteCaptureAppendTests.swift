import Foundation
import Testing
@testable import Typeflux

@Suite("Quick note append and recovery", .exclusiveUIState)
@MainActor
struct AskNoteCaptureAppendTests {
    private func prepare(_ fixture: AskTestFixture, store: any AskNoteStoring, body: String = "    Added\n") {
        _ = fixture.model.credentials()
        fixture.model.notes = store
        fixture.model.plugins.enter(AskNoteCapturePlugin.keywords[0])
        fixture.model.launcherDraft.text = body
    }

    @Test(arguments: ["", "Old", "Old\n", "Old\n\n", "Old\n\n\n"])
    func `append preserves both original and addition`(body: String) {
        let addition = "    code\n\n"
        let separator = body.isEmpty || body.hasSuffix("\n\n") ? "" : body.hasSuffix("\n") ? "\n" : "\n\n"
        #expect(AskNoteCaptureState.appending(addition, to: body) == body + separator + addition)
    }

    @Test func `state preserves origin and requires explicit target selection for every capture`() throws {
        var before = makeTestNote("Original", at: 10)
        before.body = "AI answer"
        before.source = .chat
        before.author = .agent
        before.tags = ["private"]
        before.pinned = true
        before.model = "test-model"
        before.conversationID = "conversation"
        var state = AskNoteCaptureState()
        state.update("Extra")
        state.selectTarget(before)
        let pending = state.begin(at: Date(timeIntervalSince1970: 20))
        let note = try #require(pending)
        #expect(note.id == before.id && note.body == "AI answer\n\nExtra")
        #expect(note.title == before.title && note.source == .chat && note.originalBody == before.body)
        #expect(note.tags == before.tags && note.pinned && note.model == before.model)
        #expect(note.conversationID == before.conversationID && note.createdAt == before.createdAt)
        #expect(note.author == .user && note.editedAt == note.updatedAt)
        state.complete(note, failure: nil)
        #expect(state.savedWasAppend && state.undo?.before == before && state.target == nil)
        state.update("Another note")
        let next = state.begin(at: Date())
        #expect(next?.id != before.id && next?.body == "Another note")
    }

    @Test func `append and revision commit together and undo restores only the text`() async throws {
        let store = makeTestNotes()
        var before = makeTestNote("Existing", at: 10)
        before.body = "Original"
        before.tags = ["Work"]
        try store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        f.model.selectNoteCaptureTarget(before)
        await f.model.submitNoteCapture()?.value
        let saved = try #require(try store.note(id: before.id))
        #expect(saved.body == "Original\n\n    Added\n")
        #expect(try store.count(.all) == 1)
        #expect(try store.revisions(of: before.id).map(\.body) == ["Original"])
        #expect(f.model.noteCapture.savedWasAppend && f.model.launcherDraft.text.isEmpty)
        await f.model.undoNoteCapture()?.value
        let undone = try #require(try store.note(id: before.id))
        #expect(undone.body == before.body && undone.tags == before.tags && undone.author == .user)
        #expect(f.model.noteCapture.undone && f.model.noteCapture.undo == nil)
    }

    @Test func `conflicting target must be reloaded and reviewed before another write`() async throws {
        let store = makeTestNotes()
        let before = makeTestNote("Same title", at: 10)
        try store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store, body: "Addition")
        f.model.selectNoteCaptureTarget(before)
        var changed = before
        changed.body = "Edited in another window"
        try store.save(changed)
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.requiresReview && !f.model.noteCapture.canSave)
        #expect(f.model.noteCapture.failure == L("ask.noteCapture.conflict"))
        #expect(f.model.launcherDraft.text == "Addition")
        #expect(f.model.submitNoteCapture() == nil)
        #expect(try store.revisions(of: before.id).isEmpty)
        await f.model.reloadNoteCaptureTarget()?.value
        #expect(!f.model.noteCapture.requiresReview && f.model.noteCapture.target?.body == changed.body)
        #expect(try store.note(id: before.id)?.body == changed.body, "Reload only previews")
        await f.model.submitNoteCapture()?.value
        #expect(try store.note(id: before.id)?.body == changed.body + "\n\nAddition")
    }

    @Test func `deleted target never becomes an implicit new note`() async throws {
        let store = makeTestNotes()
        let before = makeTestNote("Deleted", at: 10)
        try store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        f.model.selectNoteCaptureTarget(before)
        try store.trash(ids: [before.id], at: Date())
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.requiresReview && f.model.noteCapture.failure == L("ask.noteCapture.deleted"))
        await f.model.reloadNoteCaptureTarget()?.value
        #expect(f.model.noteCapture.requiresReview)
        #expect(try store.count(.all) == 0 && store.count(.trash) == 1)
        f.model.selectNoteCaptureTarget(nil)
        await f.model.submitNoteCapture()?.value
        #expect(try store.count(.all) == 1 && store.count(.trash) == 1)
    }

    @Test func `uncertain commit retry cannot append twice or lose newer tags`() async throws {
        let store = CaptureTestStore()
        let before = makeTestNote("Existing", at: 10)
        _ = try await store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store, body: "Addition")
        f.model.selectNoteCaptureTarget(before)
        await store.configure(failure: .afterCommit)
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
        let expected = try #require(f.model.noteCapture.submission)
        var edited = expected
        edited.tags = ["New tag"]
        _ = try await store.save(edited)
        await f.model.submitNoteCapture()?.value
        #expect(try await store.note(id: before.id) == edited)
        #expect(await store.revisions(of: before.id).count == 1)
        #expect(f.model.noteCapture.saved?.id == before.id)
        await f.model.undoNoteCapture()?.value
        #expect(try await store.note(id: before.id)?.body == before.body)
        #expect(try await store.note(id: before.id)?.tags == ["New tag"])
    }

    @Test func `uncertain commit followed by another edit requires review`() async throws {
        let store = CaptureTestStore()
        let before = makeTestNote("Existing", at: 10)
        _ = try await store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        f.model.selectNoteCaptureTarget(before)
        await store.configure(failure: .afterCommit)
        await f.model.submitNoteCapture()?.value
        var edited = try #require(f.model.noteCapture.submission)
        edited.body += "\nLater edit"
        _ = try await store.save(edited)
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.requiresReview && f.model.launcherDraft.text == "    Added\n")
        #expect(try await store.note(id: before.id) == edited)
        #expect(await store.revisions(of: before.id).count == 1)
    }

    @Test func `choosing and searching never write or use titles as identity`() async throws {
        let store = makeTestNotes()
        let one = makeTestNote("Same title", at: 10), two = makeTestNote("Same title", at: 20)
        try store.save(one); try store.save(two)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store, body: "Extra")
        f.model.chooseNoteCaptureTarget()
        await f.model.noteCaptureSearchTask?.value
        #expect(f.model.noteCapture.matches.count == 2 && f.model.noteCapture.choosingTarget)
        #expect(!f.model.noteCapture.canSave && f.model.noteCapture.actionEnabled)
        #expect(f.model.noteCapture.actionTitleKey == "ask.noteCapture.select")
        #expect(f.model.noteCaptureKey(.down))
        let selected = try #require(f.model.noteCapture.highlighted)
        f.model.activateNoteCapture()
        #expect(f.model.noteCapture.target?.id == selected.id)
        #expect(try store.note(id: selected.id)?.body == selected.body)
        f.model.activateNoteCapture()
        await f.model.noteCaptureTask?.value
        #expect(try store.note(id: selected.id)?.body == selected.body + "\n\nExtra")
        let other = selected.id == one.id ? two : one
        #expect(try store.note(id: other.id)?.body == other.body)
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
    }

    @Test func `picker filters trash allows private tags and bounds its results`() async throws {
        let store = makeTestNotes()
        for index in 0 ..< 25 {
            try store.save(makeTestNote("Note \(index)", at: Double(index)))
        }
        var secret = makeTestNote("Secret", at: 100)
        secret.tags = ["private"]
        try store.save(secret)
        let removed = makeTestNote("Secret trash", at: 110)
        try store.save(removed); try store.trash(ids: [removed.id], at: Date())
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        f.model.chooseNoteCaptureTarget()
        await f.model.noteCaptureSearchTask?.value
        #expect(f.model.noteCapture.matches.count == 20)
        f.model.noteCapture.targetQuery = "Secret"
        f.model.searchNoteCaptureTargets()
        await f.model.noteCaptureSearchTask?.value
        #expect(f.model.noteCapture.matches.map(\.id) == [secret.id])
        f.model.noteCapture.targetQuery = "No match"
        f.model.searchNoteCaptureTargets()
        await f.model.noteCaptureSearchTask?.value
        f.model.activateNoteCapture()
        #expect(f.model.noteCapture.choosingTarget && !f.model.noteCapture.actionEnabled)
        #expect(f.model.noteCaptureKey(.escape))
        #expect(!f.model.noteCapture.choosingTarget && f.model.noteCapture.body == "    Added\n")
        #expect(!f.model.noteCaptureKey(.up) && !f.model.noteCaptureKey(.escape))
        #expect(f.model.noteCaptureKey(.commandEnter) && !f.model.noteCaptureKey(.left))
    }

    @Test func `cancelled search cannot replace A newer query or account`() async throws {
        let store = CaptureTestStore()
        _ = try await store.save(makeTestNote("Old", at: 10))
        _ = try await store.save(makeTestNote("New", at: 20))
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        await store.suspendSearch()
        f.model.chooseNoteCaptureTarget()
        let old = f.model.noteCaptureSearchTask
        for _ in 0 ..< 100 {
            if await store.searchStarted {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        f.model.noteCapture.targetQuery = "New"
        f.model.searchNoteCaptureTargets()
        await store.releaseSearch()
        await old?.value
        await f.model.noteCaptureSearchTask?.value
        #expect(f.model.noteCapture.matches.map(\.title) == ["New"])
        f.model.chooseNoteCaptureTarget()
        let cancelled = f.model.noteCaptureSearchTask
        f.model.resetSession()
        await cancelled?.value
        #expect(f.model.noteCapture.matches.isEmpty && !f.model.noteCapture.choosingTarget)
    }

    @Test func `storage failures retain search and append input without diagnostics`() async throws {
        let store = CaptureTestStore()
        let before = makeTestNote("Existing", at: 10)
        _ = try await store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        await store.setSearchFailure(true)
        f.model.chooseNoteCaptureTarget()
        await f.model.noteCaptureSearchTask?.value
        #expect(f.model.noteCapture.searchFailure == L("ask.notes.storageUnavailable"))
        f.model.cancelNoteCaptureTargetSearch()
        f.model.selectNoteCaptureTarget(before)
        await store.setReadFailure(true)
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
        await f.model.reloadNoteCaptureTarget()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
        #expect(f.model.noteCapture.body == "    Added\n")
        await store.setReadFailure(false)
        await f.model.submitNoteCapture()?.value
        await store.setReadFailure(true)
        await f.model.undoNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
    }

    @Test(arguments: [false, true])
    func `undo cannot overwrite subsequent edits`(appending: Bool) async throws {
        let store = makeTestNotes()
        let before = makeTestNote("Existing", at: 10)
        try store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        if appending {
            f.model.selectNoteCaptureTarget(before)
        }
        await f.model.submitNoteCapture()?.value
        var edited = try #require(f.model.noteCapture.saved)
        edited.body = "A newer edit"
        try store.save(edited)
        await f.model.undoNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.noteCapture.undoConflict"))
        #expect(try store.note(id: edited.id)?.body == edited.body)
    }

    @Test func `undo new note uses trash and can reconcile an already undone save`() async throws {
        let store = makeTestNotes()
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store)
        await f.model.submitNoteCapture()?.value
        let receipt = try #require(f.model.noteCapture.undo)
        await f.model.undoNoteCapture()?.value
        #expect(try store.count(.all) == 0 && store.count(.trash) == 1)
        try await AskNoteCaptureWriter(store: store).undo(receipt, at: Date())
        #expect(f.model.noteCapture.undone)
    }

    @Test func `closing during append retains target until commit and account reset ignores late completion`(
    ) async throws {
        let store = CaptureTestStore()
        let before = makeTestNote("Existing", at: 10)
        _ = try await store.save(before)
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, store: store, body: "Extra")
        f.model.selectNoteCaptureTarget(before)
        f.model.foldLauncherKeyword()
        #expect(f.model.resetLauncherForPresentation())
        #expect(f.model.noteCapture.target?.id == before.id && f.model.launcherDraft.text == "Extra")
        await store.configure(paused: true)
        let task = try #require(f.model.submitNoteCapture())
        f.model.foldLauncherKeyword()
        #expect(f.model.resetLauncherForPresentation())
        #expect(f.model.noteCapture.saving && f.model.submitNoteCapture() == nil)
        await store.release()
        await task.value
        #expect(f.model.launcherDraft.text.isEmpty && f.model.noteCapture.target == nil)
        try f.model.selectNoteCaptureTarget(#require(f.model.noteCapture.saved))
        f.model.launcherDraft.text = "Another"
        await store.configure(paused: true)
        let stale = try #require(f.model.submitNoteCapture())
        f.model.resetSession()
        await store.release()
        await stale.value
        #expect(f.model.noteCapture.saved == nil)
    }
}
