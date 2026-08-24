@testable import Typeflux
import XCTest

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

// MARK: - Extended FileHistoryStore tests

extension FileHistoryStoreTests {
    func testExportMarkdownIncludesProcessingDiagnostics() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let race = ASRRaceDiagnostics(
            startedAt: startedAt,
            selectedAt: startedAt.addingTimeInterval(1),
            priorityWindowMilliseconds: 3_000,
            decisionDurationMilliseconds: 1_000,
            selectedSource: .cloud,
            selectionReason: .cloudWithinPriorityWindow,
            cloudPriorityWindowExceeded: false,
            cloudAttempt: ASRAttemptDiagnostics(
                outcome: .succeeded,
                durationMilliseconds: 1_000,
                completedAt: startedAt.addingTimeInterval(1)
            ),
            localAttempt: ASRAttemptDiagnostics(outcome: .cancelled, durationMilliseconds: 1_000)
        )
        let llmOutcome = LLMProcessingOutcomeDiagnostics(
            startedAt: startedAt.addingTimeInterval(1),
            completedAt: startedAt.addingTimeInterval(1.4),
            timeoutMilliseconds: 3_000,
            outcome: .completed,
            usedTranscriptFallback: false
        )
        let record = HistoryRecord(
            date: startedAt,
            transcriptText: "diagnostic transcript",
            pipelineTiming: HistoryPipelineTiming(asrRace: race, llmOutcome: llmOutcome)
        )
        store.save(record: record)
        flush()

        let exportURL = try store.exportMarkdown()
        let markdown = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("ASR race selected: cloud"))
        XCTAssertTrue(markdown.contains("Local: 1000 ms (cancelled)"))
        XCTAssertTrue(markdown.contains("LLM outcome: completed"))
        XCTAssertEqual(markdown.components(separatedBy: "ASR race selected:").count - 1, 1)
    }

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
        for i in 0 ..< 5 {
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
