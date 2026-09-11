@testable import Typeflux
import XCTest

final class HistoryRetryPlanTests: XCTestCase {
    func testSelectionPersonaRetryDoesNotRequireAudio() {
        let record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: "Make it concise.",
            selectionOriginalText: "Original text",
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .failed,
            applyStatus: .skipped
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { _ in false }),
            .rewriteSelection(sourceText: "Original text", personaPrompt: "Make it concise.")
        )
    }

    func testCompletedTranscriptionRetriesPersonaWithoutAudio() {
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            audioFilePath: "/missing/audio.wav",
            transcriptText: "Raw transcript",
            personaPrompt: "Polish this.",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .failed,
            applyStatus: .skipped
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { _ in false }),
            .rewriteTranscript(sourceText: "Raw transcript", personaPrompt: "Polish this.")
        )
    }

    func testCompletedTranscriptionRetriesPersonaBeforeModeTransition() {
        let record = HistoryRecord(
            date: Date(),
            mode: .dictation,
            transcriptText: "Raw transcript",
            personaPrompt: "Polish this.",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .pending,
            applyStatus: .pending
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { _ in false }),
            .rewriteTranscript(sourceText: "Raw transcript", personaPrompt: "Polish this.")
        )
    }

    func testFailedTranscriptionRetriesFromExistingAudio() {
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            audioFilePath: "/audio.wav",
            personaPrompt: "Polish this.",
            recordingStatus: .succeeded,
            transcriptionStatus: .failed,
            processingStatus: .skipped,
            applyStatus: .skipped
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { $0 == "/audio.wav" }),
            .retranscribe(audioURL: URL(fileURLWithPath: "/audio.wav"))
        )
    }

    func testFailedApplyReusesGeneratedResult() {
        let record = HistoryRecord(
            date: Date(),
            mode: .personaRewrite,
            transcriptText: "Raw transcript",
            personaPrompt: "Polish this.",
            postProcessedText: "Finished result",
            recordingStatus: .succeeded,
            transcriptionStatus: .succeeded,
            processingStatus: .succeeded,
            applyStatus: .failed
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { _ in false }),
            .presentResult("Finished result")
        )
    }

    func testMissingRequiredAudioIsUnavailable() {
        let record = HistoryRecord(
            date: Date(),
            mode: .dictation,
            recordingStatus: .succeeded,
            transcriptionStatus: .failed,
            processingStatus: .skipped,
            applyStatus: .skipped
        )

        XCTAssertEqual(
            HistoryRetryPlanner.plan(for: record, fileExists: { _ in false }),
            .unavailable(.audioMissing)
        )
    }
}
