import Foundation
import Testing
@testable import Typeflux

@Suite("Account credit chart")
struct AccountCreditChartTests {
    static func breakdown(start: String = "2026-09-30T16:00:00Z", end: String = "2026-10-31T16:00:00Z",
                          zone: String = "Asia/Shanghai",
                          days: [CloudUsageBreakdown.Day] = []) -> CloudUsageBreakdown {
        CloudUsageBreakdown(periodStart: start, periodEnd: end, timezone: zone, days: days,
                            voice: days.reduce(0) { $0 + $1.voice }, rewrite: days.reduce(0) { $0 + $1.rewrite },
                            ask: days.reduce(0) { $0 + $1.ask })
    }

    static func date(_ value: String) -> Date { ISO8601DateFormatter.typefluxBillingDate(from: value)! }

    @Test func oneBarPerLocalDayWithFutureDaysEmpty() {
        let value = Self.breakdown(days: [
            .init(date: "2026-10-01", voice: 10, rewrite: 5, ask: 0),
            .init(date: "2026-10-05", voice: 0, rewrite: 0, ask: 7)
        ])
        // Oct 5, 12:00 in Shanghai.
        let bars = AccountCreditChart.bars(value, now: Self.date("2026-10-05T04:00:00Z"))
        #expect(bars.count == 31)
        #expect(bars[0].credits == 15)
        #expect(bars[4].credits == 7)
        #expect(bars[4].isToday)
        #expect(!bars[4].isFuture)
        #expect(bars[5].isFuture)
        #expect(bars.filter(\.isToday).count == 1)
        #expect(bars[1].credits == 0)
    }

    @Test func longPeriodsShowTheLatestMonthUpToToday() {
        let value = Self.breakdown(start: "2026-01-01T00:00:00Z", end: "2027-01-01T00:00:00Z", zone: "UTC",
                                   days: [.init(date: "2026-06-30", voice: 4, rewrite: 0, ask: 0)])
        let bars = AccountCreditChart.bars(value, now: Self.date("2026-06-30T10:00:00Z"))
        #expect(bars.count == AccountCreditChart.maxBars)
        #expect(bars.last?.isToday == true)
        #expect(bars.last?.credits == 4)
        // Before the period starts the window begins at day one.
        let early = AccountCreditChart.bars(value, now: Self.date("2025-12-01T00:00:00Z"))
        #expect(early.count == AccountCreditChart.maxBars)
        #expect(early.first?.day == Self.date("2026-01-01T00:00:00Z"))
    }

    @Test func invalidPeriodsDrawNothing() {
        #expect(AccountCreditChart.bars(Self.breakdown(start: "bad")).isEmpty)
        #expect(AccountCreditChart.bars(Self.breakdown(start: "2026-10-02T00:00:00Z",
                                                       end: "2026-10-01T00:00:00Z")).isEmpty)
    }

    @Test func unknownTimeZoneFallsBackToTheCurrentOne() {
        let calendar = AccountCreditChart.calendar(for: Self.breakdown(zone: "Mars/Olympus"))
        #expect(calendar.timeZone == .current)
    }

    @Test func todayLabelSitsUnderItsBarAwayFromTheEnds() {
        #expect(AccountCreditChart.todayLabelCenter(index: 15, count: 31, width: 310, clearance: 56) == 155)
        #expect(AccountCreditChart.todayLabelCenter(index: 1, count: 31, width: 310, clearance: 56) == nil)
        #expect(AccountCreditChart.todayLabelCenter(index: 30, count: 31, width: 310, clearance: 56) == nil)
        #expect(AccountCreditChart.todayLabelCenter(index: 0, count: 0, width: 310, clearance: 56) == nil)
        #expect(AccountCreditChart.todayLabelCenter(index: 3, count: 5, width: 100, clearance: 56) == nil)
    }

    @Test func sharesSplitTheTotalInAFixedOrder() {
        let value = Self.breakdown(days: [.init(date: "2026-10-01", voice: 50, rewrite: 30, ask: 20)])
        let shares = AccountCreditChart.shares(value)
        #expect(shares.map(\.feature) == [.voice, .rewrite, .ask])
        #expect(shares.map(\.credits) == [50, 30, 20])
        #expect(abs(shares[0].fraction - 0.5) < 0.0001)
        #expect(AccountCreditChart.shares(Self.breakdown()).isEmpty)
        #expect(value.total == 100)
        #expect(value.days[0].total == 100)
    }

    @Test func breakdownDecodesTheServerPayload() throws {
        let json = """
        {"period_start":"2026-10-01T00:00:00Z","period_end":"2026-11-01T00:00:00Z","timezone":"UTC",
         "days":[{"date":"2026-10-01","voice":1,"rewrite":2,"ask":3}],"voice":1,"rewrite":2,"ask":3}
        """
        let value = try JSONDecoder().decode(CloudUsageBreakdown.self, from: Data(json.utf8))
        #expect(value.timezone == "UTC")
        #expect(value.days == [.init(date: "2026-10-01", voice: 1, rewrite: 2, ask: 3)])
        #expect(value.total == 6)
    }
}

