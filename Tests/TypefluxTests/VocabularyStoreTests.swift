import AppKit
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

    @MainActor
    func testVocabularyImportConfirmationAlertUsesExpectedLocalizedContent() {
        let alert = StudioViewModel.makeVocabularyImportConfirmationAlert(
            subject: "typeflux-vocabulary.json",
            itemCount: 18,
        )

        XCTAssertEqual(alert.messageText, L("vocabulary.importDialog.title"))
        XCTAssertEqual(
            alert.informativeText,
            L("vocabulary.importDialog.message", 18, "typeflux-vocabulary.json"),
        )
        XCTAssertEqual(alert.buttons.map(\.title), [
            L("vocabulary.importDialog.confirm"),
            L("common.cancel"),
        ])
    }

    @MainActor
    func testVocabularyImportConfirmationAlertSupportsExternalSourceNames() {
        let alert = StudioViewModel.makeVocabularyImportConfirmationAlert(
            subject: VocabularySource.claude.displayName,
            itemCount: 12,
        )

        XCTAssertEqual(
            alert.informativeText,
            L("vocabulary.importDialog.message", 12, VocabularySource.claude.displayName),
        )
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

    func testExportDataRoundTripsEntries() throws {
        let entries = [
            VocabularyEntry(term: "TypefluxCloud", source: .manual, occurrenceCount: 3),
            VocabularyEntry(term: "Qwen3-ASR", source: .claude, occurrenceCount: 2),
        ]
        VocabularyStore.save(entries)

        let data = try VocabularyStore.exportData()
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: String]]

        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(Set(decoded?.first?.keys ?? []), Set(["term", "source"]))
        XCTAssertTrue(decoded?.contains(where: { $0["term"] == "TypefluxCloud" && $0["source"] == "manual" }) == true)
        XCTAssertTrue(decoded?.contains(where: { $0["term"] == "Qwen3-ASR" && $0["source"] == "claude" }) == true)
    }

    func testImportEntriesSupportsPlainTextLists() throws {
        let data = """
        Typeflux
        Qwen3-ASR
        Typeflux
        """
        .data(using: .utf8)!

        let result = try VocabularyStore.importEntries(from: data)

        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(Set(result.entries.map(\.term)), Set(["Typeflux", "Qwen3-ASR"]))
    }

    func testImportEntriesSupportsSourceAndTermJSONPayload() throws {
        let data = """
        [
          { "term": "WhisperKit", "source": "codex", "createdAt": 0, "occurrenceCount": 9 },
          { "term": "TypefluxCloud", "source": "manual", "id": "ignored" }
        ]
        """.data(using: .utf8)!

        let result = try VocabularyStore.importEntries(from: data)

        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.entries.first(where: { $0.term == "WhisperKit" })?.occurrenceCount, 1)
        XCTAssertEqual(result.entries.first(where: { $0.term == "WhisperKit" })?.source, .codex)
        XCTAssertEqual(result.entries.first(where: { $0.term == "TypefluxCloud" })?.source, .manual)
    }

    func testImportEntriesUpgradesExistingAutomaticTermToManualWithoutInflatingCount() throws {
        VocabularyStore.save([
            VocabularyEntry(term: "TypefluxCloud", source: .automatic, occurrenceCount: 2),
        ])

        // Exercises the `[String]` JSON-array decode path used for simple bulk imports.
        let data = """
        ["TypefluxCloud"]
        """
        .data(using: .utf8)!
        let result = try VocabularyStore.importEntries(from: data, defaultSource: .manual)

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.entries.first?.source, .manual)
        XCTAssertEqual(result.entries.first?.occurrenceCount, 2)
    }

    func testImportEntriesUpdatesExternalSourceToLatestImport() throws {
        VocabularyStore.save([
            VocabularyEntry(term: "WhisperKit", source: .claude, occurrenceCount: 2),
        ])

        let result = VocabularyStore.importTerms(["WhisperKit"], source: .codex)

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.entries.first?.source, .codex)
        XCTAssertEqual(result.entries.first?.occurrenceCount, 2)
    }

    func testPreviewImportItemsDeduplicatesTermsCaseInsensitively() throws {
        let data = """
        [
          { "term": "TypefluxCloud", "source": "manual" },
          { "term": "typefluxcloud", "source": "codex" },
          { "term": "Qwen3-ASR", "source": "claude" }
        ]
        """.data(using: .utf8)!

        let items = try VocabularyStore.previewImportItems(from: data)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first(where: { $0.term == "TypefluxCloud" })?.source, .manual)
        XCTAssertEqual(items.first(where: { $0.term == "Qwen3-ASR" })?.source, .claude)
    }

    func testImportEntriesThrowsUnsupportedFormatForMalformedBinaryPayload() {
        let malformed = Data([0xFF, 0xD8, 0x00, 0x80])

        XCTAssertThrowsError(try VocabularyStore.importEntries(from: malformed)) { error in
            XCTAssertEqual(error as? VocabularyImportError, .unsupportedFormat)
        }
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
        XCTAssertEqual(VocabularySource.claude.rawValue, "claude")
        XCTAssertEqual(VocabularySource.codex.rawValue, "codex")
    }

    // MARK: - occurrenceCount + ranking

    func testAddInitialTermHasOccurrenceCountOne() {
        let entries = VocabularyStore.add(term: "SeedASR", source: .manual)
        XCTAssertEqual(entries.first?.occurrenceCount, 1)
    }

    func testAddDuplicateBumpsOccurrenceCountInsteadOfInsertingNewEntry() {
        _ = VocabularyStore.add(term: "SeedASR", source: .manual)
        _ = VocabularyStore.add(term: "SeedASR", source: .automatic)
        let entries = VocabularyStore.add(term: "seedasr", source: .automatic) // case-insensitive
        XCTAssertEqual(entries.filter { $0.term.lowercased() == "seedasr" }.count, 1)
        XCTAssertEqual(entries.first(where: { $0.term.lowercased() == "seedasr" })?.occurrenceCount, 3)
    }

    func testAddPreservesOriginalCreatedAtAndTermWhenBumping() {
        let initial = VocabularyStore.add(term: "Typeflux", source: .manual)
        let originalID = initial.first?.id
        let originalCreatedAt = initial.first?.createdAt

        // Sleep a moment so createdAt would differ if the record were replaced.
        Thread.sleep(forTimeInterval: 0.01)
        let after = VocabularyStore.add(term: "Typeflux", source: .automatic)
        XCTAssertEqual(after.first?.id, originalID)
        XCTAssertEqual(after.first?.createdAt, originalCreatedAt)
        XCTAssertEqual(after.first?.term, "Typeflux")
    }

    func testIncrementOccurrencesBumpsMatchingTerms() {
        _ = VocabularyStore.add(term: "SeedASR", source: .manual)
        _ = VocabularyStore.add(term: "向量", source: .manual)
        _ = VocabularyStore.add(term: "GPT", source: .manual)

        let bumped = VocabularyStore.incrementOccurrences(
            in: "测试 SeedASR 与 向量 数据库",
        )
        XCTAssertEqual(Set(bumped), Set(["SeedASR", "向量"]))

        let entries = VocabularyStore.load()
        let bySeed = entries.first(where: { $0.term == "SeedASR" })
        let byVector = entries.first(where: { $0.term == "向量" })
        let byGPT = entries.first(where: { $0.term == "GPT" })
        XCTAssertEqual(bySeed?.occurrenceCount, 2)
        XCTAssertEqual(byVector?.occurrenceCount, 2)
        XCTAssertEqual(byGPT?.occurrenceCount, 1)
    }

    func testIncrementOccurrencesEmptyTextIsNoOp() {
        _ = VocabularyStore.add(term: "SeedASR", source: .manual)
        let bumped = VocabularyStore.incrementOccurrences(in: "   ")
        XCTAssertTrue(bumped.isEmpty)
        XCTAssertEqual(VocabularyStore.load().first?.occurrenceCount, 1)
    }

    func testIncrementOccurrencesIsCaseInsensitive() {
        _ = VocabularyStore.add(term: "Typeflux", source: .manual)
        let bumped = VocabularyStore.incrementOccurrences(in: "I love typeflux!")
        XCTAssertEqual(bumped, ["Typeflux"])
        XCTAssertEqual(VocabularyStore.load().first?.occurrenceCount, 2)
    }

    func testActiveTermsSortedByCountThenCreatedAt() {
        _ = VocabularyStore.add(term: "Oldest", source: .manual)
        Thread.sleep(forTimeInterval: 0.01)
        _ = VocabularyStore.add(term: "Middle", source: .manual)
        Thread.sleep(forTimeInterval: 0.01)
        _ = VocabularyStore.add(term: "Newest", source: .manual)

        // Middle appears twice → highest count → first in ranking.
        _ = VocabularyStore.add(term: "Middle", source: .manual)

        let active = VocabularyStore.activeTerms()
        XCTAssertEqual(active.prefix(3).map { $0 }, ["Middle", "Newest", "Oldest"])
    }

    func testActiveTermsCapsAt100Entries() {
        var seeded: [VocabularyEntry] = []
        let baseDate = Date(timeIntervalSince1970: 100_000)
        for i in 0 ..< 150 {
            seeded.append(
                VocabularyEntry(
                    term: "Term\(String(format: "%03d", i))",
                    source: .manual,
                    createdAt: baseDate.addingTimeInterval(TimeInterval(i)),
                    occurrenceCount: 1,
                ),
            )
        }
        VocabularyStore.save(seeded)

        let active = VocabularyStore.activeTerms()
        XCTAssertEqual(active.count, 100)
        // Latest createdAt wins the tiebreak → Term149 is first.
        XCTAssertEqual(active.first, "Term149")
        // Term049 is the 100th most-recent; Term048 should have been dropped.
        XCTAssertTrue(active.contains("Term050"))
        XCTAssertFalse(active.contains("Term049"))
    }

    func testAllTermsReturnsEverythingUnlimited() {
        var seeded: [VocabularyEntry] = []
        for i in 0 ..< 120 {
            seeded.append(
                VocabularyEntry(
                    term: "Term\(i)",
                    source: .manual,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + i)),
                    occurrenceCount: 1,
                ),
            )
        }
        VocabularyStore.save(seeded)
        XCTAssertEqual(VocabularyStore.allTerms().count, 120)
    }

    func testVocabularyEntryDecodesWithoutOccurrenceCountFieldAsOne() throws {
        // Legacy on-disk payload — simulates entries saved by pre-ranking builds.
        let legacyJSON = """
        [
          {
            "id": "\(UUID().uuidString)",
            "term": "Legacy",
            "source": "manual",
            "createdAt": 1000
          }
        ]
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoder = JSONDecoder()
        let entries = try decoder.decode([VocabularyEntry].self, from: data)
        XCTAssertEqual(entries.first?.occurrenceCount, 1)
    }
}
