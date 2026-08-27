@testable import Typeflux
import XCTest

final class AccountUsageDisplayFormatterTests: XCTestCase {
    func testCountUsesGroupedRawValueForSmallNumbers() {
        XCTAssertEqual(AccountUsageDisplayFormatter.count(0), "0")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(999), "999")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(9999), "9,999")
    }

    func testCountUsesCompactSuffixesForLargeNumbers() {
        XCTAssertEqual(AccountUsageDisplayFormatter.count(10000), "10K")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(10235), "10.2K")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(1_234_567), "1.23M")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(12_345_678), "12.3M")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(1_234_567_890), "1.23B")
        XCTAssertEqual(AccountUsageDisplayFormatter.count(1_234_567_890_123), "1.23T")
    }

    func testCountPromotesRoundedBoundaryToNextSuffix() {
        XCTAssertEqual(AccountUsageDisplayFormatter.count(999_950), "1M")
    }

    func testCountPreservesNegativeSign() {
        XCTAssertEqual(AccountUsageDisplayFormatter.count(-12345), "-12.3K")
    }

    func testSidebarCreditAmountAbbreviatesFromOneThousandWithLowercaseK() {
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(999), "999")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(1000), "1k")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(1280), "1.3k")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(4500), "4.5k")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(20000), "20k")
    }

    func testCreditAmountUsesUpToTwoFractionDigits() {
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(0), "0")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997), "1,997")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997.5), "1,997.5")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997.456), "1,997.46")
    }

    func testPercentageUsesTwoFractionDigits() {
        XCTAssertEqual(AccountUsageDisplayFormatter.percentage(0), "0.00%")
        XCTAssertEqual(AccountUsageDisplayFormatter.percentage(12.345), "12.35%")
    }
}
