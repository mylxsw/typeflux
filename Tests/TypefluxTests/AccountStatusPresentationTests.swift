import Foundation
import Testing
@testable import Typeflux

@Suite("Account status presentation")
struct AccountStatusPresentationTests {
    static let start = "2026-10-01T00:00:00Z"
    static let end = "2026-11-01T00:00:00Z"
    /// Ten days into a 31-day period.
    static let now = ISO8601DateFormatter.typefluxBillingDate(from: "2026-10-11T00:00:00Z")!

    static func snapshot(plan: String?, status: String?, paid: Bool, billing: Bool = true,
                         cancel: Bool = false, entitled: Bool = true,
                         periodEnd: String? = "2026-12-01T00:00:00Z") -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(planCode: plan, status: status, currentPeriodStart: start,
                                    currentPeriodEnd: periodEnd, cancelAtPeriodEnd: cancel, entitled: entitled,
                                    paid: paid, billingEnabled: billing)
    }

    static func credits(used: Int, limit: Int = 1000, unlimited: Bool = false) -> CloudCreditSummary {
        CloudCreditSummary(limit: limit, used: used, remaining: limit - used, unlimited: unlimited)
    }

    static func make(_ snapshot: BillingSubscriptionSnapshot, _ credits: CloudCreditSummary?,
                     start: String? = start, end: String? = end) -> AccountStatusPresentation {
        AccountStatusPresentation.make(subscription: snapshot, credits: credits,
                                       usagePeriodStart: start, usagePeriodEnd: end, now: now)
    }

    static let free = snapshot(plan: "free", status: "free", paid: false)
    static let pro = snapshot(plan: "pro", status: "active", paid: true)

    @Test func freeUserGetsAGreyBadgeAndTheUpgradeOffer() {
        let value = Self.make(Self.free, Self.credits(used: 100))
        #expect(value.badge == .plan("Free"))
        #expect(value.badgeTone == .neutral)
        #expect(value.level == .normal)
        #expect(value.offer == .upgrade)
        #expect(value.offerDestination == .plans)
        #expect(value.offerTone == .accent)
        #expect(value.billingLink == .plans)
        #expect(value.periodNote == .resets(ISO8601DateFormatter.typefluxBillingDate(from: Self.end)!))
    }

    @Test func healthyProIsNotSoldAnything() {
        let value = Self.make(Self.pro, Self.credits(used: 100))
        #expect(value.badge == .plan("Pro"))
        #expect(value.badgeTone == .accent)
        #expect(value.offer == nil)
        #expect(value.offerDestination == nil)
        #expect(value.billingLink == .billingPortal)
        #expect(value.periodNote == .renews(ISO8601DateFormatter.typefluxBillingDate(from: "2026-12-01T00:00:00Z")!))
    }

    @Test func lowQuotaTurnsTheBadgeAmberWithAForecast() {
        // 850 of 1000 used in 10 days: 85/day, 150 left → 2 days.
        let value = Self.make(Self.free, Self.credits(used: 850))
        #expect(value.badge == .low(percent: 15))
        #expect(value.badgeTone == .warning)
        #expect(value.level == .low)
        #expect(value.offer == .lowQuota(daysLeft: 2, canUpgrade: true))
        #expect(value.offerDestination == .plans)
        #expect(value.offerTone == .warning)
    }

    @Test func lowProQuotaWarnsWithoutAnUpgradeButton() {
        let value = Self.make(Self.pro, Self.credits(used: 900))
        #expect(value.offer == .lowQuota(daysLeft: 2, canUpgrade: false))
        #expect(value.offerDestination == nil)
    }

    @Test func lowBadgeNeverRoundsDownToZero() {
        let value = Self.make(Self.free, Self.credits(used: 999))
        #expect(value.badge == .low(percent: 1))
    }

    @Test func exhaustedQuotaIsRed() {
        let free = Self.make(Self.free, Self.credits(used: 1000))
        #expect(free.badge == .exhausted)
        #expect(free.badgeTone == .danger)
        #expect(free.offer == .exhausted(canUpgrade: true))
        #expect(free.offerDestination == .plans)
        #expect(free.offerTone == .danger)
        let pro = Self.make(Self.pro, Self.credits(used: 1000))
        #expect(pro.offer == .exhausted(canUpgrade: false))
        #expect(pro.offerDestination == nil)
    }

    @Test func pastDueAsksToFixThePaymentInThePortal() {
        for status in ["past_due", "unpaid", "incomplete", " PAST_DUE "] {
            let snapshot = Self.snapshot(plan: "pro", status: status, paid: true, entitled: false)
            let value = Self.make(snapshot, Self.credits(used: 1000))
            #expect(value.badge == .plan("Pro"), "\(status)")
            #expect(value.badgeTone == .danger)
            #expect(value.offer == .fixPayment)
            #expect(value.offerDestination == .billingPortal)
            #expect(value.billingLink == .billingPortal)
            #expect(value.periodNote == .paymentFailed)
        }
    }

    @Test func cancelledAtPeriodEndOffersToRestore() {
        let snapshot = Self.snapshot(plan: "pro", status: "active", paid: true, cancel: true)
        let value = Self.make(snapshot, Self.credits(used: 100))
        let end = ISO8601DateFormatter.typefluxBillingDate(from: "2026-12-01T00:00:00Z")!
        #expect(value.offer == .restore(endsOn: end))
        #expect(value.offerDestination == .billingPortal)
        #expect(value.periodNote == .ends(end))
        let undated = Self.make(Self.snapshot(plan: "pro", status: "active", paid: true, cancel: true, periodEnd: nil),
                                nil)
        #expect(undated.offer == .restore(endsOn: nil))
    }

    @Test func withoutBillingThereIsNoPlanToSell() {
        let snapshot = Self.snapshot(plan: "free", status: "free", paid: false, billing: false)
        let value = Self.make(snapshot, Self.credits(used: 10))
        #expect(value.badge == nil)
        #expect(value.offer == nil)
        #expect(value.billingLink == nil)
        let low = Self.make(snapshot, Self.credits(used: 900))
        #expect(low.offer == .lowQuota(daysLeft: 2, canUpgrade: false))
    }

    @Test func unlimitedAndMissingCreditsStayCalm() {
        let unlimited = Self.make(Self.pro, Self.credits(used: 5000, limit: 0, unlimited: true))
        #expect(unlimited.level == .normal)
        #expect(unlimited.forecast == nil)
        let missing = Self.make(Self.free, nil, start: nil, end: nil)
        #expect(missing.level == .normal)
        #expect(missing.offer == .upgrade)
        // Falls back to the subscription's period end.
        #expect(missing.periodNote == .resets(ISO8601DateFormatter.typefluxBillingDate(from: "2026-12-01T00:00:00Z")!))
        let nothing = Self.make(.none, nil, start: nil, end: nil)
        #expect(nothing.badge == nil)
        #expect(nothing.periodNote == nil)
    }

    @Test func localAskShowsOwnModelsUnlessSomethingNeedsAttention() {
        let pro = Self.make(Self.pro, Self.credits(used: 100))
        #expect(pro.footerBadge(runsLocally: false).badge == .plan("Pro"))
        #expect(pro.footerBadge(runsLocally: true).badge == .ownModels)
        #expect(pro.footerBadge(runsLocally: true).tone == .neutral)
        let noBilling = Self.make(Self.snapshot(plan: "free", status: "free", paid: false, billing: false), nil)
        #expect(noBilling.footerBadge(runsLocally: true).badge == .ownModels)
        let low = Self.make(Self.free, Self.credits(used: 900))
        #expect(low.footerBadge(runsLocally: true).badge == .low(percent: 10))
        let pastDue = Self.make(Self.snapshot(plan: "pro", status: "past_due", paid: true, entitled: false), nil)
        #expect(pastDue.footerBadge(runsLocally: true).tone == .danger)
    }

    @Test func planNamesComeFromTheServerWhenUnknown() {
        let team = Self.snapshot(plan: "team", status: "active", paid: true)
        #expect(AccountStatusPresentation.planName(for: team) == "Team")
        var named = Self.snapshot(plan: "biz_max", status: "active", paid: true)
        #expect(AccountStatusPresentation.planName(for: named) == "Biz Max")
        named = BillingSubscriptionSnapshot(planCode: "biz", status: "active", currentPeriodStart: nil,
                                            currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true,
                                            planName: " Business ", paid: true, billingEnabled: true)
        #expect(AccountStatusPresentation.planName(for: named) == "Business")
        #expect(AccountStatusPresentation.planName(for: .none) == nil)
        // A payment issue on an unnamed plan still shows a red badge.
        let unnamed = Self.snapshot(plan: nil, status: "past_due", paid: true, entitled: false)
        #expect(Self.make(unnamed, nil).badge == .plan("Pro"))
    }
}

