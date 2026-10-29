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

    func testSidebarCreditAmountPreservesTwoDecimals() {
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(999), "999.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(1000), "1,000.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(1280), "1,280.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(4500), "4,500.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.sidebarCreditAmount(20000), "20,000.00")
    }

    func testCreditAmountAlwaysUsesTwoFractionDigits() {
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(0), "0.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(0.0001), "<0.01")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1.2345), "1.23")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997), "1,997.00")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997.5), "1,997.50")
        XCTAssertEqual(AccountUsageDisplayFormatter.creditAmount(1997.456), "1,997.46")
    }

    func testPercentageUsesTwoFractionDigits() {
        XCTAssertEqual(AccountUsageDisplayFormatter.percentage(0), "0.00%")
        XCTAssertEqual(AccountUsageDisplayFormatter.percentage(12.345), "12.35%")
    }
}
