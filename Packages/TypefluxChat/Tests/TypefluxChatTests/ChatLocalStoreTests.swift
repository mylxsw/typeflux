import Foundation
@testable import TypefluxChat
import XCTest

final class ChatLocalStoreTests: XCTestCase {
    private func conversation(_ id: String, revision: Int64, text: String = "Hello",
                              updated: TimeInterval = 1000) -> ChatConversation {
        ChatConversation(id: id, title: "Title \(revision)", revision: revision,
                         updatedAt: Date(timeIntervalSince1970: updated),
                         messages: [ChatMessage(id: "m\(revision)", role: "user", text: text,
                                                createdAt: Date(timeIntervalSince1970: updated))])
    }

    func testCloudCopiesOnlyMoveForwardByRevision() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.save(conversation("c1", revision: 5, text: "newer"), storage: .cloud, owner: "a")
        try await store.save(conversation("c1", revision: 3, text: "older"), storage: .cloud, owner: "a")
        let kept = try await store.conversation(id: "c1", owner: "a")
        XCTAssertEqual(kept?.messages.first?.text, "newer")
        try await store.save(conversation("c1", revision: 6, text: "latest"), storage: .cloud, owner: "a")
        let latest = try await store.conversation(id: "c1", owner: "a")
        XCTAssertEqual(latest?.revision, 6)
    }

    func testLocalConversationsAlwaysTakeTheLatestWrite() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.save(conversation("l1", revision: 5), storage: .local, owner: "local", modelRef: "local:p/m")
        try await store.save(conversation("l1", revision: 1, text: "edited"), storage: .local, owner: "local")
        let value = try await store.conversation(id: "l1", owner: "local")
        XCTAssertEqual(value?.messages.first?.text, "edited")
        // A save without a model keeps the remembered one.
        let reference = try await store.modelRef(id: "l1", owner: "local")
        XCTAssertEqual(reference, "local:p/m")
    }

    func testOwnersAreIsolatedAndDeletedTogether() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.save(conversation("c1", revision: 1), storage: .cloud, owner: "a")
        try await store.save(conversation("c2", revision: 1), storage: .cloud, owner: "b")
        try await store.saveDraft(ChatDraft(text: "draft"), id: "new", owner: "a")
        try await store.saveValue(["x"], key: "catalog", owner: "a")
        let missing = try await store.conversation(id: "c1", owner: "b")
        XCTAssertNil(missing)
        try await store.deleteAll(owner: "a")
        let gone = try await store.summaries(owner: "a")
        XCTAssertTrue(gone.isEmpty)
        let draft = try await store.draft(id: "new", owner: "a")
        XCTAssertNil(draft)
        let value = try await store.value([String].self, key: "catalog", owner: "a")
        XCTAssertNil(value)
        let other = try await store.summaries(owner: "b")
        XCTAssertEqual(other.map(\.summary.id), ["c2"])
    }

    func testFirstPageRemovesConversationsDeletedElsewhere() async throws {
        let store = try ChatLocalStore.inMemory()
        let old = ChatConversationSummary(id: "old", title: "Old", updatedAt: Date(timeIntervalSince1970: 100))
        let gone = ChatConversationSummary(id: "gone", title: "Gone", updatedAt: Date(timeIntervalSince1970: 300))
        let kept = ChatConversationSummary(id: "kept", title: "Kept", updatedAt: Date(timeIntervalSince1970: 200))
        try await store.syncCloudPage([gone, kept, old], owner: "a", firstPage: true, complete: false)
        try await store.save(conversation("private", revision: 1, updated: 250), storage: .local, owner: "a")
        // "gone" is newer than the page's oldest item but missing: deleted on another device.
        // "old" is older than the page, so it may be on a later page and stays.
        try await store.syncCloudPage([kept], owner: "a", firstPage: true, complete: false)
        var ids = try await store.summaries(owner: "a").map(\.summary.id)
        XCTAssertEqual(Set(ids), ["kept", "old", "private"])
        try await store.syncCloudPage([kept], owner: "a", firstPage: true, complete: true)
        ids = try await store.summaries(owner: "a").map(\.summary.id)
        XCTAssertEqual(ids, ["private", "kept"])
        // Later pages only add.
        try await store.syncCloudPage([old], owner: "a", firstPage: false, complete: false)
        ids = try await store.summaries(owner: "a").map(\.summary.id)
        XCTAssertEqual(ids, ["private", "kept", "old"])
    }

    func testSummariesReportStorageContentAndModel() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.syncCloudPage([ChatConversationSummary(id: "c1", title: "Listed",
                                                               updatedAt: Date(timeIntervalSince1970: 50))],
                                      owner: "a", firstPage: false, complete: false)
        try await store.save(conversation("l1", revision: 1, updated: 60), storage: .local, owner: "a",
                             modelRef: "local:p/m")
        let summaries = try await store.summaries(owner: "a")
        XCTAssertEqual(summaries.map(\.storage), [.local, .cloud])
        XCTAssertEqual(summaries.map(\.hasContent), [true, false])
        XCTAssertEqual(summaries.first?.modelRef, "local:p/m")
        try await store.setModelRef("cloud:fast", id: "c1", owner: "a")
        let reference = try await store.modelRef(id: "c1", owner: "a")
        XCTAssertEqual(reference, "cloud:fast")
        let unknown = try await store.modelRef(id: "missing", owner: "a")
        XCTAssertNil(unknown)
    }

    func testPruneKeepsTitlesButDropsOlderContent() async throws {
        let store = try ChatLocalStore.inMemory()
        for index in 0 ..< 4 {
            try await store.save(conversation("c\(index)", revision: 2, updated: TimeInterval(index)),
                                 storage: .cloud, owner: "a")
        }
        try await store.save(conversation("l", revision: 1, updated: -1), storage: .local, owner: "a")
        let before = try await store.contentSize(owner: "a")
        try await store.prune(owner: "a", keep: 2)
        let summaries = try await store.summaries(owner: "a")
        XCTAssertEqual(summaries.filter(\.hasContent).map(\.summary.id), ["c3", "c2", "l"])
        let after = try await store.contentSize(owner: "a")
        XCTAssertLessThan(after, before)
        // A pruned conversation accepts any snapshot again, even an older revision.
        try await store.save(conversation("c0", revision: 1, text: "reloaded"), storage: .cloud, owner: "a")
        let reloaded = try await store.conversation(id: "c0", owner: "a")
        XCTAssertEqual(reloaded?.messages.first?.text, "reloaded")
    }

    func testStorageNeverChangesForAnExistingConversation() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.save(conversation("x", revision: 1, text: "private"), storage: .local, owner: "a")
        try await store.save(conversation("x", revision: 9, text: "cloud"), storage: .cloud, owner: "a")
        let value = try await store.conversation(id: "x", owner: "a")
        XCTAssertEqual(value?.messages.first?.text, "private")
    }

    func testDraftsAndDeletion() async throws {
        let store = try ChatLocalStore.inMemory()
        try await store.saveDraft(ChatDraft(text: "hi", image: "data:image/png;base64,AA"), id: "c1", owner: "a")
        var draft = try await store.draft(id: "c1", owner: "a")
        XCTAssertEqual(draft, ChatDraft(text: "hi", image: "data:image/png;base64,AA"))
        try await store.saveDraft(ChatDraft(text: "  "), id: "c1", owner: "a")
        draft = try await store.draft(id: "c1", owner: "a")
        XCTAssertNil(draft)
        try await store.saveDraft(ChatDraft(text: "again"), id: "c1", owner: "a")
        try await store.save(conversation("c1", revision: 1), storage: .cloud, owner: "a")
        try await store.delete(id: "c1", owner: "a")
        draft = try await store.draft(id: "c1", owner: "a")
        XCTAssertNil(draft)
        let value = try await store.conversation(id: "c1", owner: "a")
        XCTAssertNil(value)
    }

    func testValuesRoundTripWithTheirTime() async throws {
        let store = try ChatLocalStore.inMemory()
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let catalog = [ChatModel(id: "fast", name: "Fast", vision: true, pricing: ["input": "1.5"],
                                 reasoning: true, reasoningEfforts: ["low", "high"], contextWindowTokens: 1000,
                                 maxOutputTokens: 100)]
        try await store.saveValue(catalog, key: "catalog", owner: "a", at: saved)
        let cached = try await store.value([ChatModel].self, key: "catalog", owner: "a")
        XCTAssertEqual(cached?.value, catalog)
        XCTAssertEqual(cached?.savedAt, saved)
        try await store.deleteValue(key: "catalog", owner: "a")
        let removed = try await store.value([ChatModel].self, key: "catalog", owner: "a")
        XCTAssertNil(removed)
    }

    func testFileStorePersistsAcrossConnections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/store.sqlite")
        do {
            let store = try ChatLocalStore(url: url)
            try await store.save(conversation("c1", revision: 1), storage: .local, owner: "local")
        }
        let reopened = try ChatLocalStore(url: url)
        let value = try await reopened.conversation(id: "c1", owner: "local")
        XCTAssertEqual(value?.id, "c1")
    }

    func testOpeningAnInvalidPathFails() {
        XCTAssertThrowsError(try ChatLocalStore(url: URL(fileURLWithPath: "/dev/null/not-a-directory/x.sqlite")))
    }
}
