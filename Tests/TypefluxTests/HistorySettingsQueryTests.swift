@testable import Typeflux
import XCTest

final class HistorySettingsQueryTests: XCTestCase {
    func testSparseFilterScansPastFirstPageAndRetainsRawCursor() throws {
        try withStore { store in
            let base = Date()
            for index in 0 ..< 245 {
                store.save(record: HistoryRecord(date: base.addingTimeInterval(Double(-index)),
                                                 transcriptText: "record \(index)",
                                                 errorMessage: index >= 105 && index % 3 == 0 ? "failed" : nil))
            }
            let first = HistorySettingsQuery.page(store: store, query: nil, filter: .failures, limit: 20, offset: 0)
            XCTAssertEqual(first.records.count, 20)
            XCTAssertEqual(first.records.first?.transcriptText, "record 105")
            XCTAssertEqual(first.nextOffset, 163)
            XCTAssertTrue(first.hasMore)
            let second = HistorySettingsQuery.page(store: store, query: nil, filter: .failures,
                                                   limit: 20, offset: first.nextOffset)
            XCTAssertEqual(second.records.first?.transcriptText, "record 165")
            let third = HistorySettingsQuery.page(store: store, query: nil, filter: .failures,
                                                  limit: 20, offset: second.nextOffset)
            let ids = (first.records + second.records + third.records).map(\.id)
            XCTAssertEqual(ids.count, 47)
            XCTAssertEqual(Set(ids).count, 47)
            XCTAssertFalse(third.hasMore)
        }
    }

    func testSearchAndFilterComposeAndNoMatchesReachEnd() throws {
        try withStore { store in
            store.save(record: HistoryRecord(
                date: Date(),
                audioFilePath: "/tmp/fixture.wav",
                transcriptText: "alpha audio"
            ))
            store.save(record: HistoryRecord(date: Date(), transcriptText: "beta text"))
            store.save(record: HistoryRecord(date: Date(), transcriptText: "alpha failure", processingStatus: .failed))
            let audio = HistorySettingsQuery.page(store: store, query: "alpha", filter: .audio, limit: 1, offset: 0)
            XCTAssertEqual(audio.records.map(\.transcriptText), ["alpha audio"])
            let failed = HistorySettingsQuery.page(store: store, query: "alpha", filter: .failures, limit: 5, offset: 0)
            XCTAssertEqual(failed.records.map(\.transcriptText), ["alpha failure"])
            XCTAssertFalse(failed.hasMore)
            let empty = HistorySettingsQuery.page(store: store, query: "beta", filter: .audio, limit: 1, offset: 0)
            XCTAssertTrue(empty.records.isEmpty)
            XCTAssertEqual(empty.nextOffset, 1)
            XCTAssertFalse(empty.hasMore)
        }
    }

    func testAllFilterAndInvalidBounds() throws {
        try withStore { store in
            store.save(record: HistoryRecord(date: Date(), transcriptText: "first"))
            store.save(record: HistoryRecord(date: Date(), transcriptText: "second"))
            let first = HistorySettingsQuery.page(store: store, query: nil, filter: .all, limit: 1, offset: -10)
            XCTAssertEqual(first.records.count, 1)
            XCTAssertEqual(first.nextOffset, 1)
            XCTAssertTrue(first.hasMore)
            let end = HistorySettingsQuery.page(store: store, query: nil, filter: .all, limit: 1, offset: 2)
            XCTAssertTrue(end.records.isEmpty)
            XCTAssertFalse(end.hasMore)
            let invalid = HistorySettingsQuery.page(store: store, query: nil, filter: .all, limit: 0, offset: -1)
            XCTAssertEqual(invalid.nextOffset, 0)
            XCTAssertFalse(invalid.hasMore)
        }
    }

    func testPredicatesHandleMissingAndEmptyContent() {
        let empty = HistoryRecord(date: Date(), audioFilePath: "", transcriptText: "")
        XCTAssertTrue(HistorySettingsFilter.all.matches(empty))
        XCTAssertFalse(HistorySettingsFilter.audio.matches(empty))
        XCTAssertFalse(HistorySettingsFilter.text.matches(empty))
        XCTAssertFalse(HistorySettingsFilter.failures.matches(empty))
        XCTAssertTrue(HistorySettingsFilter.text.matches(HistoryRecord(date: Date(), postProcessedText: "final text")))
        XCTAssertTrue(HistorySettingsFilter.failures.matches(HistoryRecord(date: Date(), applyStatus: .failed)))
        XCTAssertFalse(HistorySettingsFilter.audio.matches(HistoryRecord(date: Date())))
        XCTAssertFalse(HistorySettingsFilter.text.matches(HistoryRecord(date: Date())))
    }

    private func withStore(_ check: (SQLiteHistoryStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try check(SQLiteHistoryStore(baseDir: root))
    }
}
