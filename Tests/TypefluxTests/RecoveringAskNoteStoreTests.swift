import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class NotebookFaultStore: AskNoteStoring, @unchecked Sendable {
    let base: SQLiteAskNoteStore
    private let lock = NSLock()
    private var readsFail = false
    private var writesFail = false
    private var writes = 0
    private var gate: DispatchSemaphore?
    init(_ base: SQLiteAskNoteStore) { self.base = base }
    func faults(reads: Bool = false, writes: Bool = false) {
        lock.withLock { readsFail = reads; writesFail = writes }
    }
    func blockWrites(_ gate: DispatchSemaphore) { lock.withLock { self.gate = gate } }
    var attempts: Int { lock.withLock { writes } }
    private func read() throws { if lock.withLock({ readsFail }) { throw LocalStoreFailure.unavailable } }
    private func write() throws {
        let state = lock.withLock { writes += 1; return (writesFail, gate) }
        if state.0 { throw LocalStoreFailure.busy }
        if let gate = state.1 { _ = gate.wait(timeout: .now() + 3) }
    }
    func note(id: UUID) throws -> AskNote? { try read(); return try base.note(id: id) }
    func list(_ query: AskNoteQuery) throws -> [AskNote] { try read(); return try base.list(query) }
    func count(_ scope: AskNoteQuery.Scope) throws -> Int { try read(); return try base.count(scope) }
    func commands() throws -> [AskNoteFacet] { try read(); return try base.commands() }
    func sources() throws -> [AskNoteFacet] { try read(); return try base.sources() }
    func tags() throws -> [AskNoteFacet] { try read(); return try base.tags() }
    func revisions(of id: UUID) throws -> [AskNoteRevision] { try read(); return try base.revisions(of: id) }
    func save(_ note: AskNote) throws -> Bool { try write(); return try base.save(note) }
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) throws -> Bool {
        try write(); return try base.save(note, replacing: previous, revisionAt: date)
    }
    func delete(ids: [UUID]) throws { try write(); try base.delete(ids: ids) }
    func restore(_ notes: [AskNote]) throws { try write(); try base.restore(notes) }
    func trash(ids: [UUID], at date: Date) throws { try write(); try base.trash(ids: ids, at: date) }
    func purgeTrash(before date: Date) throws { try write(); try base.purgeTrash(before: date) }
    func saveRevision(_ note: AskNote, at date: Date) throws { try write(); try base.saveRevision(note, at: date) }
    func deleteRevision(of id: UUID, at date: Date) throws { try write(); try base.deleteRevision(of: id, at: date) }
}

