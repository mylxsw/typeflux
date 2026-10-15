import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("AI prompt results: Markdown, windows and notes", .exclusiveUIState)
@MainActor
struct AskPromptResultFlowTests {
    private func request(_ text: String = "teh text", origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskPromptPlugin.keywords[2],
                         options: AskPromptPlugin.keywords[2].options, interfaceLanguage: .english)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func resultsAreMarkdownWithWindowAndNoteActions() async throws {
        let generator = AskTestTextGenerator()
        generator.pieces = ["**Bold**"]
        let plain = AskPromptPlugin(generator: generator, modelName: { "gpt-test" })
        let output = try await plain.run(request(), plan: await plain.plan(request()))
        #expect(output.markdown, "AI prompt results are drawn as Markdown")
        #expect(output.action(for: .shiftCommandC)?.kind == .copyRich("**Bold**"))
        #expect(output.action(for: .commandO)?.kind == .openInWindow)
        #expect(output.action(for: .commandS) == nil && output.starred == nil, "no notes, no star")
        let saving = AskPromptPlugin(generator: generator, modelName: { "gpt-test" }, savesNotes: true)
        let saved = try await saving.run(request(), plan: await saving.plan(request()))
        let draft = try #require(saved.noteDraft)
        #expect(draft == AskNoteDraft(command: L("ask.plugin.prompt.preset.explain"), keyword: "ex", input: "teh text",
                                      body: "**Bold**", model: "gpt-test"))
        #expect(saved.starred == false && saved.action(for: .commandS)?.title == L("ask.notes.save"))
        #expect(saved.action(for: .commandB)?.kind == .openNotes(id: nil))
        let starred = saved.noteSaving(true)
        #expect(starred.starred == true && starred.action(for: .commandS)?.title == L("ask.notes.unsave"))
        #expect(starred.action(for: .commandS)?.symbol == "star.fill")
        let unnamed = AskPromptPlugin(generator: generator, savesNotes: true)
        #expect(try await unnamed.run(request(), plan: await unnamed.plan(request())).noteDraft?.model == nil)
        #expect(AskPluginOutput(body: "", original: "", meta: [], source: "", actions: []).noteDraft == nil)
    }

    @Test func aRunningResultHandsOffWithoutBeingCancelled() async throws {
        let generator = AskTestTextGenerator()
        generator.pieces = ["One", " two", " three"]
        generator.delay = .milliseconds(300)
        let plugin = AskPromptPlugin(generator: generator, modelName: { "m" })
        let session = AskPluginSession(plugins: [plugin]) { AskPromptPlugin.keywords }
        #expect(session.handOff { _ in } == nil, "nothing to hand over outside keyword mode")
        session.enter(AskPromptPlugin.keywords[0])
        session.update(text: "text", selection: nil, language: .english)
        try await settle { if case .ready = session.phase { true } else { false } }
        #expect(session.handOff { _ in } == nil, "nothing ran yet")
        session.run()
        try await settle { session.partial?.body == "One" }
        #expect(session.currentOutput?.body == "One")
        var events: [String] = []
        let handoff = try #require(session.handOff { event in
            switch event {
            case let .progress(output): events.append("p:" + output.body)
            case let .done(output): events.append("d:" + output.body)
            case let .failed(failure): events.append("f:" + failure.message)
            case .cancelled: events.append("c")
            }
        })
        #expect(handoff.running && handoff.output?.body == "One")
        session.deactivate()
        try await settle { events.last == "d:One two three" }
        #expect(events.contains("p:One two"), "progress keeps arriving after the launcher closed")
        #expect(session.output == nil, "the launcher no longer shows it")
        // A finished result hands over as it is.
        session.enter(AskPromptPlugin.keywords[0])
        session.update(text: "again", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { session.output != nil }
        let finished = try #require(session.handOff { _ in Issue.record("a finished run sends nothing") })
        #expect(!finished.running && finished.output?.body == "One two three")
        finished.cancel()
    }

    @Test func aHandedOffRunCanBeCancelledOrFail() async throws {
        let generator = AskTestTextGenerator()
        generator.pieces = ["a", "b", "c", "d"]
        generator.delay = .milliseconds(200)
        let plugin = AskPromptPlugin(generator: generator, modelName: { "m" })
        let session = AskPluginSession(plugins: [plugin]) { AskPromptPlugin.keywords }
        session.enter(AskPromptPlugin.keywords[0])
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { session.partial != nil }
        var last = ""
        let handoff = try #require(session.handOff { event in
            if case .cancelled = event { last = "cancelled" }
        })
        handoff.cancel()
        try await settle { last == "cancelled" }
        generator.pieces = ["x", "y"]
        generator.failure = AskPluginFailure(message: "bad")
        session.update(text: "y", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { session.partial != nil }
        var failed: String?
        _ = session.handOff { event in if case let .failed(failure) = event { failed = failure.message } }
        try await settle { failed == "bad" }
        // A live plugin may still be waiting out its debounce: there is nothing to hand over yet.
        let live = AskPluginSession(plugins: [AskNotesPlugin(store: makeTestNotes())]) { AskNotesPlugin.keywords }
        live.enter(AskNotesPlugin.keywords[0])
        live.update(text: "x", selection: nil, language: .english)
        try await settle { live.isRunning }
        #expect(live.handOff { _ in } == nil)
    }

    @Test func commandSWhileStreamingSavesOnceDone() async throws {
        let generator = AskTestTextGenerator()
        generator.pieces = ["Part", " done"]
        generator.delay = .milliseconds(60)
        let plugin = AskPromptPlugin(generator: generator, modelName: { "m" }, savesNotes: true)
        let session = AskPluginSession(plugins: [plugin]) { AskPromptPlugin.keywords }
        var saved: [String] = []
        session.saveNoteWhenDone = { saved.append($0.body) }
        session.toggleSaveNoteWhenDone()
        #expect(!session.savesNoteWhenDone, "only while running")
        session.enter(AskPromptPlugin.keywords[0])
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { session.isRunning }
        session.toggleSaveNoteWhenDone()
        #expect(session.savesNoteWhenDone)
        try await settle { session.output != nil }
        #expect(saved == ["Part done"] && !session.savesNoteWhenDone)
        session.showNoteSaved(true)
        #expect(session.output?.starred == true)
        session.update(text: "z", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { session.isRunning }
        session.toggleSaveNoteWhenDone()
        session.deactivate()
        #expect(!session.savesNoteWhenDone, "leaving keyword mode forgets it")
    }

    // MARK: - The launcher model

    @Test func theModelSavesRemovesAndOpensNotes() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let store = makeTestNotes()
        model.notes = store
        var opened: [UUID?] = []
        model.openNotes = { opened.append($0) }
        var windows: [AskNote] = []
        model.openNoteWindow = { windows.append($0) }
        let generator = AskTestTextGenerator()
        generator.pieces = ["Answer"]
        model.promptAI = generator
        model.plugins = AskPluginSession(plugins: model.makeLauncherPlugins()) { AskPluginRegistry.defaultKeywords }
        model.connectNotes(to: model.plugins)
        model.launcherDraft = AskDraft(text: "", includeScreenshot: false, selection: nil,
                                       source: "Safari — Docs", sourceBundleID: "com.apple.Safari")
        model.plugins.enter(AskPromptPlugin.keywords[2])
        model.plugins.update(text: "topic", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { model.plugins.output != nil }
        let output = try #require(model.plugins.output)
        let save = try #require(output.action(for: .commandS))
        #expect(model.performPluginAction(save) == .stay)
        await model.notebookTask?.value
        let note = try #require(try store.list(AskNoteQuery()).first)
        #expect(note.body == "Answer" && note.sourceApp == "Safari" && note.sourceBundleID == "com.apple.Safari")
        #expect(model.plugins.output?.starred == true && model.commandFeedback == L("ask.notes.saved"))
        #expect(model.launcherNoteID == note.id)
        // ⌘S again takes it out.
        #expect(try model.performPluginAction(#require(model.plugins.output?.action(for: .commandS))) == .stay)
        await model.notebookTask?.value
        #expect(try store.count(.all) == 0 && model.plugins.output?.starred == false)
        #expect(model.commandFeedback == L("ask.notes.removed"))
        // An edited note stays.
        _ = model.performPluginAction(save)
        await model.notebookTask?.value
        var edited = try #require(try store.list(AskNoteQuery()).first)
        edited.editedAt = Date()
        try store.save(edited)
        _ = model.performPluginAction(save)
        await model.notebookTask?.value
        #expect(try store.count(.all) == 1 && model.commandFeedback == L("ask.notes.editedKept"))
        #expect(model.performPluginAction(.init(kind: .copyRich("**x**"), title: "", symbol: "")) == .stay)
        #expect(model.commandFeedback == L("ask.plugin.copiedRich"))
        #expect(model.performPluginAction(.init(kind: .openNotes(id: nil), title: "", symbol: "")) == .close)
        #expect(opened == [edited.id], "⌘B opens the notes on the saved result")
        #expect(model.performPluginAction(.init(kind: .openNote(edited.id), title: "", symbol: "")) == .stay)
        await model.notebookTask?.value
        #expect(windows.map(\.id) == [edited.id])
        #expect(model.performPluginAction(.init(kind: .openNote(UUID()), title: "", symbol: "")) == .stay)
        #expect(await model.saveLauncherNote(AskNoteDraft(command: "c", keyword: "k", input: "", body: " ", model: nil)) == nil)
        model.notes = nil
        await model.toggleLauncherNote(AskNoteDraft(command: "c", keyword: "k", input: "", body: "b", model: nil))
        #expect(try store.count(.all) == 1, "without notes nothing is saved")
    }

    @Test func commandOMovesAStreamingResultIntoAWindow() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.notes = makeTestNotes()
        var presented: [AskResultDocument] = []
        model.presentResultWindow = { presented.append($0) }
        let generator = AskTestTextGenerator()
        generator.pieces = ["Slow", " answer"]
        // Long enough that a loaded machine still sees the first piece alone.
        generator.delay = .milliseconds(400)
        model.promptAI = generator
        model.plugins = AskPluginSession(plugins: model.makeLauncherPlugins()) { AskPluginRegistry.defaultKeywords }
        model.connectNotes(to: model.plugins)
        model.launcherDraft = AskDraft(text: "", includeScreenshot: false, selection: nil, source: "Mail",
                                       sourceBundleID: "com.apple.mail")
        #expect(model.performPluginAction(.init(kind: .openInWindow, title: "", symbol: "")) == .stay,
                "nothing to open outside keyword mode")
        model.plugins.enter(AskPromptPlugin.keywords[0])
        model.plugins.update(text: "teh", selection: nil, language: .english, runWhenPlanned: true)
        try await settle { model.plugins.partial?.body == "Slow" }
        // ⌘S while streaming asks to save once done.
        let save = try #require(model.plugins.currentOutput?.action(for: .commandS))
        _ = model.performPluginAction(save)
        await model.notebookTask?.value
        #expect(model.plugins.savesNoteWhenDone && model.commandFeedback == L("ask.notes.saveWhenDone"))
        _ = model.performPluginAction(save)
        await model.notebookTask?.value
        #expect(!model.plugins.savesNoteWhenDone && model.commandFeedback == L("ask.notes.saveWhenDone.cancelled"))
        #expect(model.performPluginAction(.init(kind: .openInWindow, title: "", symbol: "")) == .close)
        let document = try #require(presented.first)
        #expect(!model.plugins.isActive, "the launcher leaves keyword mode")
        #expect(document.isStreaming && document.sourceApp == "Mail" && document.sourceBundleID == "com.apple.mail")
        #expect(document.body == "Slow", "the window starts with what already streamed in")
        try await settle { document.state == .done }
        #expect(document.body == "Slow answer")
    }
}