@Suite("Account usage forecast")
struct AccountUsageForecastTests {
    let start = ISO8601DateFormatter.typefluxBillingDate(from: "2026-10-01T00:00:00Z")!
    let end = ISO8601DateFormatter.typefluxBillingDate(from: "2026-11-01T00:00:00Z")!

    func credits(_ used: Int, limit: Int = 1000) -> CloudCreditSummary {
        CloudCreditSummary(limit: limit, used: used, remaining: limit - used, unlimited: false)
    }

    @Test func projectsThePaceToTheEndOfThePeriod() throws {
        let now = start.addingTimeInterval(end.timeIntervalSince(start) / 4)
        let forecast = try #require(AccountUsageForecast.make(credits: credits(100), periodStart: start,
                                                              periodEnd: end, now: now))
        #expect(abs(forecast.usedFraction - 0.1) < 0.0001)
        #expect(abs(forecast.elapsedFraction - 0.25) < 0.0001)
        #expect(abs((forecast.projectedFraction ?? 0) - 0.4) < 0.0001)
        #expect(forecast.daysUntilExhausted == nil)
        #expect(!forecast.runsOut)
    }

    @Test func countsTheDaysLeftWhenThePaceRunsOut() throws {
        let now = start.addingTimeInterval(10 * 86400)
        let forecast = try #require(AccountUsageForecast.make(credits: credits(500), periodStart: start,
                                                              periodEnd: end, now: now))
        // 50/day with 500 left → 10 days, before the 21 left in the period.
        #expect(forecast.daysUntilExhausted == 10)
        #expect(forecast.runsOut)
    }

    @Test func waitsHalfADayBeforeExtrapolating() throws {
        let forecast = try #require(AccountUsageForecast.make(credits: credits(500), periodStart: start,
                                                              periodEnd: end, now: start.addingTimeInterval(3600)))
        #expect(forecast.projectedFraction == nil)
        #expect(forecast.daysUntilExhausted == nil)
        #expect(forecast.usedFraction == 0.5)
    }

    @Test func rejectsWhatCannotBeForecast() {
        let now = start.addingTimeInterval(86400 * 5)
        #expect(AccountUsageForecast.make(credits: nil, periodStart: start, periodEnd: end, now: now) == nil)
        #expect(AccountUsageForecast.make(credits: credits(1, limit: 0), periodStart: start, periodEnd: end,
                                          now: now) == nil)
        let unlimited = CloudCreditSummary(limit: 10, used: 1, remaining: 9, unlimited: true)
        #expect(AccountUsageForecast.make(credits: unlimited, periodStart: start, periodEnd: end, now: now) == nil)
        #expect(AccountUsageForecast.make(credits: credits(1), periodStart: end, periodEnd: start, now: now) == nil)
        #expect(AccountUsageForecast.make(credits: credits(1), periodStart: nil, periodEnd: end, now: now) == nil)
    }

    @Test func clampsTimeAndUsageIntoThePeriod() throws {
        let after = try #require(AccountUsageForecast.make(credits: credits(1500), periodStart: start, periodEnd: end,
                                                           now: end.addingTimeInterval(86400)))
        #expect(after.elapsedFraction == 1)
        #expect(after.usedFraction == 1)
        #expect(after.daysUntilExhausted == nil)
        let unused = try #require(AccountUsageForecast.make(credits: credits(0), periodStart: start, periodEnd: end,
                                                            now: start.addingTimeInterval(86400 * 3)))
        #expect(unused.projectedFraction == 0)
        #expect(unused.daysUntilExhausted == nil)
    }
}
