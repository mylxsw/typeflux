@testable import Typeflux
import Foundation
import XCTest

final class RecentInputMemoryTests: XCTestCase {
    func testSettingsEnableAllAppsExceptExplicitExclusions() {
        let name = "RecentInputMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)

        XCTAssertFalse(settings.recentInputMemoryAllowed(for: "app.one"))
        settings.recentInputMemoryEnabled = true
        XCTAssertTrue(settings.recentInputMemoryAllowed(for: "app.one"))
        XCTAssertTrue(settings.recentInputMemoryAllowed(for: "app.two"))
        settings.recentInputMemoryExcludedApps = ["app.one"]
        XCTAssertFalse(settings.recentInputMemoryAllowed(for: "app.one"))
        XCTAssertTrue(settings.recentInputMemoryAllowed(for: "app.two"))
    }

    func testBrowserScopesSeparateAppsSitesAndConversationURLs() throws {
        let first = try XCTUnwrap(RecentInputMemoryScope.browserScope(
            bundleIdentifier: "com.google.Chrome", url: URL(string: "https://chat.example/c/1")!
        ))
        let otherChat = try XCTUnwrap(RecentInputMemoryScope.browserScope(
            bundleIdentifier: "com.google.Chrome", url: URL(string: "https://chat.example/c/2")!
        ))
        let otherBrowser = try XCTUnwrap(RecentInputMemoryScope.browserScope(
            bundleIdentifier: "com.microsoft.edgemac", url: URL(string: "https://chat.example/c/1")!
        ))
        XCTAssertNotEqual(first, otherChat)
        XCTAssertNotEqual(first, otherBrowser)
        XCTAssertFalse(first.key.contains("chat.example"))
    }

    func testStoreReplacesCorrectionAndSeparatesScopes() {
        XCTAssertEqual(RecentInputMemoryStore.lifetime, 24 * 60 * 60)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RecentInputMemoryStore(fileURL: file)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 10_000)

        store.upsert(id: id, appIdentifier: "app.one", scope: "app.one", text: "initial", at: now)
        store.upsert(id: id, appIdentifier: "app.one", scope: "app.one", text: "corrected", at: now)
        store.upsert(id: UUID(), appIdentifier: "app.two", scope: "app.two", text: "other", at: now)

        XCTAssertEqual(store.recent(scope: "app.one", at: now), ["corrected"])
        XCTAssertEqual(store.recent(scope: "app.two", at: now), ["other"])
        XCTAssertEqual(store.recent(scope: "app.one", at: now.addingTimeInterval(4 * 60 * 60)), ["corrected"])
        XCTAssertEqual(
            store.recent(scope: "app.one", at: now.addingTimeInterval(RecentInputMemoryStore.lifetime - 1)),
            ["corrected"]
        )
        XCTAssertTrue(store.recent(scope: "app.one", at: now.addingTimeInterval(RecentInputMemoryStore.lifetime)).isEmpty)
    }

    func testClearPreventsPendingObservationFromRestoringMemory() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RecentInputMemoryStore(fileURL: file)
        let generation = store.currentGeneration()
        store.clear()
        XCTAssertFalse(store.upsert(
            id: UUID(), appIdentifier: "app.one", scope: "app.one",
            text: "stale", expectedGeneration: generation
        ))
        XCTAssertTrue(store.recent(scope: "app.one").isEmpty)
    }

    func testBrowserAppLimitAppliesAcrossSites() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RecentInputMemoryStore(fileURL: file)
        let now = Date(timeIntervalSince1970: 10_000)
        for index in 0 ... 20 {
            store.upsert(
                id: UUID(), appIdentifier: "browser", scope: "site-\(index)",
                text: "message-\(index)", at: now.addingTimeInterval(Double(index))
            )
        }
        XCTAssertTrue(store.recent(scope: "site-0", at: now.addingTimeInterval(21)).isEmpty)
        XCTAssertEqual(store.recent(scope: "site-20", at: now.addingTimeInterval(21)), ["message-20"])
    }

    func testManagementCanListDeleteOneAndClearOneApp() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RecentInputMemoryStore(fileURL: file)
        let first = UUID()
        let second = UUID()
        let other = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        store.upsert(id: first, appIdentifier: "app.one", scope: "one", text: "first", at: now)
        store.upsert(id: second, appIdentifier: "app.one", scope: "one", text: "second", at: now.addingTimeInterval(1))
        store.upsert(id: other, appIdentifier: "app.two", scope: "two", text: "other", at: now)

        XCTAssertEqual(store.list(at: now.addingTimeInterval(2)).count, 3)
        let generation = store.currentGeneration()
        store.delete(id: second)
        XCTAssertEqual(Set(store.list(at: now.addingTimeInterval(2)).map(\.id)), Set([first, other]))
        XCTAssertFalse(store.upsert(
            id: second, appIdentifier: "app.one", scope: "one", text: "restored",
            expectedGeneration: generation
        ))
        store.clear(appIdentifier: "app.one")
        XCTAssertEqual(store.list(at: now.addingTimeInterval(2)).map(\.id), [other])
    }

    func testExcerptKeepsInsertedRegionAndShortSurroundingContext() {
        let before = String(repeating: "a", count: 200)
        let after = String(repeating: "z", count: 200)
        let captured = RecentInputMemoryExcerpt.extract(
            insertedText: "type flux",
            from: before + "type flux" + after
        )
        XCTAssertNotNil(captured)
        let body = RecentInputMemoryExcerpt.updatedBody(
            in: before + "Typeflux" + after,
            leading: captured?.leading ?? "",
            trailing: captured?.trailing ?? ""
        )
        XCTAssertEqual(body, "Typeflux")
        let excerpt = RecentInputMemoryExcerpt.excerpt(
            body: body ?? "", leading: captured?.leading ?? "", trailing: captured?.trailing ?? ""
        )
        XCTAssertEqual(excerpt?.count, 208)
        XCTAssertTrue(excerpt?.contains("Typeflux") == true)
    }

    func testPromptTreatsMemoryAsContextOnly() {
        let request = LLMRewriteRequest(
            mode: .rewriteTranscript,
            sourceText: "继续说这个",
            spokenInstruction: nil,
            personaPrompt: nil,
            recentInputMemory: ["之前讨论的是项目进度"]
        )
        let prompts = PromptCatalog.rewritePrompts(for: request)
        XCTAssertTrue(prompts.user.contains("之前讨论的是项目进度"))
        XCTAssertTrue(prompts.user.contains("Current speech and explicit instructions take priority"))
    }
}