@Suite("Notebook supervised storage", .exclusiveUIState)
@MainActor
struct RecoveringAskNoteStoreTests {
    private func policy() -> ModulePolicy {
        var policy = ModulePolicy(); policy.automaticallyRecover = false; return policy
    }
    private func settle(_ store: RecoveringAskNoteStore) async throws {
        for _ in 0..<400 {
            let health = await store.module.supervisor.health()
            if !health.hasLifecycleWork && health.activeOperations == 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Notebook cleanup did not settle")
    }

    @Test func failedOpenReopensWithoutReplayingTheWrite() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        try Data("occupied".utf8).write(to: fixture.root)
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskNoteStore(factory: {
            clock.open(); return SQLiteAskNoteStore(url: fixture.url)
        }, policy: policy(), uptime: { clock.now() })
        #expect(clock.opens == 0)
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.list(.init()) }
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.save(makeTestNote()) }
        try await settle(store)
        try FileManager.default.removeItem(at: fixture.root)
        clock.advance()
        #expect(try await store.count(.all) == 0)
        #expect(clock.opens == 2)
        let note = makeTestNote()
        #expect(try await store.save(note))
        await store.module.setEnabled(false)
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.note(id: note.id) }
        try await settle(store)
        await store.module.setEnabled(true)
        #expect(try await store.note(id: note.id) == note)
        store.preventNewWork()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.count(.all) }
        await store.shutdown()
    }

    @Test func everyOperationPreservesDataAndRevisionSemanticsAcrossReopen() async throws {
        let base = makeTestNotes()
        let fault = NotebookFaultStore(base)
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskNoteStore(factory: { clock.open(); return fault }, policy: policy(), uptime: { clock.now() })
        let note = makeTestNote(tags: ["tag"], pinned: true)
        #expect(try await store.save(note))
        var edited = note; edited.body = "edited"
        #expect(try await store.save(edited, replacing: note, revisionAt: note.updatedAt))
        #expect(try await store.revisions(of: note.id).count == 1)
        #expect(try await store.commands().count == 1)
        #expect(try await store.sources().count == 1)
        #expect(try await store.tags().count == 1)
        #expect(try await store.list(.init()).first == edited)
        #expect(try await store.save(note, replacing: note, revisionAt: .now) == false)
        #expect(clock.opens == 1, "An edit conflict is not a storage failure")
        try await store.deleteRevision(of: note.id, at: note.updatedAt)
        try await store.saveRevision(edited, at: note.updatedAt)
        fault.faults(writes: true)
        await #expect(throws: LocalStoreFailure.busy) { try await store.save(note) }
        try await settle(store)
        let attempts = fault.attempts
        fault.faults(); clock.advance()
        #expect(try await store.note(id: note.id)?.body == "edited")
        #expect(fault.attempts == attempts, "Recovery must not repeat a mutation")
        try await store.trash(ids: [note.id], at: note.updatedAt)
        #expect(try await store.count(.trash) == 1)
        try await store.purgeTrash(before: note.updatedAt.addingTimeInterval(1))
        #expect(try await store.count(.all) == 0)
        try await store.restore([note])
        try await store.delete(ids: [note.id])
        #expect(try await store.note(id: note.id) == nil)
        await store.shutdown()
    }

    @Test func lockedWritesLeaveTheNoteAndRevisionsUnchanged() async throws {
        let fixture = WordBookFaultFixture()
        defer { fixture.clean() }
        let base = SQLiteAskNoteStore(url: fixture.url, busyTimeoutMilliseconds: 1)
        let note = makeTestNote()
        try base.save(note)
        var db: OpaquePointer?
        try #require(sqlite3_open(fixture.url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        var edited = note; edited.body = "must not persist"
        #expect(throws: LocalStoreFailure.busy) { try base.save(edited, replacing: note, revisionAt: .now) }
        #expect(try base.note(id: note.id) == note)
        #expect(try base.revisions(of: note.id).isEmpty)
        try #require(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try fixture.sql("UPDATE notes SET tags_json = 'invalid';")
        #expect(throws: LocalStoreFailure.invalidData) { try base.list(.init()) }
        try fixture.sql("UPDATE notes SET tags_json = '[]', id = 'invalid';")
        #expect(throws: LocalStoreFailure.invalidData) { try base.list(.init()) }
    }

    @Test func uncertainCompletedWriteIsNeverAutomaticallyRepeated() async throws {
        let base = makeTestNotes()
        let fault = NotebookFaultStore(base)
        let gate = DispatchSemaphore(value: 0)
        fault.blockWrites(gate)
        var policy = policy(); policy.operationTimeout = 0.03
        let clock = WordBookRecoveryClock()
        let store = RecoveringAskNoteStore(factory: { fault }, policy: policy, uptime: { clock.now() })
        let note = makeTestNote()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.save(note) }
        clock.advance()
        await #expect(throws: LocalStoreFailure.unavailable) { try await store.save(note) }
        #expect(fault.attempts == 1)
        gate.signal()
        try await settle(store)
        clock.advance()
        #expect(try await store.note(id: note.id) == note)
        #expect(fault.attempts == 1)
        await store.shutdown()
    }
}

