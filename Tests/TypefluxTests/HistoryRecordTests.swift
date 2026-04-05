@testable import Typeflux
import XCTest

final class HistoryRecordTests: XCTestCase {
    // MARK: - HistoryPipelineTiming

    func testMillisecondsBetweenValidDates() {
        let timing = HistoryPipelineTiming()
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1002.5)
        XCTAssertEqual(timing.millisecondsBetween(start, end), 2500)
    }

    func testMillisecondsBetweenReturnsZeroForReversedDates() {
        let timing = HistoryPipelineTiming()
        let start = Date(timeIntervalSince1970: 1003)
        let end = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(timing.millisecondsBetween(start, end), 0)
    }

    func testMillisecondsBetweenReturnsNilForNilStart() {
        let timing = HistoryPipelineTiming()
        XCTAssertNil(timing.millisecondsBetween(nil, Date()))
    }

    func testMillisecondsBetweenReturnsNilForNilEnd() {
        let timing = HistoryPipelineTiming()
        XCTAssertNil(timing.millisecondsBetween(Date(), nil))
    }

    func testMillisecondsBetweenReturnsNilForBothNil() {
        let timing = HistoryPipelineTiming()
        XCTAssertNil(timing.millisecondsBetween(nil, nil))
    }

    func testTimingHasDataWhenEmpty() {
        let timing = HistoryPipelineTiming()
        XCTAssertFalse(timing.hasData)
    }

    func testTimingHasDataWhenRecordingStoppedSet() {
        var timing = HistoryPipelineTiming()
        timing.recordingStoppedAt = Date()
        XCTAssertTrue(timing.hasData)
    }

    func testGeneratedStatsComputesTranscriptionDuration() {
        let base = Date(timeIntervalSince1970: 1000)
        var timing = HistoryPipelineTiming()
        timing.recordingStoppedAt = base
        timing.audioFileReadyAt = base.addingTimeInterval(0.1)
        timing.transcriptionStartedAt = base.addingTimeInterval(0.2)
        timing.transcriptionCompletedAt = base.addingTimeInterval(1.2)

        let stats = timing.generatedStats()
        XCTAssertEqual(stats.stopToAudioReadyMilliseconds, 100)
        XCTAssertEqual(stats.transcriptionDurationMilliseconds, 1000)
        XCTAssertEqual(stats.stopToTranscriptionCompletedMilliseconds, 1200)
    }

    func testGeneratedStatsEndToEndUsesLatestAvailableTimestamp() {
        let base = Date(timeIntervalSince1970: 1000)
        var timing = HistoryPipelineTiming()
        timing.recordingStoppedAt = base
        timing.transcriptionCompletedAt = base.addingTimeInterval(2.0)

        let stats = timing.generatedStats()
        XCTAssertEqual(stats.endToEndMilliseconds, 2000)
    }

    // MARK: - HistoryPipelineStats

    func testPipelineStatsHasDataWhenEmpty() {
        let stats = HistoryPipelineStats()
        XCTAssertFalse(stats.hasData)
    }

    func testPipelineStatsHasDataWithDurationOnly() {
        let stats = HistoryPipelineStats(transcriptionDurationMilliseconds: 500)
        XCTAssertTrue(stats.hasData)
    }

    // MARK: - HistoryRecord computed properties

    func testTextPriorityOrder() {
        let record = HistoryRecord(
            date: Date(),
            transcriptText: "transcript",
            personaResultText: "persona",
            selectionEditedText: "edited",
        )
        XCTAssertEqual(record.text, "edited")
    }

    func testTextFallsBackToPersona() {
        let record = HistoryRecord(
            date: Date(),
            transcriptText: "transcript",
            personaResultText: "persona",
        )
        XCTAssertEqual(record.text, "persona")
    }

    func testTextFallsBackToTranscript() {
        let record = HistoryRecord(
            date: Date(),
            transcriptText: "transcript",
        )
        XCTAssertEqual(record.text, "transcript")
    }

    func testTextFallsBackToErrorMessage() {
        let record = HistoryRecord(
            date: Date(),
            errorMessage: "something failed",
        )
        XCTAssertEqual(record.text, "something failed")
    }

    func testTextReturnsEmptyWhenNothingSet() {
        let record = HistoryRecord(date: Date())
        XCTAssertEqual(record.text, "")
    }

    func testFinalTextExcludesErrorMessage() {
        let record = HistoryRecord(
            date: Date(),
            errorMessage: "error",
        )
        XCTAssertNil(record.finalText)
    }

    func testHasFailureDetectsFailedRecording() {
        let record = HistoryRecord(date: Date(), recordingStatus: .failed)
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureDetectsFailedTranscription() {
        let record = HistoryRecord(date: Date(), transcriptionStatus: .failed)
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureDetectsErrorMessage() {
        let record = HistoryRecord(date: Date(), errorMessage: "oops")
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureFalseForEmptyErrorMessage() {
        let record = HistoryRecord(date: Date(), errorMessage: "")
        XCTAssertFalse(record.hasFailure)
    }

    func testHasFailureFalseWhenAllPending() {
        let record = HistoryRecord(date: Date())
        XCTAssertFalse(record.hasFailure)
    }

    func testHasProcessingDetailsDetectsTranscript() {
        let record = HistoryRecord(date: Date(), transcriptText: "hello")
        XCTAssertTrue(record.hasProcessingDetails)
    }

    func testHasProcessingDetailsFalseWhenEmpty() {
        let record = HistoryRecord(date: Date())
        XCTAssertFalse(record.hasProcessingDetails)
    }

    // MARK: - HistoryRecord Codable

    func testCodableRoundTrip() throws {
        let record = HistoryRecord(
            date: Date(timeIntervalSince1970: 1000),
            mode: .personaRewrite,
            transcriptText: "hello",
            personaResultText: "Hello!",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .succeeded,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(record)
        let decoded = try decoder.decode(HistoryRecord.self, from: data)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.mode, .personaRewrite)
        XCTAssertEqual(decoded.transcriptText, "hello")
        XCTAssertEqual(decoded.personaResultText, "Hello!")
        XCTAssertEqual(decoded.recordingStatus, .succeeded)
        XCTAssertEqual(decoded.applyStatus, .succeeded)
    }

    func testDecodesLegacyTextFieldAsTranscript() throws {
        let json: [String: Any] = [
            "text": "legacy transcript",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let record = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(record.transcriptText, "legacy transcript")
        XCTAssertEqual(record.transcriptionStatus, .succeeded)
        XCTAssertEqual(record.applyStatus, .succeeded)
    }

    func testDecodesWithMissingFieldsUsingDefaults() throws {
        let json: [String: Any] = [:]
        let data = try JSONSerialization.data(withJSONObject: json)
        let record = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(record.mode, .dictation)
        XCTAssertNil(record.transcriptText)
        XCTAssertEqual(record.recordingStatus, .succeeded)
        XCTAssertEqual(record.transcriptionStatus, .pending)
        XCTAssertEqual(record.applyStatus, .pending)
    }

    func testPipelineStatsGeneratedFromTimingDuringDecode() {
        let base = Date(timeIntervalSince1970: 1000)
        let timing = HistoryPipelineTiming(
            recordingStoppedAt: base,
            transcriptionStartedAt: base.addingTimeInterval(0.1),
            transcriptionCompletedAt: base.addingTimeInterval(1.1),
        )

        let record = HistoryRecord(
            date: base,
            pipelineTiming: timing,
        )

        XCTAssertNotNil(record.pipelineStats)
        XCTAssertEqual(record.pipelineStats?.transcriptionDurationMilliseconds, 1000)
    }

    // MARK: - HistoryRecord.Mode

    func testModeRawValues() {
        XCTAssertEqual(HistoryRecord.Mode.dictation.rawValue, "dictation")
        XCTAssertEqual(HistoryRecord.Mode.personaRewrite.rawValue, "personaRewrite")
        XCTAssertEqual(HistoryRecord.Mode.editSelection.rawValue, "editSelection")
        XCTAssertEqual(HistoryRecord.Mode.askAnswer.rawValue, "askAnswer")
    }

    // MARK: - HistoryRecord.StepStatus

    func testStepStatusRawValues() {
        XCTAssertEqual(HistoryRecord.StepStatus.pending.rawValue, "pending")
        XCTAssertEqual(HistoryRecord.StepStatus.running.rawValue, "running")
        XCTAssertEqual(HistoryRecord.StepStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(HistoryRecord.StepStatus.failed.rawValue, "failed")
        XCTAssertEqual(HistoryRecord.StepStatus.skipped.rawValue, "skipped")
    }
}

// MARK: - Extended HistoryRecord tests

final class HistoryRecordExtendedTests: XCTestCase {
    // MARK: - HistoryRecord text computed property

    func testTextFallsThroughToTranscriptText() {
        let record = HistoryRecord(
            date: Date(),
            mode: .dictation,
            transcriptText: "transcript",
        )
        XCTAssertEqual(record.text, "transcript")
    }

    func testTextPrefersPersonaResultOverTranscript() {
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            transcriptText: "original",
            personaResultText: "rewritten",
        )
        XCTAssertEqual(record.text, "rewritten")
    }

    func testTextPrefersSelectionEditedOverAll() {
        let record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            transcriptText: "original",
            personaResultText: "persona",
            selectionEditedText: "edited",
        )
        XCTAssertEqual(record.text, "edited")
    }

    func testTextFallsBackToErrorMessage() {
        let record = HistoryRecord(
            date: Date(),
            mode: .dictation,
            errorMessage: "Something failed",
        )
        XCTAssertEqual(record.text, "Something failed")
    }

    func testTextReturnsEmptyWhenAllNil() {
        let record = HistoryRecord(date: Date())
        XCTAssertEqual(record.text, "")
    }

    // MARK: - finalText

    func testFinalTextIsNilWhenAllNil() {
        let record = HistoryRecord(date: Date())
        XCTAssertNil(record.finalText)
    }

    func testFinalTextReturnsTranscriptWhenOnlyTranscript() {
        let record = HistoryRecord(date: Date(), transcriptText: "hello")
        XCTAssertEqual(record.finalText, "hello")
    }

    func testFinalTextPrefersEditedText() {
        let record = HistoryRecord(
            date: Date(),
            transcriptText: "original",
            selectionEditedText: "edited",
        )
        XCTAssertEqual(record.finalText, "edited")
    }

    // MARK: - hasFailure

    func testHasFailureIsFalseWhenAllSucceeded() {
        let record = HistoryRecord(
            date: Date(),
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .succeeded,
        )
        XCTAssertFalse(record.hasFailure)
    }

    func testHasFailureIsTrueWhenRecordingFailed() {
        let record = HistoryRecord(
            date: Date(),
            recordingStatus: .failed,
        )
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureIsTrueWhenTranscriptionFailed() {
        let record = HistoryRecord(
            date: Date(),
            transcriptionStatus: .failed,
        )
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureIsTrueWhenErrorMessageIsSet() {
        let record = HistoryRecord(
            date: Date(),
            errorMessage: "unexpected error",
        )
        XCTAssertTrue(record.hasFailure)
    }

    func testHasFailureIsFalseWithEmptyErrorMessage() {
        let record = HistoryRecord(
            date: Date(),
            errorMessage: "",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .succeeded,
        )
        XCTAssertFalse(record.hasFailure)
    }

    // MARK: - HistoryPipelineTiming hasData

    func testTimingHasDataWhenTranscriptionSet() {
        var timing = HistoryPipelineTiming()
        timing.transcriptionStartedAt = Date()
        XCTAssertTrue(timing.hasData)
    }

    func testTimingHasDataWhenLLMSet() {
        var timing = HistoryPipelineTiming()
        timing.llmProcessingStartedAt = Date()
        XCTAssertTrue(timing.hasData)
    }

    func testTimingHasDataWhenApplySet() {
        var timing = HistoryPipelineTiming()
        timing.applyCompletedAt = Date()
        XCTAssertTrue(timing.hasData)
    }

    // MARK: - HistoryPipelineStats hasData

    func testStatsHasDataWithDurationFields() {
        let stats = HistoryPipelineStats(transcriptionDurationMilliseconds: 100)
        XCTAssertTrue(stats.hasData)
    }

    func testStatsHasDataWithEndToEnd() {
        let stats = HistoryPipelineStats(endToEndMilliseconds: 1500)
        XCTAssertTrue(stats.hasData)
    }

    // MARK: - HistoryRecord Codable

    func testHistoryRecordCodableRoundTrip() throws {
        let original = HistoryRecord(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1000),
            mode: .editSelection,
            transcriptText: "test",
            selectionOriginalText: "old",
            selectionEditedText: "new",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .succeeded,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.mode, .editSelection)
        XCTAssertEqual(decoded.transcriptText, "test")
        XCTAssertEqual(decoded.selectionOriginalText, "old")
        XCTAssertEqual(decoded.selectionEditedText, "new")
    }

    // MARK: - generatedStats end-to-end calculations

    func testGeneratedStatsPreferApplyCompletedForEndToEnd() {
        let base = Date(timeIntervalSince1970: 0)
        var timing = HistoryPipelineTiming()
        timing.recordingStoppedAt = base
        timing.transcriptionCompletedAt = base.addingTimeInterval(1.0)
        timing.llmProcessingCompletedAt = base.addingTimeInterval(2.0)
        timing.applyCompletedAt = base.addingTimeInterval(3.0)

        let stats = timing.generatedStats()
        XCTAssertEqual(stats.endToEndMilliseconds, 3000)
    }

    func testGeneratedStatsUsesLLMCompletedWhenApplyMissing() {
        let base = Date(timeIntervalSince1970: 0)
        var timing = HistoryPipelineTiming()
        timing.recordingStoppedAt = base
        timing.transcriptionCompletedAt = base.addingTimeInterval(1.0)
        timing.llmProcessingCompletedAt = base.addingTimeInterval(2.5)
        // applyCompletedAt is nil

        let stats = timing.generatedStats()
        XCTAssertEqual(stats.endToEndMilliseconds, 2500)
    }
}
