import XCTest
@testable import Typeflux

final class AutomaticVocabularyMonitorTests: XCTestCase {
    func testPendingAnalysisWaitsUntilTextSettles() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start
        )

        XCTAssertTrue(
            AutomaticVocabularyMonitor.observe(
                text: "hello Doubao",
                at: start.addingTimeInterval(1),
                state: &state
            )
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(2),
                settleDelay: 2.5,
                maxAnalyses: 3
            )
        )

        let pending = AutomaticVocabularyMonitor.pendingAnalysis(
            state: state,
            now: start.addingTimeInterval(3.6),
            settleDelay: 2.5,
            maxAnalyses: 3
        )

        XCTAssertEqual(pending?.previousStableText, "hello world")
        XCTAssertEqual(pending?.updatedText, "hello Doubao")
    }

    func testPendingAnalysisResetsWhenUserKeepsEditing() {
        let start = Date(timeIntervalSince1970: 2_000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Dou",
            at: start.addingTimeInterval(1),
            state: &state
        )
        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(2),
            state: &state
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(4),
                settleDelay: 2.5,
                maxAnalyses: 3
            )
        )

        XCTAssertNotNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(4.6),
                settleDelay: 2.5,
                maxAnalyses: 3
            )
        )
    }

    func testMarkAnalysisCompletedPreventsDuplicateTriggerForSameStableText() {
        let start = Date(timeIntervalSince1970: 3_000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state
        )

        let pending = AutomaticVocabularyMonitor.pendingAnalysis(
            state: state,
            now: start.addingTimeInterval(4),
            settleDelay: 2.5,
            maxAnalyses: 3
        )
        XCTAssertEqual(pending?.updatedText, "hello Doubao")

        AutomaticVocabularyMonitor.markAnalysisCompleted(for: "hello Doubao", state: &state)

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(6),
                settleDelay: 2.5,
                maxAnalyses: 3
            )
        )
        XCTAssertEqual(state.analysisCount, 1)
    }

    func testPendingAnalysisHonorsMaxAnalysisLimit() {
        let start = Date(timeIntervalSince1970: 4_000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start
        )
        state.analysisCount = 3

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(5),
                settleDelay: 2.5,
                maxAnalyses: 3
            )
        )
    }

    func testDetectChangeExtractsNewLatinToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please review the prd draft",
            to: "Please review the PRDPlus draft"
        )

        XCTAssertEqual(change?.oldFragment, "prd")
        XCTAssertEqual(change?.newFragment, "PRDPlus")
        XCTAssertEqual(change?.candidateTerms, ["PRDPlus"])
    }

    func testDetectChangeExtractsNewHanToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "我在写豆包语音",
            to: "我在写豆包 SeedASR"
        )

        XCTAssertEqual(change?.candidateTerms, ["SeedASR"])
    }

    func testParseAcceptedTermsSupportsJSONObject() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["SeedASR","Qwen3-ASR","SeedASR"]}"#
        )

        XCTAssertEqual(terms, ["SeedASR", "Qwen3-ASR"])
    }
}
