@testable import Typeflux
import XCTest

final class UsageStatsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: UsageStatsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "UsageStatsStoreTests-\(UUID().uuidString)")!
        store = UsageStatsStore(defaults: defaults)
    }

    override func tearDown() {
        if let suiteName = defaults.volatileDomainNames.first {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Computed metrics

    func testCompletionRateZeroWhenNoSessions() {
        XCTAssertEqual(store.completionRate, 0)
    }

    func testCompletionRateCalculation() {
        defaults.set(10, forKey: "stats.totalSessions")
        defaults.set(7, forKey: "stats.successfulSessions")
        XCTAssertEqual(store.completionRate, 70)
    }

    func testCompletionRateCappedAt100() {
        defaults.set(5, forKey: "stats.totalSessions")
        defaults.set(10, forKey: "stats.successfulSessions")
        XCTAssertEqual(store.completionRate, 100)
    }

    func testSavedMinutesZeroWithNoData() {
        XCTAssertEqual(store.savedMinutes, 0)
    }

    func testSavedMinutesCalculation() {
        defaults.set(60.0, forKey: "stats.estimatedTypingSeconds")
        defaults.set(30.0, forKey: "stats.totalRecordingSeconds")
        // (60/60) - (30/60) = 1 - 0.5 = 0.5 → rounds to 1
        XCTAssertEqual(store.savedMinutes, 1)
    }

    func testSavedMinutesNeverNegative() {
        defaults.set(10.0, forKey: "stats.estimatedTypingSeconds")
        defaults.set(600.0, forKey: "stats.totalRecordingSeconds")
        XCTAssertEqual(store.savedMinutes, 0)
    }

    func testAveragePaceWPMZeroWithShortRecording() {
        defaults.set(10.0, forKey: "stats.totalRecordingSeconds")
        defaults.set(50, forKey: "stats.totalWords")
        // 10/60 = 0.17 minutes < 0.5 → returns 0
        XCTAssertEqual(store.averagePaceWPM, 0)
    }

    func testAveragePaceWPMCalculation() {
        defaults.set(120.0, forKey: "stats.totalRecordingSeconds")
        defaults.set(200, forKey: "stats.totalWords")
        // 200 / (120/60) = 200/2 = 100
        XCTAssertEqual(store.averagePaceWPM, 100)
    }

    func testTotalDictationMinutes() {
        defaults.set(150.0, forKey: "stats.totalRecordingSeconds")
        // 150/60 = 2.5 → rounds to 3
        XCTAssertEqual(store.totalDictationMinutes, 3)
    }

    // MARK: - editedTextContribution (LCS diff)

    func testEditedTextContributionEmptyEdited() {
        let result = store.editedTextContribution(originalText: "hello", editedText: "")
        XCTAssertEqual(result, "")
    }

    func testEditedTextContributionEmptyOriginal() {
        let result = store.editedTextContribution(originalText: "", editedText: "new text")
        XCTAssertEqual(result, "new text")
    }

    func testEditedTextContributionIdenticalTexts() {
        let result = store.editedTextContribution(originalText: "same", editedText: "same")
        XCTAssertEqual(result, "")
    }

    func testEditedTextContributionAppendedText() {
        let result = store.editedTextContribution(originalText: "abc", editedText: "abcdef")
        XCTAssertEqual(result, "def")
    }

    func testEditedTextContributionPrependedText() {
        let result = store.editedTextContribution(originalText: "world", editedText: "Hello world")
        XCTAssertEqual(result, "Hello")
    }

    func testEditedTextContributionMiddleInsertion() {
        let result = store.editedTextContribution(originalText: "ac", editedText: "abc")
        XCTAssertEqual(result, "b")
    }

    func testEditedTextContributionCompleteReplacement() {
        let result = store.editedTextContribution(originalText: "abc", editedText: "xyz")
        XCTAssertEqual(result, "xyz")
    }

    // MARK: - heuristicEditedTextContribution

    func testHeuristicContributionMiddleChange() {
        let original = Array("Hello World!")
        let edited = Array("Hello Swift World!")
        let result = store.heuristicEditedTextContribution(original: original, edited: edited)
        XCTAssertEqual(result, "Swift")
    }

    func testHeuristicContributionPrefixMatch() {
        let original = Array("abc")
        let edited = Array("abcdef")
        let result = store.heuristicEditedTextContribution(original: original, edited: edited)
        XCTAssertEqual(result, "def")
    }

    func testHeuristicContributionSuffixMatch() {
        let original = Array("def")
        let edited = Array("abcdef")
        let result = store.heuristicEditedTextContribution(original: original, edited: edited)
        XCTAssertEqual(result, "abc")
    }

    func testHeuristicContributionNoChangeReturnsEmpty() {
        let chars = Array("same")
        let result = store.heuristicEditedTextContribution(original: chars, edited: chars)
        XCTAssertEqual(result, "")
    }

    // MARK: - estimatedTypingSeconds

    func testEstimatedTypingSecondsLatinOnly() {
        // 10 latin chars: 10 * 60/240 = 2.5 seconds
        let seconds = store.estimatedTypingSeconds(for: "abcdefghij")
        XCTAssertEqual(seconds, 2.5, accuracy: 0.01)
    }

    func testEstimatedTypingSecondsCJKOnly() {
        // 3 CJK chars: 3 * 60/45 = 4.0 seconds
        let seconds = store.estimatedTypingSeconds(for: "你好世")
        XCTAssertEqual(seconds, 4.0, accuracy: 0.01)
    }

    func testEstimatedTypingSecondsMixed() {
        // "Hi你好" → 2 latin + 2 CJK
        // 2 * 60/240 + 2 * 60/45 = 0.5 + 2.667 = 3.167
        let seconds = store.estimatedTypingSeconds(for: "Hi你好")
        XCTAssertEqual(seconds, 0.5 + 2 * 60.0 / 45.0, accuracy: 0.01)
    }

    func testEstimatedTypingSecondsSkipsWhitespace() {
        let seconds = store.estimatedTypingSeconds(for: "  \n\t  ")
        XCTAssertEqual(seconds, 0.0)
    }

    func testEstimatedTypingSecondsKana() {
        // Japanese kana
        let seconds = store.estimatedTypingSeconds(for: "あいう")
        XCTAssertEqual(seconds, 3 * 60.0 / 45.0, accuracy: 0.01)
    }

    func testEstimatedTypingSecondsHangul() {
        // Korean hangul
        let seconds = store.estimatedTypingSeconds(for: "가나다")
        XCTAssertEqual(seconds, 3 * 60.0 / 45.0, accuracy: 0.01)
    }

    // MARK: - wordCount

    func testWordCountEnglish() {
        let count = store.wordCount("Hello world, this is a test")
        XCTAssertEqual(count, 6)
    }

    func testWordCountEmpty() {
        let count = store.wordCount("")
        XCTAssertEqual(count, 0)
    }

    func testWordCountChinese() {
        let count = store.wordCount("你好世界")
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Unicode.Scalar extensions

    func testCJKIdeographDetection() throws {
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0x4E00)?.isCJKIdeograph)) // 一
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0x9FFF)?.isCJKIdeograph)) // End of CJK Unified
        XCTAssertFalse(try XCTUnwrap(Unicode.Scalar(0x0041)?.isCJKIdeograph)) // A
    }

    func testKanaDetection() throws {
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0x3042)?.isKana)) // あ (Hiragana)
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0x30A2)?.isKana)) // ア (Katakana)
        XCTAssertFalse(try XCTUnwrap(Unicode.Scalar(0x0041)?.isKana)) // A
    }

    func testHangulDetection() throws {
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0xAC00)?.isHangul)) // 가
        XCTAssertTrue(try XCTUnwrap(Unicode.Scalar(0x1100)?.isHangul)) // ᄀ (Hangul Jamo)
        XCTAssertFalse(try XCTUnwrap(Unicode.Scalar(0x0041)?.isHangul)) // A
    }

    // MARK: - contribution / isSuccessful

    func testIsSuccessfulWithApplySucceeded() {
        let record = HistoryRecord(
            date: Date(),
            applyStatus: .succeeded,
        )
        XCTAssertTrue(store.isSuccessful(record))
    }

    func testIsSuccessfulWithSkippedApplyAndSucceededTranscription() {
        let record = HistoryRecord(
            date: Date(),
            transcriptionStatus: .succeeded,
            applyStatus: .skipped,
        )
        XCTAssertTrue(store.isSuccessful(record))
    }

    func testIsNotSuccessfulWhenPending() {
        let record = HistoryRecord(date: Date())
        XCTAssertFalse(store.isSuccessful(record))
    }

    func testContributionCountsModeCorrectly() {
        let dictation = HistoryRecord(date: Date(), mode: .dictation)
        XCTAssertEqual(store.contribution(for: dictation).dictationCount, 1)
        XCTAssertEqual(store.contribution(for: dictation).personaRewriteCount, 0)

        let persona = HistoryRecord(date: Date(), mode: .personaRewrite)
        XCTAssertEqual(store.contribution(for: persona).personaRewriteCount, 1)

        let edit = HistoryRecord(date: Date(), mode: .editSelection)
        XCTAssertEqual(store.contribution(for: edit).editSelectionCount, 1)

        let ask = HistoryRecord(date: Date(), mode: .askAnswer)
        XCTAssertEqual(store.contribution(for: ask).askAnswerCount, 1)
    }

    func testContributionSessionCounts() {
        let failedRecord = HistoryRecord(
            date: Date(),
            recordingStatus: .failed,
            applyStatus: .succeeded,
        )
        let contrib = store.contribution(for: failedRecord)
        XCTAssertEqual(contrib.sessions, 1)
        XCTAssertEqual(contrib.successfulSessions, 1)
        XCTAssertEqual(contrib.failedSessions, 1)
    }

    // MARK: - SessionContribution.add

    func testSessionContributionAdd() {
        var a = UsageStatsStore.SessionContribution(sessions: 1, successfulSessions: 1)
        let b = UsageStatsStore.SessionContribution(sessions: 2, failedSessions: 1, outputWords: 50)
        a.add(b)
        XCTAssertEqual(a.sessions, 3)
        XCTAssertEqual(a.successfulSessions, 1)
        XCTAssertEqual(a.failedSessions, 1)
        XCTAssertEqual(a.outputWords, 50)
    }
}

