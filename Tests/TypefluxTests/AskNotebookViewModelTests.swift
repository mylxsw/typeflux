import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Notebook window model", .exclusiveUIState)
@MainActor
struct AskNotebookViewModelTests {
    private func model(_ store: SQLiteAskNoteStore, at seconds: TimeInterval = 5000) -> AskNotesViewModel {
        let model = AskNotesViewModel(store: store, notificationCenter: NotificationCenter())
        model.clock = { Date(timeIntervalSince1970: seconds) }
        model.autosaveDelay = .milliseconds(10)
        return model
    }

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "notebook-vm-\(UUID().uuidString)")!)
    }

    @Test func createsNotesAndSavesEditsWhileTyping() async throws {
        let store = makeTestNotes()
        store.save(makeTestNote("Tagged", tags: ["work"]))
        let notes = model(store)
        notes.scope = .tag("work")
        let id = try #require(notes.createNote())
        #expect(notes.selectedID == id && notes.mode == .edit && notes.scope == .tag("work"))
        #expect(store.note(id: id)?.tags == ["work"] && store.note(id: id)?.source == .manual)
        notes.draftBody = "# Plan\n\n- [ ] one"
        #expect(notes.hasUnsavedDraft)
        for _ in 0 ..< 200 where notes.hasUnsavedDraft { try await Task.sleep(for: .milliseconds(5)) }
        let saved = try #require(store.note(id: id))
        #expect(saved.body == "# Plan\n\n- [ ] one" && saved.title == "Plan" && saved.originalBody == nil)
        notes.setMode(.split)
        #expect(notes.mode == .split && notes.editing)
        notes.toggleEditing()
        #expect(notes.mode == .read)
        notes.toggleTask(0)
        #expect(store.note(id: id)?.body == "# Plan\n\n- [x] one")
        notes.toggleTask(9)
        notes.rename("")
        #expect(store.note(id: id)?.title == "Plan", "a written note falls back to its first heading")
        notes.scope = .pinned
        let other = try #require(notes.createNote(title: "  From search "))
        #expect(notes.scope == .all && store.note(id: other)?.title == "From search")
        notes.draftBody = ""
        notes.rename("")
        #expect(store.note(id: other)?.title == L("ask.notes.untitled"))
    }

    @Test func preservesUserEditsAndRevertsTheAgentsRevision() throws {
        let store = makeTestNotes()
        var note = makeTestNote("AI", body: "generated")
        note.source = .chat
        note.conversationID = "conv"
        store.save(note)
        let notes = model(store)
        var opened: [String] = []
        #expect(!notes.canOpenSource)
        notes.openConversation = { opened.append($0) }
        #expect(notes.canOpenSource)
        notes.openSource()
        #expect(opened == ["conv"])
        notes.beginEditing()
        notes.draftBody = "mine"
        notes.setMode(.read)
        #expect(store.note(id: note.id)?.originalBody == "generated")
        #expect(store.note(id: note.id)?.body == "mine" && store.note(id: note.id)?.editedAt != nil)
        #expect(notes.notice == nil)

        #expect(notes.agentRevision == nil)
        let tool = AskNotebookTool(store: store, clock: { Date(timeIntervalSince1970: 6000) })
        _ = try tool.execute(["action": "append", "id": note.id.uuidString, "body": "agent text"])
        notes.reload()
        #expect(notes.selected?.author == .agent && notes.agentRevision?.body == "mine")
        notes.revertAgentChange()
        #expect(store.note(id: note.id)?.body == "mine" && store.note(id: note.id)?.author == .user)
        #expect(notes.notice == L("ask.notes.agentReverted") && store.revisions(of: note.id).isEmpty)
    }

    @Test func groupsSearchesAndFiltersByTag() {
        let store = makeTestNotes()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12))!
        store.save(makeTestNote("Pinned", pinned: true, at: now.timeIntervalSince1970 - 10 * 86400))
        store.save(makeTestNote("Today", body: "apple", tags: ["fruit"], at: now.timeIntervalSince1970 - 60))
        store.save(makeTestNote("Yesterday", body: "apple pie", at: now.timeIntervalSince1970 - 86400))
        store.save(makeTestNote("Week", at: now.timeIntervalSince1970 - 3 * 86400))
        store.save(makeTestNote("Old", at: now.timeIntervalSince1970 - 9 * 86400))
        let notes = model(store, at: now.timeIntervalSince1970)
        let sections = AskNotesViewModel.sections(notes.notes, sort: .updated, trash: false, now: now)
        #expect(sections.map(\.title) == [L("ask.notes.group.pinned"), L("ask.notes.group.today"),
                                          L("ask.notes.group.yesterday"), L("ask.notes.group.week"),
                                          L("ask.notes.group.earlier")])
        #expect(AskNotesViewModel.sections(notes.notes, sort: .title, trash: false, now: now).count == 1)
        #expect(AskNotesViewModel.sections([], sort: .title, trash: false, now: now).isEmpty)
        #expect(notes.sections.count == 5)
        #expect(AskNotesViewModel.parseSearch("apple #Fruit  #") == ("apple", ["Fruit"]))
        notes.searchText = "apple"
        #expect(notes.notes.map(\.title) == ["Today", "Yesterday"])
        notes.searchText = "apple #fruit"
        #expect(notes.notes.map(\.title) == ["Today"])
        #expect(notes.title(of: .recent) == L("ask.notes.shelf.recent") && notes.title(of: .trash) == L("ask.notes.shelf.trash"))
        #expect(notes.title(of: .source(.chat)) == AskNoteSource.chat.title)
        #expect(notes.counts[.recent] != nil && notes.sources[.command] == 5)
        notes.scope = .source(.chat)
        #expect(notes.scope == .all, "an empty source shelf falls back to all notes")
    }

    @Test func picksSeveralNotesForOneAction() throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", body: "1", at: 30), b = makeTestNote("B", body: "2", at: 20), c = makeTestNote("C", body: "3", at: 10)
        [a, b, c].forEach { store.save($0) }
        let notes = model(store)
        var copied: [String] = []
        notes.copy = { copied.append($0) }
        notes.togglePick(b.id)
        #expect(notes.selecting && notes.picked == [a.id, b.id], "picking starts from the chosen note")
        notes.togglePick(a.id)
        notes.pickRange(to: c.id)
        #expect(notes.picked == [a.id, b.id, c.id], "⇧ click picks from the last clicked note")
        notes.pickAll()
        #expect(notes.pickedNotes.map(\.title) == ["A", "B", "C"])
        notes.pinPicked()
        #expect(store.count(.pinned) == 3)
        notes.pinPicked()
        #expect(store.count(.pinned) == 0)
        notes.tagPicked("#batch")
        notes.tagPicked(" ")
        #expect(store.tags().first?.name == "batch" && store.tags().first?.count == 3)
        notes.copyPicked()
        #expect(copied == [AskNoteExporter.merged(notes.pickedNotes)] && notes.notice == L("ask.notes.copiedSeveral", 3))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var revealed: [URL] = []
        notes.revealInFinder = { revealed.append($0) }
        notes.chooseFolder = { folder }
        notes.exportPicked()
        #expect(notes.noticeReveals != nil)
        notes.revealNoticeTarget()
        #expect(revealed.count == 1 && (try? FileManager.default.contentsOfDirectory(atPath: revealed[0].path).count) == 3)
        notes.chooseFolder = { nil }
        notes.exportAll()
        notes.setSelecting(false)
        notes.togglePick(b.id)
        notes.trashPicked()
        #expect(store.count(.all) == 1 && !notes.selecting && notes.noticeOffersUndo)
        notes.undoDelete()
        #expect(store.count(.all) == 3 && store.count(.trash) == 0, "one undo puts back the whole batch")
        notes.trashPicked()
    }

    @Test func recentlyDeletedRestoresAndDeletesForGood() throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", at: 20), b = makeTestNote("B", at: 10)
        store.save(a)
        store.save(b)
        let notes = model(store)
        notes.deleteSelected()
        notes.select(b.id)
        notes.deleteSelected()
        #expect(store.count(.trash) == 2 && notes.notes.isEmpty)
        notes.scope = .trash
        #expect(notes.inTrash && notes.notes.count == 2)
        notes.setSelecting(true)
        notes.pickAll()
        #expect(!notes.selecting, "nothing is picked in Recently Deleted")
        notes.beginEditing()
        #expect(!notes.editing, "deleted notes are read-only")
        let first = try #require(notes.selectedID)
        notes.restoreFromTrash()
        #expect(store.note(id: first)?.isDeleted == false && notes.notes.count == 1)
        notes.deleteSelected()
        #expect(store.count(.trash) == 0, "in Recently Deleted, delete removes for good")
        notes.reveal(first)
        #expect(notes.scope == .all && notes.selectedID == first)
        notes.deleteSelected()
        notes.scope = .trash
        notes.emptyTrash()
        #expect(store.count(.trash) == 0 && notes.notes.isEmpty)
        notes.restoreFromTrash()
        notes.deleteForever()
    }

    @Test func importsAndExportsFormats() throws {
        let store = makeTestNotes()
        let notes = model(store)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Imported.md")
        try "# Hello\nworld".write(to: file, atomically: true, encoding: .utf8)
        notes.chooseImportFiles = { [file, folder.appendingPathComponent("x.png")] }
        notes.scope = .pinned
        notes.importFiles()
        #expect(notes.scope == .all && notes.selected?.title == "Hello" && notes.selected?.source == .import)
        #expect(notes.notice == L("ask.notes.importedSkipped", 1, 1))
        notes.importFiles([])
        notes.chooseExportURL = { folder.appendingPathComponent($0) }
        notes.exportSelected(.html)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Hello.html").path))
        notes.exportSelected(.pdf)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Hello.pdf").path))
        #expect(notes.notice == L("ask.notes.exported", "Hello.pdf"))
    }

    @Test func hidesTagsFromTheAgent() {
        let store = makeTestNotes()
        let notes = model(store)
        #expect(!notes.isHiddenFromAgent("x"))
        notes.toggleHiddenFromAgent("x")
        #expect(notes.agentHiddenTags.isEmpty, "without settings nothing is stored")
        let settings = settings()
        notes.agentSettings = settings
        #expect(notes.agentEnabled && notes.isHiddenFromAgent("PRIVATE"))
        notes.toggleHiddenFromAgent("work")
        #expect(settings.askNotebookHiddenTags.contains("work") && notes.isHiddenFromAgent("Work"))
        notes.toggleHiddenFromAgent("Work")
        #expect(!settings.askNotebookHiddenTags.contains("work"))
        notes.setAgentEnabled(false)
        #expect(!notes.agentEnabled && !settings.askNotebookAgentEnabled)
        notes.setAgentEnabled(true)
        #expect(notes.agentEnabled && settings.askNotebookAgentEnabled)
    }

    @Test func theWindowFollowsTheInterfaceStyleAndOpensNewNotes() throws {
        let store = makeTestNotes()
        let controller = AskNotesWindowController()
        let settings = settings()
        settings.interfaceStyle = .classic
        controller.configure(store: store, settings: settings, askAI: nil, openConversation: { _ in }, appearance: { nil })
        controller.showNewNote(title: "Fresh")
        #expect(controller.model?.selected?.title == "Fresh" && controller.model?.editing == true)
        #expect(controller.model?.agentSettings === settings)
        #expect(controller.window?.toolbar != nil && controller.window?.isVisible == true)
        controller.window?.close()
        #expect(controller.model == nil && store.count(.all) == 1)
    }

    @Test func filteringAndChangingShelvesFlushesTheDraftBeforeReplacingSelection() throws {
        let store = makeTestNotes()
        let first = makeTestNote("First", body: "old", tags: ["work"], at: 20)
        let second = makeTestNote("Second", body: "other", at: 10)
        [first, second].forEach { store.save($0) }
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "saved before search"
        notes.searchText = "Second"
        #expect(store.note(id: first.id)?.body == "saved before search")
        #expect(notes.selectedID == second.id && !notes.editing)
        notes.searchText = ""
        notes.select(first.id)
        notes.beginEditing()
        notes.draftBody = "saved before shelf"
        notes.scope = .tag("work")
        #expect(store.note(id: first.id)?.body == "saved before shelf" && !notes.hasUnsavedDraft)
        notes.beginEditing()
        notes.draftBody = "saved before selection"
        notes.scope = .all
        notes.select(second.id)
        #expect(store.note(id: first.id)?.body == "saved before selection")
        #expect(notes.selectedID == second.id && !notes.editing)
    }

    @Test func draftSavePreservesConcurrentMetadataAndRefusesConcurrentText() throws {
        let store = makeTestNotes()
        let original = makeTestNote("Original", body: "before")
        store.save(original)
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "my draft"
        var external = original
        external.tags = ["new"]
        external.pinned = true
        store.save(external)
        #expect(notes.saveDraft())
        let saved = try #require(store.note(id: original.id))
        #expect(saved.body == "my draft" && saved.tags == ["new"] && saved.pinned)

        notes.draftBody = "my next draft"
        external = saved
        external.body = "agent version"
        external.author = .agent
        store.save(external)
        notes.reload()
        #expect(!notes.finishEditing())
        #expect(notes.editing && notes.hasUnsavedDraft && notes.draftConflict)
        #expect(notes.draftBody == "my next draft" && store.note(id: original.id)?.body == "agent version")
        notes.searchText = "unmatched"
        #expect(notes.searchText.isEmpty && notes.selectedID == original.id)
        notes.scope = .trash
        #expect(notes.scope == .all && notes.hasUnsavedDraft)
        #expect(notes.createNote() == nil)
        notes.setSelecting(true)
        #expect(!notes.selecting)
        notes.saveDraftCopy()
        #expect(!notes.editing && !notes.hasUnsavedDraft && !notes.draftConflict)
        #expect(notes.selectedID != original.id && notes.selected?.body == "my next draft")
        #expect(store.note(id: original.id)?.body == "agent version" && store.count(.all) == 2)
    }

    @Test func externalDeletionKeepsTheDraftWithoutResurrectingTheNote() throws {
        let store = makeTestNotes()
        let note = makeTestNote("Original", body: "before", tags: ["work"])
        store.save(note)
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.scope = .tag("work")
        notes.beginEditing()
        notes.draftBody = "still recoverable"
        store.trash(ids: [note.id], at: Date())
        notes.reload()
        #expect(!notes.finishEditing() && notes.editing && notes.draftBody == "still recoverable")
        #expect(notes.selectedID == note.id && notes.selected != nil)
        notes.saveDraftCopy()
        #expect(notes.selected?.body == "still recoverable" && notes.selected?.source == .manual)
        #expect(store.note(id: note.id)?.isDeleted == true)
    }

    @Test func anIdleEditorFollowsExternalChangesWithoutWritingThemBack() {
        let store = makeTestNotes()
        var note = makeTestNote("Original", body: "before")
        store.save(note)
        let notes = model(store)
        notes.beginEditing()
        note.body = "changed outside"
        store.save(note)
        notes.reload()
        #expect(notes.draftBody == "changed outside" && !notes.hasUnsavedDraft)
        #expect(notes.finishEditing() && store.note(id: note.id) == note)
    }

    @Test func failedWritesKeepTheDraftAndPreventWindowClosure() throws {
        let store = FailingNotebookStore()
        let note = makeTestNote("Original", body: "before")
        store.save(note)
        let controller = AskNotesWindowController()
        controller.configure(store: store, askAI: nil, appearance: { nil })
        controller.show()
        let notes = try #require(controller.model)
        let window = try #require(controller.window)
        defer { store.rejectWrites = false; window.close() }
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "must survive"
        store.rejectWrites = true
        #expect(!notes.saveDraft() && notes.hasUnsavedDraft)
        #expect(!controller.windowShouldClose(window))
        #expect(notes.editing && store.note(id: note.id)?.body == "before")
        notes.select(UUID())
        notes.deleteSelected()
        #expect(notes.selectedID == note.id && store.note(id: note.id)?.isDeleted == false)
        #expect(notes.notice == L("ask.notes.saveFailed"))
        store.rejectWrites = false
        #expect(controller.windowShouldClose(window))
        #expect(store.note(id: note.id)?.body == "must survive" && !notes.editing)
    }

    @Test func deleteUndoKeepsTheLatestDraftAndLaterChanges() throws {
        let store = makeTestNotes()
        let original = makeTestNote("Original", body: "before")
        store.save(original)
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "latest draft"
        notes.deleteSelected()
        #expect(store.note(id: original.id)?.body == "latest draft")
        var removed = try #require(store.note(id: original.id))
        removed.tags = ["later metadata"]
        store.save(removed)
        notes.undoDelete()
        #expect(store.note(id: original.id)?.body == "latest draft")
        #expect(store.note(id: original.id)?.tags == ["later metadata"])
        notes.deleteSelected()
        store.delete(ids: [original.id])
        notes.undoDelete()
        #expect(store.note(id: original.id) == nil, "undo must not resurrect a permanently deleted note")
    }

    @Test func shareAndExportUseTheCurrentDraftBeforeAutosave() throws {
        let store = makeTestNotes()
        store.save(makeTestNote("Title", body: "stored"))
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "fresh draft"
        var copied = "", rich = "", asked = "", opened = ""
        notes.copy = { copied = $0 }
        notes.copyRich = { rich = $0 }
        notes.askAI = { asked = $0 }
        notes.openInWindow = { opened = $0.body }
        notes.copySelected()
        notes.copySelectedRich()
        notes.askAIAboutSelected()
        notes.openSelectedInWindow()
        #expect(copied == "fresh draft" && rich == copied && opened == copied && asked.contains(copied))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        notes.chooseExportURL = { _ in url }
        notes.exportSelected()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fresh draft"))
    }

    @Test func titleCommitTargetsItsOriginalNoteAndTaskEditsRemainUserEdits() throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", body: "- [ ] task", at: 20)
        let b = makeTestNote("B", at: 10)
        [a, b].forEach { store.save($0) }
        let notes = model(store)
        notes.select(b.id)
        notes.rename("A edited", id: a.id)
        #expect(store.note(id: a.id)?.title == "A edited" && store.note(id: b.id)?.title == "B")
        notes.select(a.id)
        notes.toggleTask(0)
        let edited = try #require(store.note(id: a.id))
        #expect(edited.body == "- [x] task" && edited.originalBody == a.body && edited.isEdited && edited.author == .user)
        notes.scope = .trash
        store.trash(ids: [a.id], at: Date())
        notes.reload()
        notes.select(a.id)
        notes.toggleTask(0)
        #expect(store.note(id: a.id)?.body == "- [x] task", "Recently Deleted is read-only")
    }

    @Test func agentTextUndoPreservesLaterMetadataAndIgnoresNoOpRevisions() throws {
        let store = makeTestNotes()
        var note = makeTestNote("Title", body: "before")
        store.save(note)
        store.saveRevision(note, at: Date(timeIntervalSince1970: 1))
        note.body = "after"
        note.author = .agent
        note.tags = ["keep"]
        note.pinned = true
        store.save(note)
        let notes = model(store)
        notes.revertAgentChange()
        #expect(store.note(id: note.id)?.body == "before")
        #expect(store.note(id: note.id)?.tags == ["keep"] && store.note(id: note.id)?.pinned == true)
        note = try #require(store.note(id: note.id))
        note.author = .agent
        store.save(note)
        store.saveRevision(note, at: Date(timeIntervalSince1970: 2))
        notes.reload()
        #expect(notes.agentRevision == nil, "identical text must not offer an agent undo")
    }


    @Test func failedTitleWritesBlockNavigationAndWindowClosureUntilRecovered() throws {
        let store = FailingNotebookStore()
        let first = makeTestNote("First", at: 20), second = makeTestNote("Second", at: 10)
        [first, second].forEach { store.save($0) }
        let controller = AskNotesWindowController()
        controller.configure(store: store, askAI: nil, appearance: { nil })
        controller.show(selecting: first.id)
        let notes = try #require(controller.model)
        let window = try #require(controller.window)
        defer { store.rejectWrites = false; window.close() }
        notes.autosaveDelay = .seconds(60)
        notes.stageTitle("My unsaved title", id: first.id)
        store.rejectWrites = true
        #expect(!notes.savePendingTitle())
        #expect(notes.pendingTitle == "My unsaved title" && store.note(id: first.id)?.title == "First")
        notes.select(second.id)
        notes.searchText = "Second"
        #expect(notes.selectedID == first.id && notes.searchText.isEmpty)
        #expect(!controller.windowShouldClose(window))
        #expect(notes.notice == L("ask.notes.saveFailed"))
        store.rejectWrites = false
        notes.select(second.id)
        #expect(notes.selectedID == second.id && notes.pendingTitle == nil)
        #expect(store.note(id: first.id)?.title == "My unsaved title")
    }

    @Test func aConcurrentTitleChangeCanBeRecoveredAsACopy() throws {
        let store = makeTestNotes()
        var original = makeTestNote("First", body: "unchanged body")
        store.save(original)
        let notes = model(store)
        notes.autosaveDelay = .seconds(60)
        notes.stageTitle("User title", id: original.id)
        original.title = "Agent title"
        original.author = .agent
        store.save(original)
        notes.reload()
        #expect(!notes.finishEditing() && notes.pendingTitle == "User title" && notes.draftConflict)
        notes.saveDraftCopy()
        #expect(notes.selected?.title == "User title" && notes.selected?.body == "unchanged body")
        #expect(store.note(id: original.id)?.title == "Agent title" && notes.pendingTitle == nil)
    }

    @Test func titleAutosaveAlsoWorksOutsideBodyEditing() async throws {
        let store = makeTestNotes()
        let note = makeTestNote("First", body: "body")
        store.save(note)
        let notes = model(store)
        notes.stageTitle("New title", id: note.id)
        for _ in 0 ..< 200 where notes.pendingTitle != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(notes.pendingTitle == nil && store.note(id: note.id)?.title == "New title")
        #expect(!notes.editing && store.note(id: note.id)?.body == "body")
        notes.stageTitle("Temporary", id: note.id)
        notes.stageTitle("New title", id: note.id)
        #expect(notes.pendingTitle == nil, "returning to the saved title clears the pending change")
    }

}


