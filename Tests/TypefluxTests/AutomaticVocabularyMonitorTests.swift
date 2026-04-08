@testable import Typeflux
import XCTest

final class AutomaticVocabularyMonitorTests: XCTestCase {
    func testPendingAnalysisWaitsUntilTextSettles() {
        let start = Date(timeIntervalSince1970: 1000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )

        XCTAssertTrue(
            AutomaticVocabularyMonitor.observe(
                text: "hello Doubao",
                at: start.addingTimeInterval(1),
                state: &state,
            ),
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(2),
                settleDelay: 2.5,
                maxAnalyses: 3,
            ),
        )

        let pending = AutomaticVocabularyMonitor.pendingAnalysis(
            state: state,
            now: start.addingTimeInterval(3.6),
            settleDelay: 2.5,
            maxAnalyses: 3,
        )

        XCTAssertEqual(pending?.previousStableText, "hello world")
        XCTAssertEqual(pending?.updatedText, "hello Doubao")
    }

    func testPendingAnalysisResetsWhenUserKeepsEditing() {
        let start = Date(timeIntervalSince1970: 2000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Dou",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(2),
            state: &state,
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(4),
                settleDelay: 2.5,
                maxAnalyses: 3,
            ),
        )

        XCTAssertNotNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(4.6),
                settleDelay: 2.5,
                maxAnalyses: 3,
            ),
        )
    }

    func testMarkAnalysisCompletedPreventsDuplicateTriggerForSameStableText() {
        let start = Date(timeIntervalSince1970: 3000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state,
        )

        let pending = AutomaticVocabularyMonitor.pendingAnalysis(
            state: state,
            now: start.addingTimeInterval(4),
            settleDelay: 2.5,
            maxAnalyses: 3,
        )
        XCTAssertEqual(pending?.updatedText, "hello Doubao")

        AutomaticVocabularyMonitor.markAnalysisCompleted(for: "hello Doubao", state: &state)

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(6),
                settleDelay: 2.5,
                maxAnalyses: 3,
            ),
        )
        XCTAssertEqual(state.analysisCount, 1)
    }

    func testPendingAnalysisHonorsSingleAnalysisPerSessionLimit() {
        let start = Date(timeIntervalSince1970: 4000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )
        state.analysisCount = 1

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state,
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(5),
                settleDelay: 2.5,
                maxAnalyses: 1,
            ),
        )
    }

    func testPendingAnalysisDoesNotTriggerSecondAnalysisInSameSession() {
        let start = Date(timeIntervalSince1970: 4500)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        AutomaticVocabularyMonitor.markAnalysisCompleted(for: "hello Doubao", state: &state)

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao SeedASR",
            at: start.addingTimeInterval(5),
            state: &state,
        )

        XCTAssertNil(
            AutomaticVocabularyMonitor.pendingAnalysis(
                state: state,
                now: start.addingTimeInterval(8),
                settleDelay: 2.5,
                maxAnalyses: 1,
            ),
        )
        XCTAssertEqual(state.analysisCount, 1)
    }

    func testDetectChangeExtractsNewLatinToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please review the prd draft",
            to: "Please review the PRDPlus draft",
        )

        XCTAssertEqual(change?.oldFragment, "prd")
        XCTAssertEqual(change?.newFragment, "PRDPlus")
        XCTAssertEqual(change?.candidateTerms, ["PRDPlus"])
    }

    func testDetectChangeExpandsIntraWordReplacementToWholeToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please open Redmi docs",
            to: "Please open Readme docs",
        )

        XCTAssertEqual(change?.oldFragment, "Redmi")
        XCTAssertEqual(change?.newFragment, "Readme")
        XCTAssertEqual(change?.candidateTerms, ["Readme"])
    }

    func testDetectChangeExpandsInsertedSuffixToWholeToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "I meant Readm",
            to: "I meant Readme",
        )

        XCTAssertEqual(change?.oldFragment, "Readm")
        XCTAssertEqual(change?.newFragment, "Readme")
        XCTAssertEqual(change?.candidateTerms, ["Readme"])
    }

    func testDetectChangeExpandsTechnicalVariantToWholeToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Switch to fooBar today",
            to: "Switch to foo_bar today",
        )

        XCTAssertEqual(change?.oldFragment, "fooBar")
        XCTAssertEqual(change?.newFragment, "foo_bar")
        XCTAssertEqual(change?.candidateTerms, ["foo_bar"])
    }

    func testDetectChangeExtractsNewHanToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "我在写豆包语音",
            to: "我在写豆包 SeedASR",
        )

        XCTAssertEqual(change?.candidateTerms, ["SeedASR"])
    }

    func testParseAcceptedTermsSupportsJSONObject() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["SeedASR","Qwen3-ASR","SeedASR"]}"#,
        )

        XCTAssertEqual(terms, ["SeedASR", "Qwen3-ASR"])
    }

    func testParseAcceptedTermsSupportsFencedJSONObject() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: """
            ```json
            {"terms":["mylxsw","cc-src-learning"]}
            ```
            """,
        )

        XCTAssertEqual(terms, ["mylxsw", "cc-src-learning"])
    }

    func testParseAcceptedTermsRejectsInvalidJSONFragments() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["```","{","}","terms\":[\"mylxsw\"]","mylxsw"]}"#,
        )

        XCTAssertEqual(terms, ["mylxsw"])
    }

    func testParseAcceptedTermsKeepsValidTechnicalTermsContainingJSON() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["JSONSchema","jsonrpc","fastjson2"]}"#,
        )

        XCTAssertEqual(terms, ["JSONSchema", "jsonrpc", "fastjson2"])
    }

    func testParseAcceptedTermsDoesNotFallbackToLineParsing() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: """
            ```json
            {"terms":["mylxsw","cc-src-learning"]
            ```
            """,
        )

        XCTAssertTrue(terms.isEmpty)
    }
}

