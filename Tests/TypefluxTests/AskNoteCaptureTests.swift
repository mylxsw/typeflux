import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher quick note capture", .exclusiveUIState)
@MainActor
struct AskNoteCaptureTests {
    private func prepare(_ fixture: AskTestFixture, body: String) {
        _ = fixture.model.credentials()
        fixture.model.plugins.enter(AskNoteCapturePlugin.keywords[0])
        fixture.model.launcherDraft = AskDraft(text: body, includeScreenshot: false, selection: "Never capture this")
    }

    @Test func `prefix preserves whitespace and does not steal notes or workflows`() async throws {
        let plugin = AskNoteCapturePlugin()
        let keyword = plugin.defaultKeywords[0]
        #expect(plugin.id == AskNoteCapturePlugin.id && plugin.entersOnReturn && plugin.runsWithoutInput)
        #expect(!plugin.usesSelectionInput && plugin.preservesInputWhitespace)
        #expect(!plugin.title.isEmpty && !plugin.symbol.isEmpty && !plugin.placeholder(selectionLines: nil).isEmpty)
        #expect(plugin.chipDetail(for: keyword, language: .english) == nil)
        for prefix in ["n ", "N:", "记：", "记　"] {
            #expect(AskKeywordMatcher.match(prefix + "    code\n\n", keywords: [keyword]) == .active(
                keyword,
                argument: "    code\n\n"
            ))
        }
        for text in ["note", "notes", "notebook", "nb", "never"] {
            #expect(AskKeywordMatcher.match(text, keywords: [keyword]) == nil)
        }
        let oldGroups = AskPluginRegistry.coveredGroups.filter { $0 != plugin.id }
        let occupied = AskKeyword(keyword: "n", pluginID: AskWebSearchPlugin.id)
        let migrated = AskPluginRegistry.keywords(saved: [occupied], known: oldGroups)
        #expect(migrated.first == occupied)
        #expect(migrated.first { $0.pluginID == plugin.id }?.allKeywords == ["记"])
        #expect(AskPluginRegistry.keywords(saved: migrated, known: AskPluginRegistry.coveredGroups) == migrated)
        #expect(!AskPluginRegistry.keywords(saved: nil, known: nil, reserved: ["n", "记"])
            .contains { $0.pluginID == plugin.id })
        let request = AskPluginRequest(
            text: "Body",
            origin: .argument,
            keyword: keyword,
            options: [:],
            interfaceLanguage: .english
        )
        let plan = await plugin.plan(request)
        #expect(plan.mode == .onSubmit && plan.actions.isEmpty)
        #expect(plugin.nextOptions(after: plan, request: request, step: 1) == nil)
        do { _ = try await plugin.run(request, plan: plan) { _ in }; Issue.record("Preview must never save") }
        catch is CancellationError {} catch { Issue.record(error) }
    }

    @Test func `state keeps exact body and reuses only A failed submission`() throws {
        var state = AskNoteCaptureState()
        #expect(state.begin(at: Date()) == nil)
        state.update(" \n ")
        #expect(!state.hasContent && state.begin(at: Date()) == nil)
        let body = "\n    # **A heading**\n\n    code\n#literal @name\n"
        state.update(body)
        let admitted = state.begin(at: Date(timeIntervalSince1970: 10))
        let note = try #require(admitted)
        #expect(note.body == body && note.title == "A heading")
        #expect(note.source == .manual && note.author == .user && note.model == nil && note.originalBody == nil)
        #expect(state.begin(at: Date()) == nil)
        state.update("Ignored while saving")
        #expect(state.body == body)
        state.complete(note, failure: "Failed")
        let retried = state.begin(at: Date())
        let retry = try #require(retried)
        #expect(retry == note)
        state.complete(retry, failure: nil)
        #expect(state.body.isEmpty && state.saved == note && state.submission == nil)
        state.update(body)
        #expect(state.begin(at: Date())?.id != note.id)
        #expect(AskNoteCaptureState.title(for: "\n###\nText") == L("ask.noteCapture.untitled"))
        #expect(AskNoteCaptureState.title(for: String(repeating: "🐱", count: 30)).count == AskNote.titleLength + 1)
    }

    @Test func `explicit submit saves locally without history or AI and allows another note`() async throws {
        let f = try AskTestFixture(localOnly: true)
        defer { f.model.resetSession() }
        let store = makeTestNotes()
        f.model.notes = store
        prepare(f, body: "    code\n\nAnother line\n")
        #expect(try store.count(.all) == 0)
        f.model.recordLauncherInput(destination: .keyword)
        f.model.recordAbandonedLauncherInput()
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
        let task = try #require(f.model.submitNoteCapture())
        #expect(f.model.noteCapture.saving && f.model.submitNoteCapture() == nil)
        f.model.clearNoteCapture()
        #expect(f.model.noteCapture.saving)
        await task.value
        let note = try #require(try store.list(AskNoteQuery()).first)
        #expect(note.body == "    code\n\nAnother line\n" && note.title == "code")
        #expect(f.model.noteCapture.saved?.id == note.id && f.model.launcherDraft.text.isEmpty)
        #expect(f.model.isNoteCaptureMode && f.model.noteCapture.failure == nil)
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
        f.model.launcherDraft.text = note.body
        await f.model.submitNoteCapture()?.value
        #expect(try store.count(.all) == 2)
        f.model.clearNoteCapture()
        #expect(f.model.noteCapture.saved == nil && f.model.noteCapture.body.isEmpty)
    }

    @Test func `empty unavailable disabled and renamed keywords`() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        prepare(f, body: " \n ")
        #expect(f.model.submitNoteCapture() == nil)
        f.model.launcherDraft.text = "Private"
        #expect(f.model.submitNoteCapture() == nil && f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
        let keyword = AskKeyword(keyword: "capture", pluginID: AskNoteCapturePlugin.id, aliases: ["记录"])
        f.model.modelLibrary.settings.saveAskLauncherKeywords([keyword])
        #expect(!f.model.isNoteCaptureInput("n Body"))
        #expect(f.model.isNoteCaptureInput("记录：Private"))
        #expect(f.model.submitNoteCapture() == nil, "The stale default chip is no longer authorized")
        _ = f.model.enterSelectedLauncherKeyword(keyword, run: false)
        #expect(f.model.launcherDraft.text == "Private")
        f.model.plugins.deactivate()
        f.model.launcherDraft.text = "capture"
        #expect(f.model.enterLauncherKeywordFromText(pluginID: AskNoteCapturePlugin.id))
        #expect(f.model.launcherDraft.text == "Private")
        #expect(f.model.isNoteCaptureInput("capture"))
        f.model.modelLibrary.settings.saveAskLauncherKeywords([AskKeyword(
            keyword: "capture",
            pluginID: keyword.pluginID,
            enabled: false
        )])
        f.model.foldLauncherKeyword()
        #expect(!f.model.resetLauncherForPresentation())
        #expect(!f.model.plugins.isActive)
    }

    @Test func `closing retains private draft beyond the normal timeout and reset clears it`() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        f.model.launcherDraft.text = "记：    private\n"
        f.model.recordAbandonedLauncherInput()
        f.model.foldLauncherKeyword()
        #expect(f.model.launcherDraft.text.isEmpty && f.model.noteCapture.body == "    private\n")
        f.model.launcherDismissedAt = Date(timeIntervalSince1970: 0)
        #expect(f.model.resetLauncherForPresentation())
        #expect(f.model.isNoteCaptureMode && f.model.launcherDraft.text == "    private\n")
        f.model.recordLauncherInput(destination: .keyword, text: "n Secret", keyword: "n")
        #expect(f.model.launcherInputHistory.history.entries.isEmpty)
        f.model.foldLauncherKeyword()
        f.model.resetSession()
        #expect(f.model.noteCapture.body.isEmpty && f.model.noteCapture.resumeKeyword == nil)
    }

    @Test func `failures retain draft and retry uses the same UUID even after an uncertain commit`() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let store = CaptureTestStore()
        await store.configure(failure: .afterCommit)
        f.model.notes = store
        prepare(f, body: "Do not lose this")
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.storageUnavailable"))
        let id = try #require(f.model.noteCapture.submission?.id)
        #expect(f.model.launcherDraft.text == "Do not lose this" && f.model.noteCapture.saved == nil)
        f.model.foldLauncherKeyword()
        #expect(f.model.resetLauncherForPresentation())
        #expect(f.model.noteCapture.submission?.id == id)
        await f.model.submitNoteCapture()?.value
        #expect(await store.count(.all) == 1)
        #expect(f.model.noteCapture.saved?.id == id && f.model.noteCapture.failure == nil)
        f.model.launcherDraft.text = "Changed"
        await store.configure(failure: .returnFalse)
        await f.model.submitNoteCapture()?.value
        #expect(f.model.noteCapture.failure == L("ask.notes.saveFailed"))
        f.model.launcherDraft.text = "Changed again"
        #expect(f.model.noteCapture.submission == nil && f.model.noteCapture.failure == nil)
    }

    @Test(arguments: [true, false])
    func `closing during save updates only its own capture`(reopen: Bool) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let store = CaptureTestStore()
        await store.configure(paused: true)
        f.model.notes = store
        prepare(f, body: "Snapshot")
        let task = try #require(f.model.submitNoteCapture())
        try await f.wait { f.model.noteCapture.saving }
        f.model.foldLauncherKeyword()
        if reopen {
            #expect(f.model.resetLauncherForPresentation())
            #expect(f.model.noteCapture.saving && f.model.launcherDraft.text == "Snapshot")
        } else {
            f.model.plugins.enter(AskNotesPlugin.keywords[0])
            f.model.launcherDraft.text = "Other search"
        }
        await store.release()
        await task.value
        #expect(f.model.noteCapture.saved?.body == "Snapshot")
        #expect(f.model.launcherDraft.text == (reopen ? "" : "Other search"))
    }

    @Test func `account reset does not restore an old save result`() async throws {
        let f = try AskTestFixture()
        let store = CaptureTestStore()
        await store.configure(paused: true)
        f.model.notes = store
        prepare(f, body: "Old account")
        let task = try #require(f.model.submitNoteCapture())
        f.model.resetSession()
        await store.release()
        await task.value
        #expect(f.model.noteCapture.saved == nil && f.model.noteCapture.body.isEmpty)
    }

    @Test(arguments: [false, true])
    func `retry never overwrites an edited or deleted committed note`(deleted: Bool) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let store = CaptureTestStore()
        await store.configure(failure: .afterCommit)
        f.model.notes = store
        prepare(f, body: "Submitted")
        await f.model.submitNoteCapture()?.value
        var existing = try #require(f.model.noteCapture.submission)
        existing.body = "Edited in another window"
        existing.deletedAt = deleted ? Date() : nil
        _ = try await store.save(existing)
        await f.model.submitNoteCapture()?.value
        #expect(await store.note(id: existing.id) == existing)
        if deleted {
            #expect(f.model.noteCapture.failure == L("ask.noteCapture.deleted"))
            #expect(f.model.launcherDraft.text == "Submitted")
        } else {
            #expect(f.model.noteCapture.saved == existing)
            #expect(f.model.launcherDraft.text.isEmpty)
        }
    }

    @Test func `settings directory and help expose the capture keyword`() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let keyword = AskNoteCapturePlugin.keywords[0]
        let row = AskKeywordListPresentation.rows(keywords: [keyword], interface: .english, secondLanguage: "zh-Hans")
            .first
        #expect(row?.kind == .noteCapture && row?.name == L("ask.noteCapture.title"))
        #expect(row?.summary == L("ask.settings.keywords.kind.noteCapture.hint"))
        let draft = AskKeywordDraft(editing: keyword)
        #expect(draft.displayName == L("ask.noteCapture.title") && draft.fieldProblem == nil)
        #expect(draft.result() == keyword)
        #expect(AskKeywordKind.noteCapture.pluginID == keyword.pluginID)
        #expect(!AskKeywordKind.noteCapture.symbol.isEmpty && !AskKeywordKind.noteCapture.hint.isEmpty)
        #expect(f.model.launcherKeywordDirectory(language: .english).contains { $0.keyword == keyword && $0.canEnter })
        #expect(f.model.helpKeywordSources(language: .english)
            .contains { $0.entry.keyword == keyword && !$0.usesSelection })
        #expect(AskKeywordSection.typeflux.kinds.contains(.noteCapture))
        f.model.enterKeywordFromHelp(keyword, argument: "Help example", refreshingWorkflows: false)
        #expect(f.model.noteCapture.body == "Help example")
        f.model.enterKeywordFromHelp(keyword, argument: "", refreshingWorkflows: false)
        #expect(f.model.launcherDraft.text == "Help example")
        f.model.plugins.deactivate()
        let hotkey = KeywordHotkey(binding: nil, keyword: keyword.keyword, pluginID: keyword.pluginID)
        f.model.enterKeywordShortcut(hotkey, refreshingWorkflows: false)
        #expect(f.model.launcherDraft.text == "Help example", "Opening via a shortcut restores rather than submits")
        #expect(f.model.noteCapture.saved == nil)
        f.model.plugins.deactivate()
        f.model.launcherDraft.text = ""
        _ = f.model.enterLauncherKeyword(keyword, run: false)
        #expect(f.model.launcherDraft.text == "Help example")
    }
}

