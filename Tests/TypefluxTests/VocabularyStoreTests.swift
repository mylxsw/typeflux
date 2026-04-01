import XCTest
@testable import Typeflux

final class VocabularyStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "vocabulary.entries")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "vocabulary.entries")
        super.tearDown()
    }

    func testAddPostsVocabularyStoreDidChangeNotification() {
        let expectation = expectation(forNotification: .vocabularyStoreDidChange, object: nil) { notification in
            let entries = notification.userInfo?["entries"] as? [VocabularyEntry]
            return entries?.map(\.term) == ["SeedASR"]
        }

        _ = VocabularyStore.add(term: "SeedASR", source: .automatic)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(VocabularyStore.load().map(\.term), ["SeedASR"])
    }

    @MainActor
    func testStudioViewModelRefreshesVocabularyAfterExternalStoreWrite() {
        let settingsStore = SettingsStore()
        let historyStore = InMemoryHistoryStore()
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: historyStore,
            initialSection: .vocabulary
        )

        XCTAssertTrue(viewModel.vocabularyEntries.isEmpty)

        _ = VocabularyStore.add(term: "Qwen3-ASR", source: .automatic)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(viewModel.vocabularyEntries.map(\.term), ["Qwen3-ASR"])
        XCTAssertEqual(viewModel.vocabularyEntries.first?.source, .automatic)
    }
}

private final class InMemoryHistoryStore: HistoryStore {
    func save(record: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord] { [] }
    func record(id: UUID) -> HistoryRecord? { nil }
    func delete(id: UUID) {}
    func purge(olderThanDays days: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: "/tmp/typeflux-history.md") }
}
