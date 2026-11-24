@testable import Typeflux
import XCTest

final class LLMRewriteTimeoutPolicyTests: XCTestCase {
    func testShortTextUsesConfiguredBaseBudget() {
        let budget = LLMRewriteTimeoutPolicy.budget(
            sourceText: String(repeating: "中", count: 100),
            baseSeconds: 10
        )

        XCTAssertEqual(budget.estimatedInputUnits, 100)
        XCTAssertEqual(budget.baseSeconds, 10)
        XCTAssertEqual(budget.firstOutputSeconds, 10)
        XCTAssertEqual(budget.stallSeconds, 10)
        XCTAssertEqual(budget.totalSeconds, 10)
        XCTAssertEqual(budget.watchdogSeconds, 20)
    }

    func testLongChineseTextAddsTwoSecondsPerFiftyUnits() {
        let expected: [(characters: Int, timeout: TimeInterval)] = [
            (200, 14),
            (500, 26),
            (1_000, 46),
            (1_500, 66)
        ]

        for item in expected {
            let budget = LLMRewriteTimeoutPolicy.budget(
                sourceText: String(repeating: "中", count: item.characters),
                baseSeconds: 10
            )
            XCTAssertEqual(budget.totalSeconds, item.timeout)
        }
    }

    func testCompactASCIIUsesApproximatelyOneUnitPerFourCharacters() {
        let sourceText = String(repeating: "a", count: 400)
        let budget = LLMRewriteTimeoutPolicy.budget(sourceText: sourceText, baseSeconds: 5)

        XCTAssertEqual(budget.estimatedInputUnits, 100)
        XCTAssertEqual(budget.totalSeconds, 5)
    }

    func testWhitespaceDoesNotIncreaseEstimatedInputUnits() {
        let budget = LLMRewriteTimeoutPolicy.budget(
            sourceText: "中\n\t   文",
            baseSeconds: 10
        )

        XCTAssertEqual(budget.estimatedInputUnits, 2)
    }

    func testTotalBudgetIsCappedAtOneHundredTwentySeconds() {
        let budget = LLMRewriteTimeoutPolicy.budget(
            sourceText: String(repeating: "中", count: 10_000),
            baseSeconds: 10
        )

        XCTAssertEqual(budget.totalSeconds, 120)
        XCTAssertEqual(budget.watchdogSeconds, 130)
    }

    func testFirstOutputBudgetGrowsButStopsAtTwentySecondsForSmallBase() {
        let medium = LLMRewriteTimeoutPolicy.budget(
            sourceText: String(repeating: "中", count: 1_000),
            baseSeconds: 10
        )
        let veryLong = LLMRewriteTimeoutPolicy.budget(
            sourceText: String(repeating: "中", count: 10_000),
            baseSeconds: 10
        )

        XCTAssertEqual(medium.firstOutputSeconds, 17.5)
        XCTAssertEqual(medium.stallSeconds, 15)
        XCTAssertEqual(veryLong.firstOutputSeconds, 20)
    }

    func testLargerConfiguredBaseRemainsTheMinimum() {
        let budget = LLMRewriteTimeoutPolicy.budget(
            sourceText: String(repeating: "中", count: 200),
            baseSeconds: 40
        )

        XCTAssertEqual(budget.firstOutputSeconds, 40)
        XCTAssertEqual(budget.stallSeconds, 40)
        XCTAssertEqual(budget.totalSeconds, 44)
    }
}