/// A deterministic store that can pause admission or report an uncertain post-commit failure.
private actor CaptureTestStore: AskNoteStoring {
    enum Failure { case none, returnFalse, afterCommit }
    private var notes: [UUID: AskNote] = [:]
    private var failure = Failure.none
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(failure: Failure = .none, paused: Bool = false) {
        self.failure = failure; self.paused = paused
    }

    func release() {
        paused = false; continuation?.resume(); continuation = nil
    }

    func save(_ note: AskNote) async throws -> Bool {
        if paused {
            await withCheckedContinuation { continuation = $0 }
        }
        let result = failure
        failure = .none
        if result == .returnFalse {
            return false
        }
        notes[note.id] = note
        if result == .afterCommit {
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    func note(id: UUID) -> AskNote? {
        notes[id]
    }

    func list(_: AskNoteQuery) -> [AskNote] {
        Array(notes.values)
    }

    func count(_: AskNoteQuery.Scope) -> Int {
        notes.count
    }

    func save(_: AskNote, replacing _: AskNote, revisionAt _: Date?) -> Bool {
        false
    }

    func delete(ids _: [UUID]) {}
    func restore(_: [AskNote]) {}
    func commands() -> [AskNoteFacet] {
        []
    }

    func sources() -> [AskNoteFacet] {
        []
    }

    func tags() -> [AskNoteFacet] {
        []
    }

    func trash(ids _: [UUID], at _: Date) {}
    func purgeTrash(before _: Date) {}
    func saveRevision(_: AskNote, at _: Date) {}
    func revisions(of _: UUID) -> [AskNoteRevision] {
        []
    }

    func deleteRevision(of _: UUID, at _: Date) {}
}