@Suite("Ask notes window", .exclusiveUIState)
@MainActor
struct AskNotesViewModelTests {
    private func model(_ store: SQLiteAskNoteStore) async -> AskNotesViewModel {
        let model = AskNotesViewModel(store: store, notificationCenter: NotificationCenter())
        await model.waitForReload()
        model.clock = { Date(timeIntervalSince1970: 5000) }
        return model
    }

    @Test func listsFiltersAndReveals() async throws {
        let store = makeTestNotes()
        let a = makeTestNote("A", command: "Explain", tags: ["x"], at: 10)
        let b = makeTestNote("B", body: "needle", command: "Sum", at: 20)
        try store.save(a)
        try store.save(b)
        let notes = await model(store)
        #expect(notes.notes.map(\.title) == ["B", "A"] && notes.selectedID == b.id)
        #expect(notes.counts[.all] == 2 && notes.counts[.pinned] == 0)
        #expect(notes.commands.map(\.name).sorted() == ["Explain", "Sum"] && notes.tags.map(\.name) == ["x"])
        notes.scope = .tag("x")
        await notes.waitForNavigation()
        #expect(notes.notes.map(\.title) == ["A"] && notes.selectedID == a.id)
        await notes.reveal(b.id)
        #expect(notes.scope == .all && notes.selectedID == b.id)
        notes.searchText = "needle"
        await notes.waitForNavigation()
        #expect(notes.notes.map(\.title) == ["B"])
        await notes.reveal(a.id)
        #expect(notes.searchText.isEmpty && notes.selectedID == a.id)
        await notes.reveal(UUID())
        await notes.reveal(nil)
        #expect(notes.selectedID == a.id)
        notes.sort = .created
        await notes.waitForNavigation()
        await notes.moveSelection(-1)
        #expect(notes.selectedID == b.id)
        await notes.moveSelection(5)
        #expect(notes.selectedID == a.id)
        #expect(notes.title(of: .all) == L("ask.notes.shelf.all") && notes.title(of: .pinned) == L("ask.notes.shelf.pinned"))
        #expect(notes.title(of: .command("Sum")) == "Sum" && notes.title(of: .tag("x")) == "#x")
    }

