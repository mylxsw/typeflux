@testable import Typeflux
import XCTest

final class AccountUsageCreditPresentationTests: XCTestCase {
    func testMissingCreditsDoNotBecomeZeroOrUnlimited() {
        let presentation = AccountUsageCreditPresentation(credits: nil)
        XCTAssertEqual(presentation.usage, .unavailable)
        XCTAssertNil(presentation.progress)
    }

    func testFiniteCreditsUseServerUsedAmountAndMatchingProgress() throws {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 90000, used: 9226, remaining: 80774, unlimited: false)
        )
        XCTAssertEqual(presentation.usage, .limited(used: 9226, limit: 90000))
        XCTAssertEqual(try XCTUnwrap(presentation.progress), 9226.0 / 90000, accuracy: 0.000001)

        let adjustedBalance = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 30, remaining: 55, unlimited: false)
        )
        XCTAssertEqual(adjustedBalance.usage, .limited(used: 30, limit: 100))
        XCTAssertEqual(adjustedBalance.progress, 0.3)
    }

    func testExhaustedCreditsClampMeterWithoutHidingOverage() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: 125, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(presentation.progress, 1)
        XCTAssertEqual(presentation.usageFraction, 1.25)
        XCTAssertEqual(presentation.usage, .limited(used: 125, limit: 100))
    }

    func testUnlimitedCreditsDoNotShowAFiniteMeter() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 0, used: 100, remaining: 0, unlimited: true)
        )
        XCTAssertEqual(presentation.usage, .unlimited(used: 100))
        XCTAssertNil(presentation.progress)
    }

    func testZeroLimitRemainsDistinctFromUnavailableAndUnlimited() {
        let presentation = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 0, used: 0, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(presentation.usage, .limited(used: 0, limit: 0))
        XCTAssertNil(presentation.progress)
    }

    func testInvalidLimitIsUnavailableAndNegativeUsageDoesNotDrawOutsideMeter() {
        let invalid = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: -1, used: 0, remaining: 0, unlimited: false)
        )
        XCTAssertEqual(invalid.usage, .unavailable)
        XCTAssertNil(invalid.progress)
        let corrected = AccountUsageCreditPresentation(
            credits: CloudCreditSummary(limit: 100, used: -5, remaining: 100, unlimited: false)
        )
        XCTAssertEqual(corrected.progress, 0)
    }
}
