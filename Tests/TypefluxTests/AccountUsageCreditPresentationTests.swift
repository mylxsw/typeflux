@testable import Typeflux
import XCTest

final class AccountUsageCreditPresentationTests: XCTestCase {
    func testMissingCreditsDoNotBecomeZeroOrUnlimited() {
        let presentation = AccountUsageCreditPresentation(credits: nil)
        XCTAssertEqual(presentation.balance, .unavailable)
        XCTAssertNil(presentation.progress)
    }

    func testFiniteCreditsUseServerRemainingAmountAndMatchingProgress() throws {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 90000, used: 9226, remaining: 80774, unlimited: false)
        )
        XCTAssertEqual(presentation.balance, .limited(remaining: 80774, limit: 90000))
        XCTAssertEqual(try XCTUnwrap(presentation.progress), 80774.0 / 90000, accuracy: 0.000001)

        let adjustedBalance = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 30, remaining: 55, unlimited: false)
        )
        XCTAssertEqual(adjustedBalance.balance, .limited(remaining: 55, limit: 100))
        XCTAssertEqual(adjustedBalance.progress, 0.55)
    }

    func testExhaustedCreditsShowEmptyMeterAndWarning() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 125, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(presentation.progress, 0)
        XCTAssertEqual(presentation.remainingFraction, 0)
        XCTAssertTrue(presentation.isExhausted)
        XCTAssertEqual(presentation.balance, .limited(remaining: 0, limit: 100))
    }

    func testUnlimitedCreditsDoNotShowAFiniteMeter() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: -1, used: 100, remaining: -1, unlimited: true)
        )
        XCTAssertEqual(presentation.balance, .unlimited)
        XCTAssertNil(presentation.progress)
    }

    func testZeroLimitRemainsDistinctFromUnavailableAndUnlimited() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 0, used: 0, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(presentation.balance, .limited(remaining: 0, limit: 0))
        XCTAssertNil(presentation.progress)
    }

    func testInvalidLimitIsUnavailableAndNegativeRemainingIsClamped() {
        let invalid = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: -1, used: 0, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(invalid.balance, .unavailable)
        XCTAssertNil(invalid.progress)
        let corrected = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 105, remaining: -5, unlimited: false)
        )
        XCTAssertEqual(corrected.progress, 0)
        XCTAssertEqual(corrected.balance, .limited(remaining: 0, limit: 100))
    }

    func testUnusedCreditsShowFullMeterWithoutWarning() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 0, remaining: 100, unlimited: false)
        )
        XCTAssertEqual(presentation.progress, 1)
        XCTAssertEqual(presentation.balance, .limited(remaining: 100, limit: 100))
        XCTAssertFalse(presentation.isExhausted)
    }

    func testExtraRemainingCreditsClampOnlyTheMeter() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 0, remaining: 120, unlimited: false)
        )
        XCTAssertEqual(presentation.balance, .limited(remaining: 120, limit: 100))
        XCTAssertEqual(presentation.progress, 1)
        XCTAssertFalse(presentation.isExhausted)
    }
}