    @Test func editsTitlesTextPinsAndTags() async throws {
        let store = makeTestNotes()
        let note = makeTestNote("Old", body: "Body", tags: ["keep"])
        try store.save(note)
        let notes = await model(store)
        await notes.rename("  New  ")
        #expect(try store.note(id: note.id)?.title == "New")
        await notes.rename("")
        #expect(try store.note(id: note.id)?.title == AskNote.title(command: note.command, input: note.input))
        notes.beginEditing()
        #expect(notes.editing && notes.draftBody == "Body")
        notes.draftBody = "Changed"
        await notes.finishEditing()
        let edited = try #require(try store.note(id: note.id))
        #expect(!notes.editing && edited.body == "Changed" && edited.editedAt == Date(timeIntervalSince1970: 5000))
        notes.beginEditing()
        notes.draftBody = "Kept"
        await notes.cancelEditing()
        #expect(try store.note(id: note.id)?.body == "Kept" && !notes.editing, "edits save as they are typed")
        #expect(try store.note(id: note.id)?.originalBody == "Body", "the AI text is kept as a source snapshot")
        notes.beginEditing()
        await notes.finishEditing()
        #expect(try store.note(id: note.id)?.updatedAt == Date(timeIntervalSince1970: 5000))
        await notes.togglePin()
        #expect(try store.note(id: note.id)?.pinned == true && notes.counts[.pinned] == 1)
        await notes.addTag("#new ")
        await notes.addTag("keep")
        await notes.addTag("  ")
        #expect(try store.note(id: note.id)?.tags == ["keep", "new"])
        notes.scope = .tag("new")
        await notes.waitForNavigation()
        await notes.removeTag("new")
        await notes.removeTag("missing")
        #expect(try store.note(id: note.id)?.tags == ["keep"] && notes.scope == .all, "an emptied tag shelf falls back")
    }