/// Injects disk-write failures while preserving readable data for recovery tests.
private final class FailingNotebookStore: AskNoteStoring, @unchecked Sendable {
    let base = makeTestNotes()
    var rejectWrites = false
    func note(id: UUID) -> AskNote? { base.note(id: id) }
    @discardableResult func save(_ note: AskNote) -> Bool { !rejectWrites && base.save(note) }
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) -> Bool {
        !rejectWrites && base.save(note, replacing: previous, revisionAt: date)
    }
    func delete(ids: [UUID]) { if !rejectWrites { base.delete(ids: ids) } }
    func restore(_ notes: [AskNote]) { if !rejectWrites { base.restore(notes) } }
    func list(_ query: AskNoteQuery) -> [AskNote] { base.list(query) }
    func count(_ scope: AskNoteQuery.Scope) -> Int { base.count(scope) }
    func commands() -> [AskNoteFacet] { base.commands() }
    func sources() -> [AskNoteFacet] { base.sources() }
    func tags() -> [AskNoteFacet] { base.tags() }
    func trash(ids: [UUID], at date: Date) { if !rejectWrites { base.trash(ids: ids, at: date) } }
    func purgeTrash(before date: Date) { base.purgeTrash(before: date) }
    func saveRevision(_ note: AskNote, at date: Date) { base.saveRevision(note, at: date) }
    func revisions(of id: UUID) -> [AskNoteRevision] { base.revisions(of: id) }
    func deleteRevision(of id: UUID, at date: Date) { base.deleteRevision(of: id, at: date) }
}
