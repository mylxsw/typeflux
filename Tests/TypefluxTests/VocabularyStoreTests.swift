@testable import Typeflux
import XCTest

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
            initialSection: .vocabulary,
        )

        XCTAssertTrue(viewModel.vocabularyEntries.isEmpty)

        _ = VocabularyStore.add(term: "Qwen3-ASR", source: .automatic)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(viewModel.vocabularyEntries.map(\.term), ["Qwen3-ASR"])
        XCTAssertEqual(viewModel.vocabularyEntries.first?.source, .automatic)
    }
}

private final class InMemoryHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}

// MARK: - Extended VocabularyStore tests

final class VocabularyStoreExtendedTests: XCTestCase {
    private let defaultsKey = "vocabulary.entries"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    // MARK: - load

    func testLoadReturnsEmptyArrayWhenNoData() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let entries = VocabularyStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func testLoadReturnsPreviouslySavedEntries() {
        VocabularyStore.save([VocabularyEntry(term: "SwiftUI", source: .manual)])
        let loaded = VocabularyStore.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.term, "SwiftUI")
    }

    // MARK: - save

    func testSaveAndLoadRoundTrip() {
        let entries = [
            VocabularyEntry(term: "Combine", source: .manual),
            VocabularyEntry(term: "XCTest", source: .automatic),
        ]
        VocabularyStore.save(entries)
        let loaded = VocabularyStore.load()
        XCTAssertEqual(loaded.count, 2)
        let terms = Set(loaded.map(\.term))
        XCTAssertTrue(terms.contains("Combine"))
        XCTAssertTrue(terms.contains("XCTest"))
    }

    func testSaveDeduplicate() {
        let entries = [
            VocabularyEntry(term: "duplicate", source: .manual),
            VocabularyEntry(term: "duplicate", source: .manual),
        ]
        VocabularyStore.save(entries)
        let loaded = VocabularyStore.load()
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - add

    func testAddInsertsTerm() {
        let result = VocabularyStore.add(term: "WhisperKit", source: .manual)
        XCTAssertTrue(result.contains(where: { $0.term == "WhisperKit" }))
    }

    func testAddDoesNotDuplicateExistingTerm() {
        _ = VocabularyStore.add(term: "MyTerm", source: .manual)
        let result = VocabularyStore.add(term: "MyTerm", source: .automatic)
        let matchingTerms = result.filter { $0.term.lowercased() == "myterm" }
        XCTAssertEqual(matchingTerms.count, 1)
    }

    func testAddIgnoresEmptyTerm() {
        let result = VocabularyStore.add(term: "  ", source: .manual)
        XCTAssertTrue(result.isEmpty)
    }

    func testAddNormalizesWhitespace() {
        let result = VocabularyStore.add(term: "  Typeflux  ", source: .manual)
        XCTAssertEqual(result.first?.term, "Typeflux")
    }

    // MARK: - remove

    func testRemoveDeletesEntry() throws {
        let result = VocabularyStore.add(term: "DeleteMe", source: .manual)
        let id = try XCTUnwrap(result.first(where: { $0.term == "DeleteMe" })?.id)
        let afterRemove = VocabularyStore.remove(id: id)
        XCTAssertFalse(afterRemove.contains(where: { $0.term == "DeleteMe" }))
    }

    func testRemoveNonExistentIDDoesNotCrash() {
        _ = VocabularyStore.add(term: "KeepMe", source: .manual)
        let afterRemove = VocabularyStore.remove(id: UUID())
        XCTAssertEqual(afterRemove.count, 1)
        XCTAssertEqual(afterRemove.first?.term, "KeepMe")
    }

    // MARK: - activeTerms

    func testActiveTermsReturnsAllTerms() {
        _ = VocabularyStore.add(term: "TermA", source: .manual)
        _ = VocabularyStore.add(term: "TermB", source: .automatic)
        let terms = VocabularyStore.activeTerms()
        XCTAssertTrue(terms.contains("TermA"))
        XCTAssertTrue(terms.contains("TermB"))
    }

    func testActiveTermsIsEmptyInitially() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        XCTAssertTrue(VocabularyStore.activeTerms().isEmpty)
    }

    // MARK: - VocabularyEntry

    func testVocabularyEntryEquality() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        let e1 = VocabularyEntry(id: id, term: "test", source: .manual, createdAt: date)
        let e2 = VocabularyEntry(id: id, term: "test", source: .manual, createdAt: date)
        XCTAssertEqual(e1, e2)
    }

    func testVocabularyEntryInequality() {
        let e1 = VocabularyEntry(term: "term-a", source: .manual)
        let e2 = VocabularyEntry(term: "term-b", source: .manual)
        XCTAssertNotEqual(e1, e2)
    }

    func testVocabularySourceDisplayNamesAreNonEmpty() {
        for source in VocabularySource.allCases {
            XCTAssertFalse(source.displayName.isEmpty)
        }
    }

    func testVocabularySourceRawValues() {
        XCTAssertEqual(VocabularySource.manual.rawValue, "manual")
        XCTAssertEqual(VocabularySource.automatic.rawValue, "automatic")
    }
}
