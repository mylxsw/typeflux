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
        await fixture.model.toggleAnswerNote(answer)
        let note = try #require(try store.list(AskNoteQuery()).first)
        #expect(note.body == answer.text, "saving Markdown must preserve an indented code block")
        await fixture.model.toggleAnswerNote(answer)
        #expect(try store.note(id: note.id)?.isDeleted == true && store.count(.trash) == 1)
        #expect(fixture.model.answerNoteIDs.isEmpty)
        #expect(!(await fixture.model.openNoteInWindow(note.id)), "trash is only opened from Recently Deleted")
        try store.save(note)
        try await settle { fixture.model.answerNoteIDs[answer.id] == note.id }
        try store.trash(ids: [note.id], at: Date())
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
        try store.restore(notes)
        fixture.model.notes = store
        await fixture.model.notebookReadTask?.value
        #expect(fixture.model.answerNoteIDs.count == 511)
        #expect(fixture.model.answerNoteIDs[answer.id] == saved.id)
        await fixture.model.toggleAnswerNote(answer)
        #expect(try store.note(id: saved.id)?.isDeleted == true)
        #expect(try store.note(id: unrelated.id)?.isDeleted == false)
    }

    @Test func staleMessagesCannotSaveIntoTheCurrentConversation() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        fixture.model.notes = store
        _ = await conversation(fixture)
        await fixture.model.toggleAnswerNote(AskMessage(id: "foreign", role: "assistant", text: "Other chat", createdAt: Date()))
        await fixture.model.toggleAnswerNote(AskMessage(id: "question", role: "user", text: "Question", createdAt: Date()))
        #expect(try store.count(.all) == 0)
    }

    @Test func launcherUnsaveIsRecoverableAndTrashedNotesCanBeSavedAgain() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let store = makeTestNotes()
        fixture.model.notes = store
        let draft = AskNoteDraft(command: "Explain", keyword: "ex", input: "Topic", body: "Answer")
        let first = try #require(await fixture.model.saveLauncherNote(draft))
        await fixture.model.toggleLauncherNote(draft)
        #expect(try store.note(id: first)?.isDeleted == true && fixture.model.launcherNote == nil)
        await fixture.model.toggleLauncherNote(draft)
        #expect(try store.count(.all) == 1 && store.count(.trash) == 1)
        let saved = try #require(fixture.model.launcherNote?.id)
        try store.trash(ids: [saved], at: Date())
        await fixture.model.toggleLauncherNote(draft)
        #expect(try store.count(.all) == 1 && store.count(.trash) == 2)
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
        await fixture.model.toggleAnswerNote(answer)
        #expect(fixture.model.answerNoteIDs.isEmpty)
        #expect(fixture.model.commandFeedback == L("ask.notes.storageUnavailable"))
        let draft = AskNoteDraft(command: "Explain", keyword: "ex", input: "Topic", body: "Answer")
        #expect(await fixture.model.saveLauncherNote(draft) == nil && fixture.model.launcherNote == nil)
        #expect(fixture.model.commandFeedback == L("ask.notes.storageUnavailable"))
    }
}
