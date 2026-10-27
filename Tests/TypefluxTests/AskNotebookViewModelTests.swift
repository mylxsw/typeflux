import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Notebook window model", .exclusiveUIState)
@MainActor
struct AskNotebookViewModelTests {
    private func model(_ store: SQLiteAskNoteStore, at seconds: TimeInterval = 5000) async -> AskNotesViewModel {
        let model = AskNotesViewModel(store: store, notificationCenter: NotificationCenter())
        await model.waitForReload()
        model.clock = { Date(timeIntervalSince1970: seconds) }
        model.autosaveDelay = .milliseconds(10)
        await model.waitForReload()
        return model
    }

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "notebook-vm-\(UUID().uuidString)")!)
    }

    @Test func createsNotesAndSavesEditsWhileTyping() async throws {
        let store = makeTestNotes()
        try store.save(makeTestNote("Tagged", tags: ["work"]))
        let notes = await model(store)
        notes.scope = .tag("work")
        await notes.waitForNavigation()
        let id = try #require(await notes.createNote())
        #expect(notes.selectedID == id && notes.mode == .edit && notes.scope == .tag("work"))
        #expect(try store.note(id: id)?.tags == ["work"] && store.note(id: id)?.source == .manual)
        notes.draftBody = "# Plan\n\n- [ ] one"
        #expect(notes.hasUnsavedDraft)
        for _ in 0 ..< 200 where notes.hasUnsavedDraft { try await Task.sleep(for: .milliseconds(5)) }
        let saved = try #require(try store.note(id: id))
        #expect(saved.body == "# Plan\n\n- [ ] one" && saved.title == "Plan" && saved.originalBody == nil)
        await notes.setMode(.split)
        #expect(notes.mode == .split && notes.editing)
        await notes.toggleEditing()
        #expect(notes.mode == .read)
        await notes.toggleTask(0)
        #expect(try store.note(id: id)?.body == "# Plan\n\n- [x] one")
        await notes.toggleTask(9)
        await notes.rename("")
        #expect(try store.note(id: id)?.title == "Plan", "a written note falls back to its first heading")
        notes.scope = .pinned
        await notes.waitForNavigation()
        let other = try #require(await notes.createNote(title: "  From search "))
        #expect(try notes.scope == .all && store.note(id: other)?.title == "From search")
        notes.draftBody = ""
        await notes.rename("")
        #expect(try store.note(id: other)?.title == L("ask.notes.untitled"))
    }

    @Test func preservesUserEditsAndRevertsTheAgentsRevision() async throws {
        let store = makeTestNotes()
        var note = makeTestNote("AI", body: "generated")
        note.source = .chat
        note.conversationID = "conv"
        try store.save(note)
        let notes = await model(store)
        var opened: [String] = []
        #expect(!notes.canOpenSource)
        notes.openConversation = { opened.append($0) }
        #expect(notes.canOpenSource)
        notes.openSource()
        #expect(opened == ["conv"])
        notes.beginEditing()
        notes.draftBody = "mine"
        await notes.setMode(.read)
        #expect(try store.note(id: note.id)?.originalBody == "generated")
        #expect(try store.note(id: note.id)?.body == "mine" && store.note(id: note.id)?.editedAt != nil)
        #expect(notes.notice == nil)

        #expect(notes.agentRevision == nil)
        let tool = AskNotebookTool(store: store, clock: { Date(timeIntervalSince1970: 6000) })
        _ = try await tool.execute(["action": "append", "id": note.id.uuidString, "body": "agent text"])
        await notes.reload().value
        #expect(notes.selected?.author == .agent && notes.agentRevision?.body == "mine")
        await notes.revertAgentChange()
        #expect(try store.note(id: note.id)?.body == "mine" && store.note(id: note.id)?.author == .user)
        #expect(try notes.notice == L("ask.notes.agentReverted") && store.revisions(of: note.id).isEmpty)
    }

    @Test func groupsSearchesAndFiltersByTag() async throws {
        let store = makeTestNotes()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12))!
        try store.save(makeTestNote("Pinned", pinned: true, at: now.timeIntervalSince1970 - 10 * 86400))
        try store.save(makeTestNote("Today", body: "apple", tags: ["fruit"], at: now.timeIntervalSince1970 - 60))
        try store.save(makeTestNote("Yesterday", body: "apple pie", at: now.timeIntervalSince1970 - 86400))
        try store.save(makeTestNote("Week", at: now.timeIntervalSince1970 - 3 * 86400))
        try store.save(makeTestNote("Old", at: now.timeIntervalSince1970 - 9 * 86400))
        let notes = await model(store, at: now.timeIntervalSince1970)
        let sections = AskNotesViewModel.sections(notes.notes, sort: .updated, trash: false, now: now)
        #expect(sections.map(\.title) == [L("ask.notes.group.pinned"), L("ask.notes.group.today"),
                                          L("ask.notes.group.yesterday"), L("ask.notes.group.week"),
                                          L("ask.notes.group.earlier")])
        #expect(AskNotesViewModel.sections(notes.notes, sort: .title, trash: false, now: now).count == 1)
        #expect(AskNotesViewModel.sections([], sort: .title, trash: false, now: now).isEmpty)
        #expect(notes.sections.count == 5)
        #expect(AskNotesViewModel.parseSearch("apple #Fruit  #") == ("apple", ["Fruit"]))
        notes.searchText = "apple"
        await notes.waitForNavigation()
        #expect(notes.notes.map(\.title) == ["Today", "Yesterday"])
        notes.searchText = "apple #fruit"
        await notes.waitForNavigation()
        #expect(notes.notes.map(\.title) == ["Today"])
        #expect(notes.title(of: .recent) == L("ask.notes.shelf.recent") && notes.title(of: .trash) == L("ask.notes.shelf.trash"))
        #expect(notes.title(of: .source(.chat)) == AskNoteSource.chat.title)
        #expect(notes.counts[.recent] != nil && notes.sources[.command] == 5)
        notes.scope = .source(.chat)
        await notes.waitForNavigation()
        #expect(notes.scope == .all, "an empty source shelf falls back to all notes")
    }

    @Test func expandingSearchScopeKeepsTheQuery() async throws {
        let store = makeTestNotes()
        try store.save(makeTestNote("Work match", body: "needle", tags: ["work"]))
        try store.save(makeTestNote("Other match", body: "needle", tags: ["personal"]))
        let notes = await model(store)
        notes.scope = .tag("work")
        await notes.waitForNavigation()
        notes.searchText = "needle"
        await notes.waitForNavigation()
        #expect(notes.notes.map(\.title) == ["Work match"])
        notes.scope = .all
        await notes.waitForNavigation()
        #expect(notes.searchText == "needle")
        #expect(Set(notes.notes.map(\.title)) == ["Work match", "Other match"])
    }

    @Test func picksSeveralNotesForOneAction() async throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", body: "1", at: 30), b = makeTestNote("B", body: "2", at: 20), c = makeTestNote("C", body: "3", at: 10)
        try [a, b, c].forEach { try store.save($0) }
        let notes = await model(store)
        var copied: [String] = []
        notes.copy = { copied.append($0) }
        await notes.togglePick(b.id)
        #expect(notes.selecting && notes.picked == [a.id, b.id], "picking starts from the chosen note")
        await notes.togglePick(a.id)
        await notes.pickRange(to: c.id)
        #expect(notes.picked == [a.id, b.id, c.id], "⇧ click picks from the last clicked note")
        await notes.pickAll()
        #expect(notes.pickedNotes.map(\.title) == ["A", "B", "C"])
        await notes.pinPicked()
        #expect(try store.count(.pinned) == 3)
        await notes.pinPicked()
        #expect(try store.count(.pinned) == 0)
        await notes.tagPicked("#batch")
        await notes.tagPicked(" ")
        #expect(try store.tags().first?.name == "batch" && store.tags().first?.count == 3)
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
        await notes.exportAll()
        await notes.setSelecting(false)
        await notes.togglePick(b.id)
        await notes.trashPicked()
        #expect(try store.count(.all) == 1 && !notes.selecting && notes.noticeOffersUndo)
        await notes.undoDelete()
        #expect(try store.count(.all) == 3 && store.count(.trash) == 0, "one undo puts back the whole batch")
        await notes.trashPicked()
    }

    @Test func recentlyDeletedRestoresAndDeletesForGood() async throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", at: 20), b = makeTestNote("B", at: 10)
        try store.save(a)
        try store.save(b)
        let notes = await model(store)
        await notes.deleteSelected()
        await notes.select(b.id)
        await notes.deleteSelected()
        #expect(try store.count(.trash) == 2 && notes.notes.isEmpty)
        notes.scope = .trash
        await notes.waitForNavigation()
        #expect(notes.inTrash && notes.notes.count == 2)
        await notes.setSelecting(true)
        await notes.pickAll()
        #expect(!notes.selecting, "nothing is picked in Recently Deleted")
        notes.beginEditing()
        #expect(!notes.editing, "deleted notes are read-only")
        let first = try #require(notes.selectedID)
        await notes.restoreFromTrash()
        #expect(try store.note(id: first)?.isDeleted == false && notes.notes.count == 1)
        await notes.deleteSelected()
        #expect(try store.count(.trash) == 0, "in Recently Deleted, delete removes for good")
        await notes.reveal(first)
        #expect(notes.scope == .all && notes.selectedID == first)
        await notes.deleteSelected()
        notes.scope = .trash
        await notes.waitForNavigation()
        await notes.emptyTrash()
        #expect(try store.count(.trash) == 0 && notes.notes.isEmpty)
        await notes.restoreFromTrash()
        await notes.deleteForever()
    }

    @Test func importsAndExportsFormats() async throws {
        let store = makeTestNotes()
        let notes = await model(store)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Imported.md")
        try "# Hello\nworld".write(to: file, atomically: true, encoding: .utf8)
        notes.chooseImportFiles = { [file, folder.appendingPathComponent("x.png")] }
        notes.scope = .pinned
        await notes.waitForNavigation()
        await notes.importFiles()
        #expect(notes.scope == .all && notes.selected?.title == "Hello" && notes.selected?.source == .import)
        #expect(notes.notice == L("ask.notes.importedSkipped", 1, 1))
        await notes.importFiles([])
        notes.chooseExportURL = { folder.appendingPathComponent($0) }
        notes.exportSelected(.html)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Hello.html").path))
        notes.exportSelected(.pdf)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Hello.pdf").path))
        #expect(notes.notice == L("ask.notes.exported", "Hello.pdf"))
    }

    @Test func hidesTagsFromTheAgent() async throws {
        let store = makeTestNotes()
        let notes = await model(store)
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

    @Test func theWindowFollowsTheInterfaceStyleAndOpensNewNotes() async throws {
        let store = makeTestNotes()
        let controller = AskNotesWindowController()
        let settings = settings()
        settings.interfaceStyle = .classic
        controller.configure(store: store, settings: settings, askAI: nil, openConversation: { _ in }, appearance: { nil })
        controller.showNewNote(title: "Fresh")
        await controller.model?.waitForActions()
        #expect(controller.model?.selected?.title == "Fresh" && controller.model?.editing == true)
        #expect(controller.model?.agentSettings === settings)
        #expect(controller.window?.toolbar != nil && controller.window?.isVisible == true)
        controller.window?.close()
        #expect(try controller.model == nil && store.count(.all) == 1)
    }

    @Test func filteringAndChangingShelvesFlushesTheDraftBeforeReplacingSelection() async throws {
        let store = makeTestNotes()
        let first = makeTestNote("First", body: "old", tags: ["work"], at: 20)
        let second = makeTestNote("Second", body: "other", at: 10)
        try [first, second].forEach { try store.save($0) }
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "saved before search"
        notes.searchText = "Second"
        await notes.waitForNavigation()
        #expect(try store.note(id: first.id)?.body == "saved before search")
        #expect(notes.selectedID == second.id && !notes.editing)
        notes.searchText = ""
        await notes.waitForNavigation()
        await notes.select(first.id)
        notes.beginEditing()
        notes.draftBody = "saved before shelf"
        notes.scope = .tag("work")
        await notes.waitForNavigation()
        #expect(try store.note(id: first.id)?.body == "saved before shelf" && !notes.hasUnsavedDraft)
        notes.beginEditing()
        notes.draftBody = "saved before selection"
        notes.scope = .all
        await notes.waitForNavigation()
        await notes.select(second.id)
        #expect(try store.note(id: first.id)?.body == "saved before selection")
        #expect(notes.selectedID == second.id && !notes.editing)
    }

    @Test func draftSavePreservesConcurrentMetadataAndRefusesConcurrentText() async throws {
        let store = makeTestNotes()
        let original = makeTestNote("Original", body: "before")
        try store.save(original)
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "my draft"
        var external = original
        external.tags = ["new"]
        external.pinned = true
        try store.save(external)
        #expect(await notes.saveDraft())
        let saved = try #require(try store.note(id: original.id))
        #expect(saved.body == "my draft" && saved.tags == ["new"] && saved.pinned)

        notes.draftBody = "my next draft"
        external = saved
        external.body = "agent version"
        external.author = .agent
        try store.save(external)
        await notes.reload().value
        #expect(!(await notes.finishEditing()))
        #expect(notes.editing && notes.hasUnsavedDraft && notes.draftConflict)
        #expect(try notes.draftBody == "my next draft" && store.note(id: original.id)?.body == "agent version")
        notes.searchText = "unmatched"
        await notes.waitForNavigation()
        #expect(notes.searchText.isEmpty && notes.selectedID == original.id)
        notes.scope = .trash
        await notes.waitForNavigation()
        #expect(notes.scope == .all && notes.hasUnsavedDraft)
        #expect(await notes.createNote() == nil)
        await notes.setSelecting(true)
        #expect(!notes.selecting)
        await notes.saveDraftCopy()
        #expect(!notes.editing && !notes.hasUnsavedDraft && !notes.draftConflict)
        #expect(notes.selectedID != original.id && notes.selected?.body == "my next draft")
        #expect(try store.note(id: original.id)?.body == "agent version" && store.count(.all) == 2)
    }

    @Test func externalDeletionKeepsTheDraftWithoutResurrectingTheNote() async throws {
        let store = makeTestNotes()
        let note = makeTestNote("Original", body: "before", tags: ["work"])
        try store.save(note)
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.scope = .tag("work")
        await notes.waitForNavigation()
        notes.beginEditing()
        notes.draftBody = "still recoverable"
        try store.trash(ids: [note.id], at: Date())
        await notes.reload().value
        #expect(!(await notes.finishEditing()) && notes.editing && notes.draftBody == "still recoverable")
        #expect(notes.selectedID == note.id && notes.selected != nil)
        await notes.saveDraftCopy()
        #expect(notes.selected?.body == "still recoverable" && notes.selected?.source == .manual)
        #expect(try store.note(id: note.id)?.isDeleted == true)
    }

    @Test func anIdleEditorFollowsExternalChangesWithoutWritingThemBack() async throws {
        let store = makeTestNotes()
        var note = makeTestNote("Original", body: "before")
        try store.save(note)
        let notes = await model(store)
        notes.beginEditing()
        note.body = "changed outside"
        try store.save(note)
        await notes.reload().value
        #expect(notes.draftBody == "changed outside" && !notes.hasUnsavedDraft)
        #expect(try await notes.finishEditing() && store.note(id: note.id) == note)
    }

    @Test func failedWritesKeepTheDraftAndPreventWindowClosure() async throws {
        let store = FailingNotebookStore()
        let note = makeTestNote("Original", body: "before")
        try store.save(note)
        let controller = AskNotesWindowController()
        controller.configure(store: store, askAI: nil, appearance: { nil })
        controller.show()
        await controller.model?.waitForActions()
        let notes = try #require(controller.model)
        let window = try #require(controller.window)
        defer { store.rejectWrites = false; window.close() }
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "must survive"
        store.rejectWrites = true
        #expect(!(await notes.saveDraft()) && notes.hasUnsavedDraft)
        #expect(!controller.windowShouldClose(window))
        await notes.waitForActions()
        #expect(try notes.editing && store.note(id: note.id)?.body == "before")
        await notes.select(UUID())
        await notes.deleteSelected()
        #expect(try notes.selectedID == note.id && store.note(id: note.id)?.isDeleted == false)
        #expect(notes.notice == L("ask.notes.saveFailed"))
        store.rejectWrites = false
        #expect(!controller.windowShouldClose(window))
        await notes.waitForActions()
        #expect(controller.window == nil)
        #expect(try store.note(id: note.id)?.body == "must survive" && !notes.editing)
    }

    @Test func deleteUndoKeepsTheLatestDraftAndLaterChanges() async throws {
        let store = makeTestNotes()
        let original = makeTestNote("Original", body: "before")
        try store.save(original)
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "latest draft"
        await notes.deleteSelected()
        #expect(try store.note(id: original.id)?.body == "latest draft")
        var removed = try #require(try store.note(id: original.id))
        removed.tags = ["later metadata"]
        try store.save(removed)
        await notes.undoDelete()
        #expect(try store.note(id: original.id)?.body == "latest draft")
        #expect(try store.note(id: original.id)?.tags == ["later metadata"])
        await notes.deleteSelected()
        try store.delete(ids: [original.id])
        await notes.undoDelete()
        #expect(try store.note(id: original.id) == nil, "undo must not resurrect a permanently deleted note")
    }

    @Test func shareAndExportUseTheCurrentDraftBeforeAutosave() async throws {
        let store = makeTestNotes()
        try store.save(makeTestNote("Title", body: "stored"))
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.beginEditing()
        notes.draftBody = "fresh draft"
        var copied = "", rich = "", asked: AskNote?, opened = ""
        notes.copy = { copied = $0 }
        notes.copyRich = { rich = $0 }
        notes.askAI = { asked = $0 }
        notes.openInWindow = { opened = $0.body }
        notes.copySelected()
        notes.copySelectedRich()
        notes.askAIAboutSelected()
        notes.openSelectedInWindow()
        #expect(copied == "fresh draft" && rich == copied && opened == copied && asked?.body == copied)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        notes.chooseExportURL = { _ in url }
        notes.exportSelected()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fresh draft"))
    }

    @Test func titleCommitTargetsItsOriginalNoteAndTaskEditsRemainUserEdits() async throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", body: "- [ ] task", at: 20)
        let b = makeTestNote("B", at: 10)
        try [a, b].forEach { try store.save($0) }
        let notes = await model(store)
        await notes.select(b.id)
        await notes.rename("A edited", id: a.id)
        #expect(try store.note(id: a.id)?.title == "A edited" && store.note(id: b.id)?.title == "B")
        await notes.select(a.id)
        await notes.toggleTask(0)
        let edited = try #require(try store.note(id: a.id))
        #expect(edited.body == "- [x] task" && edited.originalBody == a.body && edited.isEdited && edited.author == .user)
        notes.scope = .trash
        await notes.waitForNavigation()
        try store.trash(ids: [a.id], at: Date())
        await notes.reload().value
        await notes.select(a.id)
        await notes.toggleTask(0)
        #expect(try store.note(id: a.id)?.body == "- [x] task", "Recently Deleted is read-only")
    }

    @Test func agentTextUndoPreservesLaterMetadataAndIgnoresNoOpRevisions() async throws {
        let store = makeTestNotes()
        var note = makeTestNote("Title", body: "before")
        try store.save(note)
        try store.saveRevision(note, at: Date(timeIntervalSince1970: 1))
        note.body = "after"
        note.author = .agent
        note.tags = ["keep"]
        note.pinned = true
        try store.save(note)
        let notes = await model(store)
        await notes.revertAgentChange()
        #expect(try store.note(id: note.id)?.body == "before")
        #expect(try store.note(id: note.id)?.tags == ["keep"] && store.note(id: note.id)?.pinned == true)
        note = try #require(try store.note(id: note.id))
        note.author = .agent
        try store.save(note)
        try store.saveRevision(note, at: Date(timeIntervalSince1970: 2))
        await notes.reload().value
        #expect(notes.agentRevision == nil, "identical text must not offer an agent undo")
    }


    @Test func failedTitleWritesBlockNavigationAndWindowClosureUntilRecovered() async throws {
        let store = FailingNotebookStore()
        let first = makeTestNote("First", at: 20), second = makeTestNote("Second", at: 10)
        try [first, second].forEach { try store.save($0) }
        let controller = AskNotesWindowController()
        controller.configure(store: store, askAI: nil, appearance: { nil })
        controller.show(selecting: first.id)
        await controller.model?.waitForActions()
        let notes = try #require(controller.model)
        let window = try #require(controller.window)
        defer { store.rejectWrites = false; window.close() }
        notes.autosaveDelay = .seconds(60)
        notes.stageTitle("My unsaved title", id: first.id)
        store.rejectWrites = true
        #expect(!(await notes.savePendingTitle()))
        #expect(try notes.pendingTitle == "My unsaved title" && store.note(id: first.id)?.title == "First")
        await notes.select(second.id)
        notes.searchText = "Second"
        await notes.waitForNavigation()
        #expect(notes.selectedID == first.id && notes.searchText.isEmpty)
        #expect(!controller.windowShouldClose(window))
        await notes.waitForActions()
        #expect(notes.notice == L("ask.notes.saveFailed"))
        store.rejectWrites = false
        await notes.select(second.id)
        #expect(notes.selectedID == second.id && notes.pendingTitle == nil)
        #expect(try store.note(id: first.id)?.title == "My unsaved title")
    }

    @Test func aConcurrentTitleChangeCanBeRecoveredAsACopy() async throws {
        let store = makeTestNotes()
        var original = makeTestNote("First", body: "unchanged body")
        try store.save(original)
        let notes = await model(store)
        notes.autosaveDelay = .seconds(60)
        notes.stageTitle("User title", id: original.id)
        original.title = "Agent title"
        original.author = .agent
        try store.save(original)
        await notes.reload().value
        #expect(!(await notes.finishEditing()) && notes.pendingTitle == "User title" && notes.draftConflict)
        await notes.saveDraftCopy()
        #expect(notes.selected?.title == "User title" && notes.selected?.body == "unchanged body")
        #expect(try store.note(id: original.id)?.title == "Agent title" && notes.pendingTitle == nil)
    }

    @Test func titleAutosaveAlsoWorksOutsideBodyEditing() async throws {
        let store = makeTestNotes()
        let note = makeTestNote("First", body: "body")
        try store.save(note)
        let notes = await model(store)
        notes.stageTitle("New title", id: note.id)
        for _ in 0 ..< 200 where notes.pendingTitle != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try notes.pendingTitle == nil && store.note(id: note.id)?.title == "New title")
        #expect(try !notes.editing && store.note(id: note.id)?.body == "body")
        notes.stageTitle("Temporary", id: note.id)
        notes.stageTitle("New title", id: note.id)
        #expect(notes.pendingTitle == nil, "returning to the saved title clears the pending change")
    }

}