@Suite("Account status text")
struct AccountStatusTextTests {
    let locale = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter.typefluxBillingDate(from: "2026-10-02T00:00:00Z")!
    let nov1 = ISO8601DateFormatter.typefluxBillingDate(from: "2026-11-01T00:00:00Z")!

    @Test func shortDateAddsTheYearOnlyWhenItDiffers() {
        #expect(AccountStatusText.shortDate(nov1, locale: locale, timeZone: utc, now: now) == "Nov 1")
        let next = ISO8601DateFormatter.typefluxBillingDate(from: "2027-01-05T00:00:00Z")!
        #expect(AccountStatusText.shortDate(next, locale: locale, timeZone: utc, now: now) == "Jan 5, 2027")
    }

    @Test func everyStateHasWording() {
        let badges: [AccountStatusPresentation.Badge] = [.plan("Pro"), .low(percent: 12), .exhausted]
        for badge in badges { #expect(!AccountStatusText.badge(badge).isEmpty) }
        #expect(AccountStatusText.badge(.plan("Pro")) == "Pro")
        #expect(AccountStatusText.badge(.low(percent: 12)).contains("12%"))

        let notes: [AccountStatusPresentation.PeriodNote] = [.resets(nov1), .renews(nov1), .ends(nov1), .paymentFailed]
        for note in notes {
            let text = AccountStatusText.period(note, locale: locale, timeZone: utc, now: now)
            #expect(!text.isEmpty && !text.hasPrefix("account."))
        }

        let offers: [AccountStatusPresentation.Offer] = [
            .upgrade, .lowQuota(daysLeft: 3, canUpgrade: true), .lowQuota(daysLeft: nil, canUpgrade: false),
            .exhausted(canUpgrade: true), .exhausted(canUpgrade: false), .restore(endsOn: nov1), .restore(endsOn: nil),
            .fixPayment
        ]
        for offer in offers {
            let copy = AccountStatusText.offer(offer, locale: locale, timeZone: utc, now: now)
            #expect(!copy.title.hasPrefix("account.") && !copy.detail.hasPrefix("account."), "\(offer)")
        }
        #expect(AccountStatusText.offer(.lowQuota(daysLeft: 3, canUpgrade: true), locale: locale).detail.contains("3"))
        #expect(AccountStatusText.offer(.lowQuota(daysLeft: nil, canUpgrade: false), locale: locale).action == nil)
        #expect(AccountStatusText.offer(.exhausted(canUpgrade: false), locale: locale).action == nil)
        #expect(AccountStatusText.offer(.fixPayment, locale: locale).action != nil)
    }

    @Test func providersAndNumbers() {
        #expect(AccountStatusText.provider("github").contains("GitHub"))
        #expect(AccountStatusText.provider("google").contains("Google"))
        #expect(AccountStatusText.provider("apple").contains("Apple"))
        #expect(!AccountStatusText.provider("password").isEmpty)
        #expect(AccountStatusText.provider("sso") == "sso")
        #expect(AccountStatusText.percent(0.284) == "28%")
        #expect(AccountStatusText.percent(-1) == "0%")
        #expect(AccountStatusText.quotaPair(remaining: 1_420_560, limit: 2_000_000, compact: true) == "1.42M / 2M")
        #expect(AccountStatusText.quotaPair(remaining: 9000, limit: 60000, compact: true) == "9K / 60K")
        #expect(AccountStatusText.quotaPair(remaining: 58500, limit: 60000, compact: true) == "58.5K / 60K")
        // Rounded down, so a nearly empty quota never reads as full.
        #expect(AccountStatusText.quotaPair(remaining: 59999, limit: 60000, compact: true) == "59.9K / 60K")
        #expect(AccountStatusText.quotaPair(remaining: 900, limit: 2000, compact: true) == "900 / 2,000")
        #expect(AccountStatusText.quotaPair(remaining: 0, limit: 60000, compact: true) == "0 / 60K")
        #expect(AccountStatusText.quotaPair(remaining: 52782, limit: 60000, compact: false).contains("52,782"))
    }
}
