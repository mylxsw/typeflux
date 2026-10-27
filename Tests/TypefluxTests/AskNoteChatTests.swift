import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskNoteChatTests {
    @Test func opensWithSnapshotAndSendsOnlyAfterTheUserAsks() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        var note = makeTestNote("Names", body: "Nuonuo and Anan")
        note.input = "Suggest baby names"
        note.source = .chat
        note.conversationID = "original-conversation"
        note.messageID = "original-message"
        f.model.launcherDraft = AskDraft(text: "Unrelated launcher", screenshot: "image", selection: "Unrelated selection")
        let launcher = f.model.launcherDraft
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        #expect(await f.model.openChat(referencing: note))
        let reference = try #require(f.model.draft.references?.first)
        #expect(reference.noteId == note.id && reference.messageId == note.id.uuidString)
        #expect(reference.text == "# Names\n\n> Suggest baby names\n\nNuonuo and Anan")
        #expect(reference.question.isEmpty)
        #expect(f.model.draft.text.isEmpty && !f.model.draft.canSend)
        #expect(!f.model.draft.includeScreenshot && f.model.draft.screenshot == nil)
        #expect(f.model.draft.selection == nil && f.model.draft.source == nil)
        #expect(f.model.launcherDraft == launcher)
        #expect(f.model.selectedId == nil && f.model.conversations.isEmpty && opens == 1)
        f.model.submitDraft()
        #expect(await f.api.sends.isEmpty)
        #expect(await f.localAPI.sends.isEmpty)
        f.model.draft.text = "Which name sounds better?"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.run?.status == "completed" }
        let request = try #require(await f.api.sends.first)
        #expect(request.text == "Which name sounds better?")
        #expect(request.references == [reference])
        #expect(request.selection == nil && request.image == nil)
        #expect(f.model.selected?.messages.first?.references == [reference])
        #expect(AskLocalPrompt.references(request.references).contains(note.body))
        // Subsequent questions use the same history, which retains the snapshot.
        f.model.draft.text = "And a nickname?"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.messages.count == 4 && !f.model.isBusy }
        #expect(f.model.selected?.messages.first?.references == [reference])
    }

    @Test func preservesExistingConversationAndUnsentWorkspaceDrafts() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.seed(.init(id: "old", title: "Old", revision: 1, updatedAt: Date(), messages: []))
        await f.model.select("old")
        f.model.draft.text = "Keep my existing draft"
        let note = makeTestNote("Note", body: "Current article")
        #expect(await f.model.openChat(referencing: note))
        #expect(try await f.cache.draft(key: "old", owner: "owner")?.text == "Keep my existing draft")
        #expect(f.model.selectedId == nil)
        // Opening a second note saves the first note's unsent reference too.
        #expect(await f.model.openChat(referencing: makeTestNote("Second")))
        let saved = try #require(f.model.savedChatDrafts.first)
        #expect(saved.draft.references?.first?.noteId == note.id)
        await f.model.restoreChatDraft(saved)
        #expect(f.model.draft.references?.first?.noteId == note.id)
        await f.model.select("old")
        #expect(f.model.draft.text == "Keep my existing draft")
    }

    @Test func referenceRoundTripsAndLocatesTheNoteInsteadOfAChatMessage() throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let note = makeTestNote("Article", body: "Reference content")
        let reference = AskReference(note: note)
        let data = try AskCoding.encoder().encode(reference)
        #expect(String(decoding: data, as: UTF8.self).contains("note_id"))
        #expect(try AskCoding.decoder().decode(AskReference.self, from: data) == reference)
        let legacy = AskReference(messageId: UUID().uuidString, text: "An answer")
        #expect(try AskCoding.decoder().decode(AskReference.self, from: AskCoding.encoder().encode(legacy)).noteId == nil)
        var opened: UUID?
        f.model.openNotes = { opened = $0 }
        f.model.locateReference(reference.locationId)
        #expect(opened == note.id && f.model.referenceLocation == nil)
        f.model.locateReference(legacy.locationId)
        #expect(f.model.referenceLocation == legacy.messageId)
        #expect(f.model.highlightedMessageId == legacy.messageId)
    }

    @Test func limitsAndCacheFailuresLeaveTheCurrentDraftIntact() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        _ = f.model.credentials()
        f.model.draft.text = "Keep this"
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        #expect(await !f.model.openChat(referencing: makeTestNote("Huge", body: String(repeating: "中", count: 22000))))
        #expect(f.model.commandFeedback == L("ask.input.tooLarge"))
        f.model.recordingIsActive = { true }
        #expect(await !f.model.openChat(referencing: makeTestNote("Busy")))
        f.model.recordingIsActive = { false }
        try await f.cache.execute(
            "CREATE TRIGGER fail_drafts BEFORE INSERT ON ask_drafts BEGIN SELECT RAISE(ABORT, 'unavailable'); END",
            strings: []
        )
        #expect(await !f.model.openChat(referencing: makeTestNote("Normal")))
        #expect(f.model.draft.text == "Keep this" && opens == 0 && !f.model.isOpeningChat)
        #expect(f.model.commandFeedback == L("ask.cache.failed"))
    }

    @Test func signedOutUsersCanPrepareAQuestionWithoutASignInPrompt() async throws {
        let f = try AskTestFixture(authenticated: false)
        defer { f.model.resetSession() }
        var opens = 0
        f.model.onShowConversation = { opens += 1 }
        #expect(await f.model.openChat(referencing: makeTestNote("Article")))
        #expect(opens == 1 && f.model.error == nil && !f.model.draft.canSend)
        #expect(await f.api.sends.isEmpty)
    }
}
