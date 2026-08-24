@testable import Typeflux
import XCTest

final class SQLiteHistoryStoreTests: XCTestCase {
    private var testDir: URL!
    private var store: SQLiteHistoryStore!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = SQLiteHistoryStore(baseDir: testDir)
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
        mode: HistoryRecord.Mode = .dictation,
        audioFilePath: String? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            date: date,
            mode: mode,
            audioFilePath: audioFilePath,
            transcriptText: transcriptText
        )
    }

    private func makeAudioFile(named name: String = UUID().uuidString) throws -> URL {
        let url = testDir.appendingPathComponent("\(name).wav")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func flush() {
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

    func testSaveFetchAndExportPreserveProcessingDiagnostics() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let race = ASRRaceDiagnostics(
            startedAt: startedAt,
            selectedAt: startedAt.addingTimeInterval(3),
            priorityWindowMilliseconds: 3_000,
            decisionDurationMilliseconds: 3_000,
            selectedSource: .local,
            selectionReason: .localAtPriorityDeadline,
            cloudPriorityWindowExceeded: true,
            cloudAttempt: ASRAttemptDiagnostics(outcome: .cancelled, durationMilliseconds: 3_000),
            localAttempt: ASRAttemptDiagnostics(
                outcome: .succeeded,
                durationMilliseconds: 800,
                completedAt: startedAt.addingTimeInterval(0.8)
            )
        )
        let llmOutcome = LLMProcessingOutcomeDiagnostics(
            startedAt: startedAt.addingTimeInterval(3),
            completedAt: startedAt.addingTimeInterval(6),
            timeoutMilliseconds: 3_000,
            outcome: .timedOutFallback,
            usedTranscriptFallback: true
        )
        var record = makeRecord(transcriptText: "diagnostic transcript")
        record.pipelineTiming = HistoryPipelineTiming(asrRace: race, llmOutcome: llmOutcome)

        store.save(record: record)
        flush()

        let fetched = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(fetched.pipelineTiming?.asrRace, race)
        XCTAssertEqual(fetched.pipelineTiming?.llmOutcome, llmOutcome)
        XCTAssertEqual(fetched.pipelineStats?.asrRace, race)
        XCTAssertEqual(fetched.pipelineStats?.llmOutcome, llmOutcome)

        let exportURL = try store.exportMarkdown()
        let markdown = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("ASR race selected: local"))
        XCTAssertTrue(markdown.contains("Cloud: 3000 ms (cancelled)"))
        XCTAssertTrue(markdown.contains("LLM outcome: timedOutFallback"))
        XCTAssertTrue(markdown.contains("Used transcript fallback: true"))
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
        for i in 0 ..< 5 {
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

    func testDeleteRemovesLinkedAudioFile() throws {
        let id = UUID()
        let audioURL = try makeAudioFile()
        store.save(record: makeRecord(id: id, transcriptText: "delete me", audioFilePath: audioURL.path))
        flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        store.delete(id: id)
        flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
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

    func testPurgeRemovesAudioFilesForExpiredRecordsOnly() throws {
        let oldAudioURL = try makeAudioFile(named: "old")
        let recentAudioURL = try makeAudioFile(named: "recent")
        let old = Date().addingTimeInterval(-10 * 24 * 3600)
        let recent = Date()

        store.save(record: makeRecord(date: old, transcriptText: "old", audioFilePath: oldAudioURL.path))
        store.save(record: makeRecord(date: recent, transcriptText: "recent", audioFilePath: recentAudioURL.path))
        flush()

        store.purge(olderThanDays: 5)
        flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentAudioURL.path))
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

    func testClearRemovesAllLinkedAudioFiles() throws {
        let firstAudioURL = try makeAudioFile(named: "first")
        let secondAudioURL = try makeAudioFile(named: "second")
        store.save(record: makeRecord(transcriptText: "a", audioFilePath: firstAudioURL.path))
        store.save(record: makeRecord(transcriptText: "b", audioFilePath: secondAudioURL.path))
        flush()

        store.clear()
        flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondAudioURL.path))
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

// MARK: - Extended SQLiteHistoryStore tests

extension SQLiteHistoryStoreTests {
    // MARK: - save with various modes

    func testSaveRecordWithAskAnswerMode() {
        let record = makeRecord(mode: .askAnswer)
        store.save(record: record)
        flush()

        let found = store.record(id: record.id)
        XCTAssertEqual(found?.mode, .askAnswer)
    }

    func testSaveRecordWithPersonaRewriteMode() {
        let record = makeRecord(mode: .personaRewrite)
        store.save(record: record)
        flush()

        let found = store.record(id: record.id)
        XCTAssertEqual(found?.mode, .personaRewrite)
    }

    func testSaveRecordWithEditSelectionMode() {
        let record = makeRecord(mode: .editSelection)
        store.save(record: record)
        flush()

        let found = store.record(id: record.id)
        XCTAssertEqual(found?.mode, .editSelection)
    }

    // MARK: - list ordering

    func testListOrdersByDateDescending() {
        let now = Date()
        let older = makeRecord(date: now.addingTimeInterval(-10), transcriptText: "older")
        let newer = makeRecord(date: now.addingTimeInterval(10), transcriptText: "newer")
        store.save(record: older)
        store.save(record: newer)
        flush()

        let list = store.list()
        XCTAssertEqual(list.first?.transcriptText, "newer")
        XCTAssertEqual(list.last?.transcriptText, "older")
    }

    // MARK: - list(limit:offset:searchQuery:) edge cases

    func testListWithZeroLimitReturnsEmpty() {
        store.save(record: makeRecord(transcriptText: "some text"))
        flush()

        let results = store.list(limit: 0, offset: 0, searchQuery: nil)
        XCTAssertEqual(results.count, 0)
    }

    func testListWithOffsetBeyondCountReturnsEmpty() {
        store.save(record: makeRecord(transcriptText: "a"))
        store.save(record: makeRecord(transcriptText: "b"))
        flush()

        let results = store.list(limit: 10, offset: 100, searchQuery: nil)
        XCTAssertEqual(results.count, 0)
    }

    func testListWithEmptySearchQueryReturnsAll() {
        store.save(record: makeRecord(transcriptText: "alpha"))
        store.save(record: makeRecord(transcriptText: "beta"))
        flush()

        let results = store.list(limit: 10, offset: 0, searchQuery: "")
        XCTAssertEqual(results.count, 2)
    }

    func testListWithNilSearchQueryReturnsAll() {
        store.save(record: makeRecord(transcriptText: "alpha"))
        store.save(record: makeRecord(transcriptText: "beta"))
        flush()

        let results = store.list(limit: 10, offset: 0, searchQuery: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testListSearchQueryIsCaseInsensitive() {
        store.save(record: makeRecord(transcriptText: "Hello World"))
        store.save(record: makeRecord(transcriptText: "Foo Bar"))
        flush()

        let results = store.list(limit: 10, offset: 0, searchQuery: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.transcriptText, "Hello World")
    }

    func testListSearchQueryReturnsEmptyForNoMatch() {
        store.save(record: makeRecord(transcriptText: "unrelated content"))
        flush()

        let results = store.list(limit: 10, offset: 0, searchQuery: "xyz123notfound")
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Multiple save/delete cycle

    func testSaveAndDeleteMultipleRecords() {
        let ids = (0 ..< 5).map { _ in UUID() }
        for id in ids {
            store.save(record: makeRecord(id: id, transcriptText: "item \(id)"))
        }
        flush()
        XCTAssertEqual(store.list().count, 5)

        store.delete(id: ids[0])
        store.delete(id: ids[2])
        flush()
        XCTAssertEqual(store.list().count, 3)
        XCTAssertNil(store.record(id: ids[0]))
        XCTAssertNil(store.record(id: ids[2]))
        XCTAssertNotNil(store.record(id: ids[1]))
    }

    // MARK: - purge edge cases

    func testPurgeWithLargeDayCountKeepsAll() {
        store.save(record: makeRecord(date: Date(), transcriptText: "recent"))
        flush()

        store.purge(olderThanDays: 10000)
        flush()

        XCTAssertEqual(store.list().count, 1)
    }

    func testPurgeWithZeroDaysRemovesAll() {
        // purge(olderThanDays: 0) should remove records older than 0 days (i.e., anything older than "now")
        let past = Date().addingTimeInterval(-1) // 1 second in the past
        store.save(record: makeRecord(date: past, transcriptText: "past"))
        flush()

        store.purge(olderThanDays: 0)
        flush()

        XCTAssertEqual(store.list().count, 0)
    }

    // MARK: - clear on empty store

    func testClearOnEmptyStoreDoesNotCrash() {
        store.clear()
        flush()
        XCTAssertEqual(store.list().count, 0)
    }

    // MARK: - exportMarkdown with multiple records

    func testExportMarkdownWithMultipleRecords() throws {
        store.save(record: makeRecord(transcriptText: "first entry", mode: .dictation))
        store.save(record: makeRecord(transcriptText: "second entry", mode: .personaRewrite))
        flush()

        let url = try store.exportMarkdown()
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("first entry"))
        XCTAssertTrue(content.contains("second entry"))
        XCTAssertTrue(content.contains("# Typeflux History"))
    }

    func testExportMarkdownOnEmptyStoreCreatesFile() throws {
        let url = try store.exportMarkdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("# Typeflux History"))
    }

    // MARK: - concurrent access safety

    func testConcurrentSavesDoNotCrash() {
        let expectation = XCTestExpectation(description: "concurrent saves")
        expectation.expectedFulfillmentCount = 10

        for i in 0 ..< 10 {
            DispatchQueue.global().async {
                let record = self.makeRecord(transcriptText: "concurrent item \(i)")
                self.store.save(record: record)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        flush()

        XCTAssertEqual(store.list().count, 10)
    }
}
