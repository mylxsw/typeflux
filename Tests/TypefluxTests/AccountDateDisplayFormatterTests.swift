import Foundation
@testable import Typeflux
import XCTest

final class AccountDateDisplayFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRelativeTimeUsesAppLocaleAndAdvancesWithTheClock() {
        let lastSync = now.addingTimeInterval(-120)
        XCTAssertEqual(
            AccountDateDisplayFormatter.relativeTime(since: lastSync, now: now, locale: Locale(identifier: "en")),
            "2 minutes ago"
        )
        XCTAssertEqual(
            AccountDateDisplayFormatter.relativeTime(
                since: lastSync, now: now.addingTimeInterval(60), locale: Locale(identifier: "en")
            ),
            "3 minutes ago"
        )
        XCTAssertEqual(
            AccountDateDisplayFormatter.relativeTime(since: lastSync, now: now, locale: Locale(identifier: "zh-Hans")),
            "2分钟前"
        )
    }

    func testFutureSyncTimestampIsClampedAfterClockCorrection() {
        for language in AppLanguage.allCases {
            let locale = Locale(identifier: language.localeIdentifier)
            XCTAssertEqual(
                AccountDateDisplayFormatter.relativeTime(since: now.addingTimeInterval(600), now: now, locale: locale),
                AccountDateDisplayFormatter.relativeTime(since: now, now: now, locale: locale)
            )
        }
    }

    func testBillingDateUsesSelectedLanguageForBothISOFormats() {
        for value in ["2026-09-20T00:00:00Z", "2026-09-20T00:00:00.000Z"] {
            XCTAssertEqual(
                AccountDateDisplayFormatter.date(
                    value, locale: Locale(identifier: "zh-Hans"), timeZone: TimeZone(secondsFromGMT: 0)!
                ),
                "2026年9月20日"
            )
            XCTAssertEqual(
                AccountDateDisplayFormatter.date(
                    value, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!
                ),
                "Sep 20, 2026"
            )
        }
    }

    func testBillingDatePreservesUserTimeZoneAndUnknownValues() {
        XCTAssertEqual(
            AccountDateDisplayFormatter.date(
                "2026-09-20T23:00:00Z", locale: Locale(identifier: "zh-Hans"),
                timeZone: TimeZone(secondsFromGMT: 8 * 3600)!
            ),
            "2026年9月21日"
        )
        XCTAssertEqual(
            AccountDateDisplayFormatter.date("unknown-date", locale: Locale(identifier: "en")),
            "unknown-date"
        )
    }
}