@Suite("Notebook caller failure handling", .exclusiveUIState)
@MainActor
struct NotebookCallerFailureTests {
    @Test func unavailableReadsKeepHistoryAndDraftWithoutInventingAConflict() async throws {
        let base = makeTestNotes()
        let original = makeTestNote()
        try base.save(original)
        let fault = NotebookFaultStore(base)
        let model = AskNotesViewModel(store: fault, notificationCenter: NotificationCenter())
        await model.waitForReload()
        model.autosaveDelay = .seconds(60)
        model.beginEditing()
        model.draftBody = "unsaved"
        fault.faults(reads: true)
        await model.reload().value
        #expect(model.notes == [original])
        #expect(await model.saveDraft() == false)
        #expect(!model.draftConflict && model.hasUnsavedDraft && model.draftBody == "unsaved")
        #expect(model.notice == L("ask.notes.storageUnavailable"))
        model.stageTitle("title draft", id: original.id)
        #expect(await model.savePendingTitle() == false)
        #expect(model.pendingTitle == "title draft" && !model.draftConflict)
        #expect(await model.finishEditing() == false)
        fault.faults()
        #expect(await model.finishEditing())
        #expect(try base.note(id: original.id)?.body == "unsaved")
        #expect(try base.note(id: original.id)?.title == "title draft")
    }

    @Test func editsTypedDuringSaveStayDirtyAndAreNotOverwritten() async throws {
        let base = makeTestNotes(); let note = makeTestNote()
        try base.save(note)
        let fault = NotebookFaultStore(base)
        let facade = RecoveringAskNoteStore(factory: { fault })
        let model = AskNotesViewModel(store: facade, notificationCenter: NotificationCenter())
        await model.waitForReload()
        model.autosaveDelay = .seconds(60)
        model.beginEditing(); model.draftBody = "submitted"
        let gate = DispatchSemaphore(value: 0); fault.blockWrites(gate)
        let task = Task { await model.saveDraft() }
        for _ in 0..<200 where fault.attempts == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fault.attempts == 1)
        model.draftBody = "newer text"
        gate.signal()
        #expect(await task.value == false)
        #expect(model.hasUnsavedDraft && model.draftBody == "newer text" && model.editing)
        #expect(try base.note(id: note.id)?.body == "submitted")
        await facade.shutdown()
    }

    @Test func failedDeletesKeepSelectionAndUndoState() async throws {
        let base = makeTestNotes(); let note = makeTestNote()
        try base.save(note)
        let fault = NotebookFaultStore(base)
        let model = AskNotesViewModel(store: fault, notificationCenter: NotificationCenter())
        await model.waitForReload()
        fault.faults(writes: true)
        await model.deleteSelected()
        #expect(model.selectedID == note.id && model.deleted.isEmpty && !model.noticeOffersUndo)
        await model.togglePin()
        #expect(try base.note(id: note.id)?.pinned == false)
        fault.faults()
        await model.deleteSelected()
        let deleted = model.deleted
        fault.faults(writes: true)
        await model.undoDelete()
        #expect(model.deleted == deleted)
        model.scope = .trash; await model.waitForNavigation()
        await model.deleteForever()
        #expect(model.notes.count == 1)
        await model.emptyTrash()
        #expect(model.notes.count == 1)
    }

    @Test func toolAndLauncherReportUnavailableInsteadOfMissingNotes() async throws {
        let fault = NotebookFaultStore(makeTestNotes()); fault.faults(reads: true)
        let tool = AskNotebookTool(store: fault)
        await #expect(throws: LocalStoreFailure.unavailable) { try await tool.execute(["action": "list"]) }
        await #expect(throws: LocalStoreFailure.unavailable) {
            try await tool.execute(["action": "read", "id": UUID().uuidString])
        }
        let plugin = AskNotesPlugin(store: fault)
        let request = AskPluginRequest(text: "", origin: .argument, keyword: AskNotesPlugin.keywords[0], options: [:],
                                      interfaceLanguage: .english)
        await #expect(throws: AskPluginFailure.self) {
            try await plugin.run(request, plan: await plugin.plan(request))
        }
    }

    @Test func resultWindowKeepsConfirmedStarWhenStorageFails() async throws {
        let id = UUID()
        let document = AskResultDocument(title: "title", keyword: "ex", model: nil, input: "", body: "body",
                                         state: .done, noteID: id,
                                         services: .init(noteExists: { _ in throw LocalStoreFailure.unavailable }))
        await document.refreshNote()?.value
        #expect(document.noteID == id)
        await document.toggleNote()?.value
        #expect(document.noteID == id && document.notice == L("ask.notes.storageUnavailable"))
        document.close()
    }
}