    @Test func deletesWithUndoAndUsesNotes() async throws {
        let store = makeTestNotes()
        let first = makeTestNote("First", body: "One", at: 20)
        let second = makeTestNote("Second", body: "Two", at: 10)
        try store.save(first)
        try store.save(second)
        let notes = await model(store)
        var copied: [String] = [], rich: [String] = [], asked: [AskNote] = [], windows: [UUID] = []
        notes.copy = { copied.append($0) }
        notes.copyRich = { rich.append($0) }
        notes.openInWindow = { windows.append($0.id) }
        notes.askAIAboutSelected()
        notes.askAI = { asked.append($0) }
        notes.copySelected()
        #expect(notes.notice == L("ask.plugin.copied"))
        notes.copySelectedRich()
        notes.askAIAboutSelected()
        notes.openSelectedInWindow()
        #expect(copied == ["One"] && rich == ["One"] && windows == [first.id])
        #expect(asked == [first])
        notes.beginEditing()
        await notes.deleteSelected()
        #expect(try store.count(.all) == 1 && notes.selectedID == second.id && !notes.editing)
        #expect(notes.noticeOffersUndo && notes.notice == L("ask.notes.deleted", "First"))
        await notes.undoDelete()
        #expect(try store.note(id: first.id) == first && notes.selectedID == first.id && notes.notice == nil)
        await notes.undoDelete()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var suggested: String?
        notes.chooseExportURL = { name in
            suggested = name
            return folder.appendingPathComponent(name)
        }
        notes.exportSelected()
        #expect(suggested == "First.md" && notes.notice == L("ask.notes.exported", "First.md"))
        #expect(try String(contentsOf: folder.appendingPathComponent("First.md"), encoding: .utf8)
            == AskNoteExporter.markdown(first))
        notes.chooseExportURL = { _ in folder.appendingPathComponent("missing/dir/x.md") }
        notes.exportSelected()
        #expect(notes.notice != L("ask.notes.exported", "x.md"), "a failed export says why")
        notes.chooseExportURL = { _ in nil }
        notes.exportSelected()
        await notes.deleteSelected()
        await notes.deleteSelected()
        #expect(try store.count(.all) == 0 && notes.selectedID == nil)
        await notes.deleteSelected()
        notes.copySelected()
        await notes.rename("x")
        notes.beginEditing()
        #expect(!notes.editing)
    }

    @Test func followsChangesFromElsewhere() async throws {
        let store = makeTestNotes()
        let center = NotificationCenter()
        store.notificationCenter = center
        let notes = AskNotesViewModel(store: store, notificationCenter: center)
        await notes.waitForReload()
        #expect(notes.notes.isEmpty && notes.selectedID == nil)
        try store.save(makeTestNote())
        for _ in 0 ..< 100 where notes.notes.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(notes.notes.count == 1 && notes.selectedID != nil)
    }

    @Test func theWindowOpensOnANote() async throws {
        let store = makeTestNotes()
        let note = makeTestNote()
        try store.save(note)
        let controller = AskNotesWindowController()
        controller.show(selecting: note.id)
        await controller.model?.waitForActions()
        #expect(controller.window == nil, "unconfigured, there is nothing to show")
        controller.configure(store: store, askAI: { _ in }, appearance: { nil })
        controller.show(selecting: note.id)
        await controller.model?.waitForActions()
        #expect(controller.model?.selectedID == note.id && controller.window?.isVisible == true)
        controller.show()
        await controller.model?.waitForActions()
        controller.window?.close()
        #expect(controller.window == nil && controller.model == nil)
    }
}