/// Injects disk-write failures while preserving readable data for recovery tests.
private final class FailingNotebookStore: AskNoteStoring, @unchecked Sendable {
    let base = makeTestNotes()
    var rejectWrites = false
    func note(id: UUID) throws -> AskNote? { try base.note(id: id) }
    @discardableResult func save(_ note: AskNote) throws -> Bool { try !rejectWrites && base.save(note) }
    func save(_ note: AskNote, replacing previous: AskNote, revisionAt date: Date?) throws -> Bool {
        try !rejectWrites && base.save(note, replacing: previous, revisionAt: date)
    }
    func delete(ids: [UUID]) throws { if !rejectWrites { try base.delete(ids: ids) } }
    func restore(_ notes: [AskNote]) throws { if !rejectWrites { try base.restore(notes) } }
    func list(_ query: AskNoteQuery) throws -> [AskNote] { try base.list(query) }
    func count(_ scope: AskNoteQuery.Scope) throws -> Int { try base.count(scope) }
    func commands() throws -> [AskNoteFacet] { try base.commands() }
    func sources() throws -> [AskNoteFacet] { try base.sources() }
    func tags() throws -> [AskNoteFacet] { try base.tags() }
    func trash(ids: [UUID], at date: Date) throws { if !rejectWrites { try base.trash(ids: ids, at: date) } }
    func purgeTrash(before date: Date) throws { try base.purgeTrash(before: date) }
    func saveRevision(_ note: AskNote, at date: Date) throws { try base.saveRevision(note, at: date) }
    func revisions(of id: UUID) throws -> [AskNoteRevision] { try base.revisions(of: id) }
    func deleteRevision(of id: UUID, at date: Date) throws { try base.deleteRevision(of: id, at: date) }
}
