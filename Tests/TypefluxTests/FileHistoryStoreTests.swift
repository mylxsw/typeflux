import XCTest
@testable import Typeflux

final class FileHistoryStoreTests: XCTestCase {

    private var testDir: URL!
    private var store: FileHistoryStore!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = FileHistoryStore(baseDir: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        testDir = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        date: Date = Date(),
        transcriptText: String? = nil,
        mode: HistoryRecord.Mode = .dictation
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            date: date,
            mode: mode,
            transcriptText: transcriptText
        )
    }

    private func flush() {
        // Allow async queue operations to complete.
        let expectation = XCTestExpectation(description: "queue flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - save

    func testSaveInsertsNewRecord() {
        let record = makeRecord(transcriptText: "hello")
        store.save(record: record)
        flush()

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, record.id)
        XCTAssertEqual(list.first?.transcriptText, "hello")
    }

    func testSaveUpdatesExistingRecord() {
        let id = UUID()
        var record = makeRecord(id: id, transcriptText: "original")
        store.save(record: record)
        flush()

        record.transcriptText = "updated"
        store.save(record: record)
        flush()

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.transcriptText, "updated")
    }

    // MARK: - list

    func testListReturnsAllRecords() {
        store.save(record: makeRecord(transcriptText: "a"))
        store.save(record: makeRecord(transcriptText: "b"))
        store.save(record: makeRecord(transcriptText: "c"))
        flush()

        XCTAssertEqual(store.list().count, 3)
    }

    // MARK: - list(limit:offset:searchQuery:)

    func testListWithPagination() {
        let now = Date()
        for i in 0..<5 {
            store.save(record: makeRecord(date: now.addingTimeInterval(TimeInterval(i)), transcriptText: "item \(i)"))
            flush()
        }

        let page = store.list(limit: 2, offset: 1, searchQuery: nil)
        XCTAssertEqual(page.count, 2)
    }

    func testListWithSearchFiltering() {
        store.save(record: makeRecord(transcriptText: "Swift programming"))
        store.save(record: makeRecord(transcriptText: "Python scripting"))
        store.save(record: makeRecord(transcriptText: "Swift UI"))
        flush()

        let results = store.list(limit: 10, offset: 0, searchQuery: "Swift")
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - record(id:)

    func testRecordFindsExistingRecord() {
        let id = UUID()
        store.save(record: makeRecord(id: id, transcriptText: "find me"))
        flush()

        let found = store.record(id: id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.transcriptText, "find me")
    }

    func testRecordReturnsNilForUnknownID() {
        store.save(record: makeRecord(transcriptText: "something"))
        flush()

        XCTAssertNil(store.record(id: UUID()))
    }

    // MARK: - delete

    func testDeleteRemovesRecord() {
        let id = UUID()
        store.save(record: makeRecord(id: id, transcriptText: "delete me"))
        flush()

        store.delete(id: id)
        flush()

        XCTAssertNil(store.record(id: id))
        XCTAssertEqual(store.list().count, 0)
    }

    // MARK: - purge

    func testPurgeRemovesOldRecords() {
        let old = Date().addingTimeInterval(-10 * 24 * 3600)
        let recent = Date()

        store.save(record: makeRecord(date: old, transcriptText: "old"))
        store.save(record: makeRecord(date: recent, transcriptText: "recent"))
        flush()

        store.purge(olderThanDays: 5)
        flush()

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.transcriptText, "recent")
    }

    // MARK: - clear

    func testClearRemovesAllRecords() {
        store.save(record: makeRecord(transcriptText: "a"))
        store.save(record: makeRecord(transcriptText: "b"))
        flush()

        store.clear()
        flush()

        XCTAssertEqual(store.list().count, 0)
    }

    // MARK: - exportMarkdown

    func testExportMarkdownGeneratesFile() throws {
        store.save(record: makeRecord(
            transcriptText: "hello world",
            mode: .dictation
        ))
        flush()

        let url = try store.exportMarkdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("# Typeflux History"))
        XCTAssertTrue(content.contains("hello world"))
        XCTAssertTrue(content.contains("Mode: dictation"))
    }
}

// MARK: - Extended FileHistoryStore tests

extension FileHistoryStoreTests {

    func testSavePreservesAllFields() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 5000)
        let record = HistoryRecord(
            id: id,
            date: date,
            mode: .askAnswer,
            transcriptText: "transcript",
            personaPrompt: "formal",
            personaResultText: "Formal transcript.",
            errorMessage: nil,
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .succeeded
        )
        store.save(record: record)

        let found = store.record(id: id)
        XCTAssertEqual(found?.transcriptText, "transcript")
        XCTAssertEqual(found?.personaPrompt, "formal")
        XCTAssertEqual(found?.personaResultText, "Formal transcript.")
        XCTAssertEqual(found?.mode, .askAnswer)
    }

    func testListIsOrderedByDateDescending() {
        let now = Date()
        let oldest = makeRecord(date: now.addingTimeInterval(-100), transcriptText: "oldest")
        let newest = makeRecord(date: now.addingTimeInterval(100), transcriptText: "newest")
        store.save(record: oldest)
        store.save(record: newest)

        let list = store.list()
        XCTAssertEqual(list.first?.transcriptText, "newest")
        XCTAssertEqual(list.last?.transcriptText, "oldest")
    }

    func testListWithOffsetSkipsRecords() {
        for i in 0..<5 {
            store.save(record: makeRecord(transcriptText: "record \(i)"))
        }

        let results = store.list(limit: 10, offset: 3, searchQuery: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testSaveAndLoadPersonaRewriteRecord() {
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            transcriptText: "raw",
            personaResultText: "polished"
        )
        store.save(record: record)

        let list = store.list()
        XCTAssertEqual(list.first?.mode, .personaRewrite)
        XCTAssertEqual(list.first?.personaResultText, "polished")
    }

    func testClearOnEmptyStoreDoesNotCrash() {
        store.clear()
        XCTAssertTrue(store.list().isEmpty)
    }
}
