import Foundation
import Testing
@testable import Typeflux

struct AskHistoryCacheTests {
    private func conversation(_ id: String = "history", revision: Int64 = 1) -> AskConversation {
        .init(id: id, title: "History", revision: revision, updatedAt: Date(timeIntervalSince1970: 100),
              messages: [.init(id: "message", role: "user", text: String(repeating: "x", count: 1_000_000),
                               createdAt: Date(timeIntervalSince1970: 100))], kind: "work")
    }

    @Test func summariesSurviveRestartAndTrackEditsAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cache.sqlite")
        let cache = try AskConversationCache(url: url)
        var value = conversation()
        try await cache.save(value, owner: "owner")
        let summary = try #require(await cache.read(table: "ask_summaries", id: value.id, owner: "owner"))
        #expect(summary.count < 1024)
        let restarted = try AskConversationCache(url: url)
        #expect(try await restarted.list(owner: "owner") == [AskConversationSummary(value)])
        #expect(try await restarted.list(owner: "other").isEmpty)
        value.title = "Renamed"; value.titleRevision = 1; value.revision = 2
        try await restarted.save(value, owner: "owner")
        #expect(try await cache.list(owner: "owner").first?.title == "Renamed")
        // A stale response cannot overwrite the newer list metadata.
        try await cache.save(conversation(), owner: "owner")
        #expect(try await cache.list(owner: "owner").first?.title == "Renamed")
        try await cache.delete(id: value.id, owner: "owner")
        #expect(try await restarted.list(owner: "owner").isEmpty)
        #expect(try await restarted.read(table: "ask_summaries", id: value.id, owner: "owner") == nil)
    }

    @Test func olderRowsAreBackfilledAndLegacyWritesInvalidateTheSummary() async throws {
        let cache = try AskConversationCache.inMemory()
        let id = UUID().uuidString.lowercased()
        var value = conversation(id)
        let oldData = try AskCoding.encoder().encode(value)
        try await cache.write(table: "ask_cache", id: id.uppercased(), owner: "owner", data: oldData)
        value.revision = 2; value.title = "Newest"
        try await cache.write(table: "ask_cache", id: id, owner: "owner", data: AskCoding.encoder().encode(value))
        #expect(try await cache.list(owner: "owner") == [AskConversationSummary(value)])
        #expect(try await cache.read(table: "ask_summaries", id: id.uppercased(), owner: "owner") != nil)
        #expect(try await cache.read(table: "ask_summaries", id: id, owner: "owner") != nil)
        value.revision = 3; value.title = "Legacy update"
        try await cache.write(table: "ask_cache", id: id, owner: "owner", data: AskCoding.encoder().encode(value))
        #expect(try await cache.read(table: "ask_summaries", id: id, owner: "owner") == nil)
        #expect(try await cache.list(owner: "owner") == [AskConversationSummary(value)])
        try await cache.delete(id: id, owner: "owner")
        #expect(try await cache.list(owner: "owner").isEmpty)
    }

    @Test func summaryWriteFailureRollsBackTheConversation() async throws {
        let cache = try AskConversationCache.inMemory()
        try await cache.execute("""
            CREATE TRIGGER fail_summary BEFORE INSERT ON ask_summaries
            BEGIN SELECT RAISE(ABORT,'fixture'); END;
            """, strings: [])
        await #expect(throws: (any Error).self) { try await cache.save(conversation(), owner: "owner") }
        #expect(try await cache.load(id: "history", owner: "owner") == nil)
        try await cache.execute("DROP TRIGGER fail_summary", strings: [])
        try await cache.save(conversation(), owner: "owner")
        #expect(try await cache.list(owner: "owner").count == 1)
    }
}
