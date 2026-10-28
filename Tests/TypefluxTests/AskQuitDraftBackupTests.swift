import Foundation
import Testing
@testable import Typeflux

@Suite("Quit draft backup")
struct AskQuitDraftBackupTests {
    @Test func backupSurvivesReopeningWithoutOverwritingConversationDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let cache = try AskConversationCache(url: url)
        let original = AskDraft(text: "existing conversation draft")
        let backup = AskDraft(text: "unsent input")
        try await cache.saveDraft(original, key: "conversation", owner: "local")
        try await AskQuitDraftBackup.save(backup, owner: "local", key: "saved-chat:quit-test", url: url)
        let reopened = try AskConversationCache(url: url)
        #expect(try await reopened.draft(key: "conversation", owner: "local") == original)
        #expect(try await reopened.savedChatDrafts(owner: "local").contains { $0.draft == backup })
        #expect(try await reopened.savedChatDrafts(owner: "another-owner").isEmpty)
    }

    @Test func backupRejectsTemporaryDraftsAndUnboundKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        var temporary = AskDraft(text: "private temporary chat")
        temporary.temporary = true
        await #expect(throws: AskRecoveryError.self) {
            try await AskQuitDraftBackup.save(temporary, owner: "local", key: "saved-chat:quit-test", url: url)
        }
        await #expect(throws: AskRecoveryError.self) {
            try await AskQuitDraftBackup.save(.init(text: "text"), owner: "local", key: "conversation", url: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