extension NotebookCallerFailureTests {
    @Test func failedReadsAndWritesNeverDiscardTheVisibleSnapshot() async throws {
        let base = makeTestNotes(); let note = makeTestNote()
        try base.save(note)
        let fault = NotebookFaultStore(base)
        let model = AskNotesViewModel(store: fault, notificationCenter: NotificationCenter())
        await model.waitForReload()
        await model.setSelecting(true)
        fault.faults(reads: true, writes: true)
        await model.reveal(note.id)
        await model.rename("new")
        await model.togglePin()
        await model.addTag("tag")
        await model.removeTag("tag")
        await model.toggleTask(0)
        await model.revertAgentChange()
        await model.deleteSelected()
        await model.pinPicked()
        await model.tagPicked("tag")
        await model.trashPicked()
        await model.exportAll()
        #expect(model.selectedID == note.id && model.notes == [note] && model.deleted.isEmpty)
        #expect(model.notice == L("ask.notes.storageUnavailable"))
        model.autosaveDelay = .seconds(60)
        model.beginEditing(); model.draftBody = "keep draft"
        await model.saveDraftCopy()
        #expect(model.draftBody == "keep draft" && model.hasUnsavedDraft)
        fault.faults()
        #expect(await model.finishEditing())
        fault.faults(writes: true)
        #expect(await model.createNote(title: "must fail") == nil)
        model.beginEditing(); model.draftBody = "another draft"
        await model.saveDraftCopy()
        #expect(model.draftBody == "another draft" && model.hasUnsavedDraft)
        #expect(try base.count(.all) == 1)
    }

    @Test func titleTypedDuringSaveKeepsItsNewBaselineAndPendingText() async throws {
        let base = makeTestNotes(); let note = makeTestNote()
        try base.save(note)
        let fault = NotebookFaultStore(base)
        let facade = RecoveringAskNoteStore(factory: { fault })
        let model = AskNotesViewModel(store: facade, notificationCenter: NotificationCenter())
        await model.waitForReload()
        model.autosaveDelay = .seconds(60)
        model.stageTitle("submitted", id: note.id)
        let gate = DispatchSemaphore(value: 0); fault.blockWrites(gate)
        let task = Task { await model.savePendingTitle() }
        for _ in 0..<200 where fault.attempts == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(fault.attempts == 1)
        model.stageTitle("newer title", id: note.id)
        gate.signal()
        #expect(await task.value == false)
        #expect(model.pendingTitle == "newer title")
        #expect(try base.note(id: note.id)?.title == "submitted")
        gate.signal()
        #expect(await model.savePendingTitle())
        #expect(try base.note(id: note.id)?.title == "newer title")
        await facade.shutdown()
    }

    @Test func closingAResultWindowFencesALateSave() async throws {
        var continuation: CheckedContinuation<UUID?, Never>?
        var calls = 0
        let doc = AskResultDocument(title: "title", keyword: "ex", model: nil, input: "", body: "body", state: .done,
                                    services: .init(saveNote: { _ in
                                        calls += 1
                                        return await withCheckedContinuation { continuation = $0 }
                                    }))
        let task = doc.toggleNote()
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 1)
        #expect(doc.toggleNote() == nil, "Repeated clicks are not queued")
        doc.close()
        continuation?.resume(returning: UUID())
        await task?.value
        #expect(doc.noteID == nil && doc.notice != L("ask.notes.saved"))
        #expect(calls == 1)
    }

    @Test func livePrivacyRevocationPreventsReturningNotebookContent() async throws {
        let base = makeTestNotes(); try base.save(makeTestNote(body: "private body"))
        var checks = 0
        let tool = AskNotebookTool(store: base, validateAccess: {
            checks += 1
            if checks > 1 { throw AskLocalError.message("revoked") }
        })
        await #expect(throws: AskLocalError.self) { try await tool.execute(["action": "list"]) }
        #expect(checks == 2, "The live policy is checked again after the read")
    }
}