// MARK: - Extended UsageStatsStore tests

extension UsageStatsStoreTests {
    // MARK: - editedTextContribution

    func testEditedTextContributionEmptyEditedReturnsEmpty() {
        let result = store.editedTextContribution(originalText: "hello", editedText: "")
        XCTAssertEqual(result, "")
    }

    func testEditedTextContributionEmptyOriginalReturnsEdited() {
        let result = store.editedTextContribution(originalText: "", editedText: "new text")
        XCTAssertEqual(result, "new text")
    }

    func testEditedTextContributionSameTextReturnsEmpty() {
        let result = store.editedTextContribution(originalText: "same", editedText: "same")
        XCTAssertEqual(result, "")
    }

    func testEditedTextContributionReturnsInsertedText() {
        // "testing" appends "ing" to "test"; the LCS-based diff captures the suffix
        let result = store.editedTextContribution(
            originalText: "test",
            editedText: "testing",
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("ing"))
    }

    func testEditedTextContributionSimpleReplacement() {
        let result = store.editedTextContribution(
            originalText: "good morning",
            editedText: "good evening",
        )
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - heuristicEditedTextContribution

    func testHeuristicContributionOnFullReplacement() {
        let original = Array("hello")
        let edited = Array("world")
        let result = store.heuristicEditedTextContribution(original: original, edited: edited)
        XCTAssertEqual(result, "world")
    }

    func testHeuristicContributionOnPrefixAppend() {
        let original = Array("hello")
        let edited = Array("hello world")
        let result = store.heuristicEditedTextContribution(original: original, edited: edited)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - completionRate

    func testCompletionRateIsZeroWithNoSessions() {
        let rate = store.completionRate
        // With no sessions, should not crash
        XCTAssertGreaterThanOrEqual(rate, 0)
    }

    // MARK: - totalDictationMinutes

    func testTotalDictationMinutesIsNonNegative() {
        XCTAssertGreaterThanOrEqual(store.totalDictationMinutes, 0)
    }

    // MARK: - savedMinutes

    func testSavedMinutesIsNonNegative() {
        XCTAssertGreaterThanOrEqual(store.savedMinutes, 0)
    }

    // MARK: - averagePaceWPM

    func testAveragePaceWPMIsNonNegative() {
        XCTAssertGreaterThanOrEqual(store.averagePaceWPM, 0)
    }

    // MARK: - SessionContribution.add cumulative fields

    func testSessionContributionAddsAllFields() {
        var a = UsageStatsStore.SessionContribution()
        a.sessions = 1
        a.successfulSessions = 1
        a.perceivedSeconds = 10.0
        a.estimatedTypingSeconds = 5.0
        a.outputCharacters = 100
        a.outputWords = 20
        a.dictationCount = 1

        var b = UsageStatsStore.SessionContribution()
        b.sessions = 2
        b.failedSessions = 1
        b.perceivedSeconds = 5.0
        b.estimatedTypingSeconds = 2.5
        b.outputCharacters = 50
        b.outputWords = 10
        b.askAnswerCount = 2

        a.add(b)

        XCTAssertEqual(a.sessions, 3)
        XCTAssertEqual(a.successfulSessions, 1)
        XCTAssertEqual(a.failedSessions, 1)
        XCTAssertEqual(a.perceivedSeconds, 15.0, accuracy: 0.001)
        XCTAssertEqual(a.estimatedTypingSeconds, 7.5, accuracy: 0.001)
        XCTAssertEqual(a.outputCharacters, 150)
        XCTAssertEqual(a.outputWords, 30)
        XCTAssertEqual(a.dictationCount, 1)
        XCTAssertEqual(a.askAnswerCount, 2)
    }

    // MARK: - isSuccessful edge cases

    func testIsNotSuccessfulWhenTranscriptionPending() {
        let record = HistoryRecord(
            date: Date(),
            transcriptionStatus: .pending,
            applyStatus: .pending,
        )
        XCTAssertFalse(store.isSuccessful(record))
    }

    func testIsNotSuccessfulWhenTranscriptionFailed() {
        // applyStatus must also not be .succeeded for the record to be not successful
        let record = HistoryRecord(
            date: Date(),
            transcriptionStatus: .failed,
            applyStatus: .failed,
        )
        XCTAssertFalse(store.isSuccessful(record))
    }
}