// MARK: - Extended AutomaticVocabularyMonitor tests

final class AutomaticVocabularyMonitorExtendedTests: XCTestCase {
    // MARK: - makeObservationState

    func testMakeObservationStateInitializesCorrectly() {
        let start = Date(timeIntervalSince1970: 5000)
        let state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "initial text",
            startedAt: start,
        )
        XCTAssertEqual(state.settledText, "initial text")
        XCTAssertEqual(state.latestObservedText, "initial text")
        XCTAssertNil(state.lastChangedAt)
        XCTAssertNil(state.lastAnalyzedText)
        XCTAssertEqual(state.analysisCount, 0)
        XCTAssertEqual(state.sessionStartedAt, start)
    }

    func testMakeObservationStateWithDefaultDate() {
        let before = Date()
        let state = AutomaticVocabularyMonitor.makeObservationState(baselineText: "text")
        let after = Date()
        XCTAssertGreaterThanOrEqual(state.sessionStartedAt, before)
        XCTAssertLessThanOrEqual(state.sessionStartedAt, after)
    }

    // MARK: - observe()

    func testObserveReturnsFalseWhenTextUnchanged() {
        let start = Date(timeIntervalSince1970: 6000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "same text",
            startedAt: start,
        )
        let changed = AutomaticVocabularyMonitor.observe(
            text: "same text",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        XCTAssertFalse(changed)
    }

    func testObserveReturnsTrueWhenTextChanges() {
        let start = Date(timeIntervalSince1970: 7000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "original",
            startedAt: start,
        )
        let changed = AutomaticVocabularyMonitor.observe(
            text: "changed",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        XCTAssertTrue(changed)
    }

    func testObserveUpdatesLatestText() {
        let start = Date(timeIntervalSince1970: 8000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "original",
            startedAt: start,
        )
        _ = AutomaticVocabularyMonitor.observe(
            text: "new text",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        XCTAssertEqual(state.latestObservedText, "new text")
    }

    func testObserveSetsLastChangedAt() {
        let start = Date(timeIntervalSince1970: 9000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "original",
            startedAt: start,
        )
        let changeTime = start.addingTimeInterval(2)
        _ = AutomaticVocabularyMonitor.observe(
            text: "different",
            at: changeTime,
            state: &state,
        )
        XCTAssertEqual(state.lastChangedAt, changeTime)
    }

    // MARK: - markAnalysisCompleted

    func testMarkAnalysisCompletedUpdatesState() {
        let start = Date(timeIntervalSince1970: 10000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "original",
            startedAt: start,
        )
        _ = AutomaticVocabularyMonitor.observe(
            text: "new text",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        AutomaticVocabularyMonitor.markAnalysisCompleted(for: "new text", state: &state)
        XCTAssertEqual(state.lastAnalyzedText, "new text")
        XCTAssertEqual(state.settledText, "new text")
        XCTAssertEqual(state.analysisCount, 1)
    }

    // MARK: - detectChange() edge cases

    func testDetectChangeReturnsNilWhenTextsAreIdentical() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "identical text",
            to: "identical text",
        )
        XCTAssertNil(change)
    }

    func testDetectChangeReturnsNilWhenOnlyDeletionOccurs() {
        // "world world" -> "world" — deleted duplicate; expanded new fragment
        // contains only "world" which already appears in the old fragment
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "world world",
            to: "world",
        )
        XCTAssertNil(change)
    }

    func testDetectChangeHandlesMultipleTokenChanges() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please check the API documentation",
            to: "Please check the OpenAI API documentation",
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.candidateTerms, ["OpenAI"])
    }

    // MARK: - decisionSchema

    func testDecisionSchemaHasCorrectName() {
        XCTAssertEqual(AutomaticVocabularyMonitor.decisionSchema.name, "automatic_vocabulary_terms")
    }

    func testDecisionSchemaHasTermsProperty() {
        // The schema should contain a "terms" property
        let schemaJSON = AutomaticVocabularyMonitor.decisionSchema.jsonObject
        if let properties = schemaJSON["properties"] as? [String: Any] {
            XCTAssertNotNil(properties["terms"])
        } else {
            XCTFail("Schema should have 'properties' key")
        }
    }

    // MARK: - parseAcceptedTerms edge cases

    func testParseAcceptedTermsWithEmptyResponse() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(from: "")
        XCTAssertTrue(terms.isEmpty)
    }

    func testParseAcceptedTermsWithWhitespaceOnlyResponse() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(from: "   \n\n  ")
        XCTAssertTrue(terms.isEmpty)
    }

    func testParseAcceptedTermsWithEmptyTermsArray() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(from: #"{"terms":[]}"#)
        XCTAssertTrue(terms.isEmpty)
    }

    func testParseAcceptedTermsDeduplicatesTerms() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["SeedASR","SeedASR","Qwen3"]}"#,
        )
        XCTAssertEqual(terms, ["SeedASR", "Qwen3"])
    }

    func testParseAcceptedTermsFiltersVeryShortTerms() {
        // The schema specifies minLength: 2, so single-character terms should be filtered
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["A","valid-term"]}"#,
        )
        // "A" is length 1, likely filtered
        XCTAssertTrue(terms.contains("valid-term"))
        XCTAssertFalse(terms.contains("A"))
    }

    // MARK: - pendingAnalysis with settled text == latest observed

    func testPendingAnalysisReturnsNilWhenLatestTextEqualsSettledText() {
        let start = Date(timeIntervalSince1970: 11000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "same",
            startedAt: start,
        )
        // Force lastChangedAt to be set but keep latestObservedText == settledText
        state.lastChangedAt = start.addingTimeInterval(1)
        // latestObservedText == settledText == "same" (no change to text)
        let result = AutomaticVocabularyMonitor.pendingAnalysis(
            state: state,
            now: start.addingTimeInterval(5),
            settleDelay: 2.5,
            maxAnalyses: 3,
        )
        XCTAssertNil(result)
    }
}
