import Foundation
import Testing
@testable import Typeflux

@Suite("Notebook entry point regressions", .exclusiveUIState)
@MainActor
struct AskNotebookEntryRegressionTests {
    private func conversation(_ fixture: AskTestFixture) async -> AskMessage {
        let answer = AskMessage(id: "answer", role: "assistant", text: "    code\n\nAnswer\n", createdAt: Date())
        await fixture.api.seed(AskConversation(id: "notebook-chat", title: "Notes", revision: 1, updatedAt: Date(),
                                               messages: [AskMessage(id: "question", role: "user", text: "Example?", createdAt: Date()),
                                                          answer]))
        await fixture.model.select("notebook-chat")
        return answer
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func cancellingAnAnswerSaveMovesItToTrashAndRestoringRefreshesTheBadge() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        // Exercise the application's notification path instead of the helper's isolated center.
        store.notificationCenter = .default
        fixture.model.notes = store
        let answer = await conversation(fixture)
        fixture.model.toggleAnswerNote(answer)
        let note = try #require(store.list(AskNoteQuery()).first)
        #expect(note.body == answer.text, "saving Markdown must preserve an indented code block")
        fixture.model.toggleAnswerNote(answer)
        #expect(store.note(id: note.id)?.isDeleted == true && store.count(.trash) == 1)
        #expect(fixture.model.answerNoteIDs.isEmpty)
        #expect(!fixture.model.openNoteInWindow(note.id), "trash is only opened from Recently Deleted")
        store.save(note)
        try await settle { fixture.model.answerNoteIDs[answer.id] == note.id }
        store.trash(ids: [note.id], at: Date())
        try await settle { fixture.model.answerNoteIDs.isEmpty }
    }

    @Test func savedAnswersAreFoundBeyondTheFirstPageAndOtherConversations() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        store.notificationCenter = NotificationCenter()
        let answer = await conversation(fixture)
        var notes = (0 ..< 510).map { index -> AskNote in
            var note = makeTestNote("Message \(index)", at: Double(1000 + index))
            note.source = .chat
            note.conversationID = "notebook-chat"
            note.messageID = "message-\(index)"
            return note
        }
        var saved = makeTestNote("Old answer", at: 10)
        saved.source = .chat
        saved.conversationID = "notebook-chat"
        saved.messageID = answer.id
        notes.append(saved)
        var unrelated = saved
        unrelated.id = UUID()
        unrelated.conversationID = "another-chat"
        unrelated.updatedAt = Date()
        notes.append(unrelated)
        store.restore(notes)
        fixture.model.notes = store
        #expect(fixture.model.answerNoteIDs.count == 511)
        #expect(fixture.model.answerNoteIDs[answer.id] == saved.id)
        fixture.model.toggleAnswerNote(answer)
        #expect(store.note(id: saved.id)?.isDeleted == true)
        #expect(store.note(id: unrelated.id)?.isDeleted == false)
    }

    @Test func staleMessagesCannotSaveIntoTheCurrentConversation() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        fixture.model.notes = store
        _ = await conversation(fixture)
        fixture.model.toggleAnswerNote(AskMessage(id: "foreign", role: "assistant", text: "Other chat", createdAt: Date()))
        fixture.model.toggleAnswerNote(AskMessage(id: "question", role: "user", text: "Question", createdAt: Date()))
        #expect(store.count(.all) == 0)
    }

    @Test func launcherUnsaveIsRecoverableAndTrashedNotesCanBeSavedAgain() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        fixture.model.notes = store
        let draft = AskNoteDraft(command: "Explain", keyword: "ex", input: "Topic", body: "Answer")
        let first = try #require(fixture.model.saveLauncherNote(draft))
        fixture.model.toggleLauncherNote(draft)
        #expect(store.note(id: first)?.isDeleted == true && fixture.model.launcherNote == nil)
        fixture.model.toggleLauncherNote(draft)
        #expect(store.count(.all) == 1 && store.count(.trash) == 1)
        let saved = try #require(fixture.model.launcherNote?.id)
        store.trash(ids: [saved], at: Date())
        fixture.model.toggleLauncherNote(draft)
        #expect(store.count(.all) == 1 && store.count(.trash) == 2)
        #expect(fixture.model.launcherNote?.id != saved)
    }

    @Test func failedSavesExplainTheFailureWithoutShowingASavedBadge() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        fixture.model.notes = SQLiteAskNoteStore(url: blocked.appendingPathComponent("notes.sqlite"))
        let answer = await conversation(fixture)
        fixture.model.toggleAnswerNote(answer)
        #expect(fixture.model.answerNoteIDs.isEmpty)
        #expect(fixture.model.commandFeedback == L("ask.notes.saveFailed"))
        let draft = AskNoteDraft(command: "Explain", keyword: "ex", input: "Topic", body: "Answer")
        #expect(fixture.model.saveLauncherNote(draft) == nil && fixture.model.launcherNote == nil)
        #expect(fixture.model.commandFeedback == L("ask.notes.saveFailed"))
    }
}
