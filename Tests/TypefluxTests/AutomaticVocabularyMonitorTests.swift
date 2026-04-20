@testable import Typeflux
import XCTest

final class AutomaticVocabularyMonitorTests: XCTestCase {
    // MARK: - Observation lifecycle

    func testShouldTriggerAnalysisWaitsForIdleSettleDelay() {
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

        XCTAssertFalse(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(3),
                idleSettleDelay: 8,
            ),
        )

        XCTAssertTrue(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(9.1),
                idleSettleDelay: 8,
            ),
        )
    }

    func testShouldTriggerAnalysisResetsWhenUserKeepsEditing() {
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
            at: start.addingTimeInterval(5),
            state: &state,
        )

        // 5 + 8 = 13, we're only at 12 → not yet
        XCTAssertFalse(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(12),
                idleSettleDelay: 8,
            ),
        )

        XCTAssertTrue(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(13.1),
                idleSettleDelay: 8,
            ),
        )
    }

    func testShouldTriggerAnalysisReturnsFalseWhenNoChangeRecorded() {
        let start = Date(timeIntervalSince1970: 3000)
        let state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )
        XCTAssertFalse(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(60),
                idleSettleDelay: 8,
            ),
        )
    }

    func testShouldTriggerAnalysisReturnsFalseWhenTextReturnsToBaseline() {
        let start = Date(timeIntervalSince1970: 4000)
        var state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "hello world",
            startedAt: start,
        )

        _ = AutomaticVocabularyMonitor.observe(
            text: "hello Doubao",
            at: start.addingTimeInterval(1),
            state: &state,
        )
        _ = AutomaticVocabularyMonitor.observe(
            text: "hello world",
            at: start.addingTimeInterval(2),
            state: &state,
        )

        XCTAssertFalse(
            AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                state: state,
                now: start.addingTimeInterval(20),
                idleSettleDelay: 8,
            ),
        )
    }

    // MARK: - detectChange()

    func testDetectChangeExtractsNewLatinToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please review the prddraft text",
            to: "Please review the PRDPlus text",
        )

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

    func testDetectChangeExtractsNewHanToken() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "我在写豆包语音",
            to: "我在写豆包 SeedASR",
        )

        XCTAssertEqual(change?.candidateTerms, ["SeedASR"])
    }

    func testDetectChangeReturnsNilWhenTextsAreIdentical() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "identical text",
            to: "identical text",
        )
        XCTAssertNil(change)
    }

    func testDetectChangeHandlesMultipleTokenChanges() {
        let change = AutomaticVocabularyMonitor.detectChange(
            from: "Please check the APIRef documentation",
            to: "Please check the OpenAI APIRef documentation",
        )
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.candidateTerms, ["OpenAI"])
    }

    // MARK: - changeIsJustInitialInsertion

    func testChangeIsJustInitialInsertionDetectsExactMatch() {
        let change = AutomaticVocabularyChange(
            oldFragment: "",
            newFragment: "hello world",
            candidateTerms: ["hello", "world"],
        )
        XCTAssertTrue(
            AutomaticVocabularyMonitor.changeIsJustInitialInsertion(
                change: change,
                insertedText: "hello world",
            ),
        )
    }

    func testChangeIsJustInitialInsertionFalseWhenFragmentMerelyContainsInserted() {
        // Fragment contains the inserted text as a substring but also introduces
        // a brand-new token the user typed — this is a real follow-up edit and
        // must NOT be filtered out. Regression guard for the dropped contains() check.
        let change = AutomaticVocabularyChange(
            oldFragment: "Doubao",
            newFragment: "Doubao SeedASR",
            candidateTerms: ["SeedASR"],
        )
        XCTAssertFalse(
            AutomaticVocabularyMonitor.changeIsJustInitialInsertion(
                change: change,
                insertedText: "Doubao",
            ),
        )
    }

    func testChangeIsJustInitialInsertionFalseForRealEdit() {
        let change = AutomaticVocabularyChange(
            oldFragment: "prddraft",
            newFragment: "PRDPlus",
            candidateTerms: ["PRDPlus"],
        )
        XCTAssertFalse(
            AutomaticVocabularyMonitor.changeIsJustInitialInsertion(
                change: change,
                insertedText: "please review the prddraft text",
            ),
        )
    }

    func testChangeIsJustInitialInsertionDetectsWhenAllTokensFromInserted() {
        // Fragment extends beyond insertion boundary but all candidate tokens
        // come from the inserted text itself — still counts as initial insertion.
        let change = AutomaticVocabularyChange(
            oldFragment: "",
            newFragment: "SeedASR Doubao",
            candidateTerms: ["SeedASR", "Doubao"],
        )
        XCTAssertTrue(
            AutomaticVocabularyMonitor.changeIsJustInitialInsertion(
                change: change,
                insertedText: "please check SeedASR and Doubao",
            ),
        )
    }

    // MARK: - editRatio / isEditTooLarge

    func testEditRatioZeroForIdenticalBaselineAndFinal() {
        XCTAssertEqual(
            AutomaticVocabularyMonitor.editRatio(
                inserted: "hello world",
                baseline: "hello world",
                final: "hello world",
            ),
            0,
            accuracy: 0.001,
        )
    }

    func testEditRatioIsCaseInsensitive() {
        XCTAssertEqual(
            AutomaticVocabularyMonitor.editRatio(
                inserted: "HELLO",
                baseline: "HELLO",
                final: "hello",
            ),
            0,
            accuracy: 0.001,
        )
    }

    func testEditRatioSmallCorrection() {
        // 31-char insertion, user swaps "prddraft" (8) → "PRDPlus" (7).
        // Levenshtein distance ≈ 7, divided by insertedLen 31 ≈ 0.23.
        let ratio = AutomaticVocabularyMonitor.editRatio(
            inserted: "please review the prddraft text",
            baseline: "please review the prddraft text",
            final: "please review the PRDPlus text",
        )
        XCTAssertLessThan(ratio, 0.35)
    }

    func testEditRatioWholesaleRewrite() {
        let ratio = AutomaticVocabularyMonitor.editRatio(
            inserted: "hello world",
            baseline: "hello world",
            final: "this is a completely different sentence written by the user",
        )
        XCTAssertGreaterThan(ratio, 1.0)
    }

    func testEditRatioBailsOutAboveLengthLimit() {
        let longBaseline = String(repeating: "a", count: 2500)
        let longFinal = String(repeating: "b", count: 2500)
        XCTAssertEqual(
            AutomaticVocabularyMonitor.editRatio(
                inserted: "hello world",
                baseline: longBaseline,
                final: longFinal,
            ),
            1,
            accuracy: 0.001,
        )
    }

    func testEditRatioIgnoresSurroundingContextInLongDocument() {
        // User had a long document, inserted "hello world", made a tiny fix.
        // The long unchanged prefix should not swamp the ratio.
        let prefix = String(repeating: "x", count: 500)
        let ratio = AutomaticVocabularyMonitor.editRatio(
            inserted: "hello world",
            baseline: prefix + " hello world",
            final: prefix + " hello World!",
        )
        XCTAssertLessThan(ratio, 0.4)
    }

    func testIsEditTooLargeFalseForSmallCorrection() {
        XCTAssertFalse(
            AutomaticVocabularyMonitor.isEditTooLarge(
                inserted: "please review the prddraft text",
                baseline: "please review the prddraft text",
                final: "please review the PRDPlus text",
                ratioLimit: 0.6,
            ),
        )
    }

    func testIsEditTooLargeTrueForWholesaleRewrite() {
        XCTAssertTrue(
            AutomaticVocabularyMonitor.isEditTooLarge(
                inserted: "hello world",
                baseline: "hello world",
                final: "this is a completely different sentence written by the user",
                ratioLimit: 0.6,
            ),
        )
    }

    func testIsEditTooLargeTrueForLengthBailout() {
        let longBaseline = String(repeating: "a", count: 2500)
        let longFinal = String(repeating: "b", count: 2500)
        XCTAssertTrue(
            AutomaticVocabularyMonitor.isEditTooLarge(
                inserted: "hello world",
                baseline: longBaseline,
                final: longFinal,
                ratioLimit: 0.6,
            ),
        )
    }

    func testIsEditTooLargeFalseForShortFragmentOnLongInsertion() {
        XCTAssertFalse(
            AutomaticVocabularyMonitor.isEditTooLarge(
                inserted: "今天下午我们开会讨论了新产品的发布计划和市场策略",
                baseline: "今天下午我们开会讨论了新产品的发布计划和市场策略",
                final: "今天下午我们开会复盘了新产品的发布计划和市场策略",
                ratioLimit: 0.6,
            ),
        )
    }

    // MARK: - Parsing / acceptance rules

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

    func testParseAcceptedTermsRejectsShortEnglishTerms() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["A","AI","UI","GPT","GPT4"]}"#,
        )
        // A (1), AI (2), UI (2) rejected; GPT (3) and GPT4 (4) both pass under the
        // relaxed 3-char minimum for English/Latin acronyms.
        XCTAssertEqual(terms, ["GPT", "GPT4"])
    }

    func testParseAcceptedTermsRejectsPureDigits() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["123","12345","Rust"]}"#,
        )
        XCTAssertEqual(terms, ["Rust"])
    }

    func testParseAcceptedTermsAcceptsShortHanTerms() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(
            from: #"{"terms":["向量","推理","数","向量数据库"]}"#,
        )
        XCTAssertEqual(terms, ["向量", "推理", "向量数据库"])
    }

    func testParseAcceptedTermsWithEmptyResponse() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(from: "")
        XCTAssertTrue(terms.isEmpty)
    }

    func testParseAcceptedTermsWithEmptyTermsArray() {
        let terms = AutomaticVocabularyMonitor.parseAcceptedTerms(from: #"{"terms":[]}"#)
        XCTAssertTrue(terms.isEmpty)
    }

    // MARK: - State initialization

    func testMakeObservationStateInitializesCorrectly() {
        let start = Date(timeIntervalSince1970: 5000)
        let state = AutomaticVocabularyMonitor.makeObservationState(
            baselineText: "initial text",
            startedAt: start,
        )
        XCTAssertEqual(state.baselineText, "initial text")
        XCTAssertEqual(state.latestObservedText, "initial text")
        XCTAssertNil(state.lastChangedAt)
        XCTAssertEqual(state.sessionStartedAt, start)
    }

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

    // MARK: - decisionSchema

    func testDecisionSchemaHasCorrectName() {
        XCTAssertEqual(AutomaticVocabularyMonitor.decisionSchema.name, "automatic_vocabulary_terms")
    }
}
