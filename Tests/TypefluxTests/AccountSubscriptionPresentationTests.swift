@testable import Typeflux
import XCTest

final class AccountSubscriptionPresentationTests: XCTestCase {
    func testNoSubscriptionSelectsSubscribeActionAndRequiredCopy() {
        let presentation = AccountSubscriptionPresentation.make(from: .none)

        XCTAssertEqual(presentation.billingAction, .subscribe)
        XCTAssertEqual(presentation.subtitleKey, "auth.account.subscriptionRequiredHint")
        XCTAssertEqual(presentation.plan, .localized("auth.account.subscriptionNoPlan"))
        XCTAssertEqual(presentation.status, .localized("auth.account.subscriptionStatusNone"))
        XCTAssertEqual(presentation.periodLabelKey, "auth.account.subscriptionPeriod")
        XCTAssertEqual(presentation.period, .unavailable)
        XCTAssertFalse(presentation.showsSubscriptionSyncAction)
    }

    func testActiveDefaultPlanSelectsManageBillingAndRenewalPeriod() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: "2026-05-01T00:00:00Z",
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true
        )

        let presentation = AccountSubscriptionPresentation.make(from: snapshot)

        XCTAssertEqual(presentation.billingAction, .manageBilling)
        XCTAssertEqual(presentation.subtitleKey, "auth.account.subscriptionActiveHint")
        XCTAssertEqual(presentation.plan, .localized("auth.account.subscriptionDefaultPlan"))
        XCTAssertEqual(presentation.status, .localized("auth.account.subscriptionStatusActive"))
        XCTAssertEqual(presentation.periodLabelKey, "auth.account.subscriptionPeriod")
        XCTAssertEqual(presentation.period, .renewsOn("2026-06-01T00:00:00Z"))
        XCTAssertFalse(presentation.showsSubscriptionSyncAction)
    }

    func testBillingEnabledFreePlanShowsSubscriptionSyncAction() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: "free",
            status: "free",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: true,
            active: true,
            paid: false,
            periodSource: "free",
            billingEnabled: true
        )

        XCTAssertTrue(AccountSubscriptionPresentation.make(from: snapshot).showsSubscriptionSyncAction)
    }

    func testBillingDisabledUnpaidPlanHidesSubscriptionSyncAction() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: "free",
            status: "free",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: true,
            active: true,
            paid: false,
            periodSource: "free",
            billingEnabled: false
        )

        XCTAssertFalse(AccountSubscriptionPresentation.make(from: snapshot).showsSubscriptionSyncAction)
    }

    func testFreePlanIsActiveButSelectsSubscribeAction() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: "free",
            status: "free",
            currentPeriodStart: "2026-05-12T00:00:00Z",
            currentPeriodEnd: "2026-06-12T00:00:00Z",
            cancelAtPeriodEnd: false,
            entitled: true,
            planName: "Free",
            active: true,
            paid: false,
            periodSource: "free"
        )

        let presentation = AccountSubscriptionPresentation.make(from: snapshot)

        XCTAssertEqual(presentation.billingAction, .subscribe)
        XCTAssertEqual(presentation.subtitleKey, "auth.account.subscriptionFreeHint")
        XCTAssertEqual(presentation.plan, .localized("auth.account.subscriptionFreePlan"))
        XCTAssertEqual(presentation.status, .localized("auth.account.subscriptionStatusAvailable"))
        XCTAssertEqual(presentation.periodLabelKey, "auth.account.subscriptionBillingCycle")
        XCTAssertEqual(
            presentation.period,
            .cycle(start: "2026-05-12T00:00:00Z", end: "2026-06-12T00:00:00Z")
        )
    }

    func testCancelAtPeriodEndUsesEndsOnPeriodCopy() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: BillingPlan.defaultPlanCode,
            status: "active",
            currentPeriodStart: "2026-05-01T00:00:00Z",
            currentPeriodEnd: "2026-06-01T00:00:00Z",
            cancelAtPeriodEnd: true,
            entitled: true
        )

        let presentation = AccountSubscriptionPresentation.make(from: snapshot)

        XCTAssertEqual(presentation.period, .endsOn("2026-06-01T00:00:00Z"))
    }

    func testCustomStatusAndPlanUseReadableLiteralFallbacks() {
        let snapshot = BillingSubscriptionSnapshot(
            planCode: "team_yearly",
            status: "requires_action",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: false
        )

        let presentation = AccountSubscriptionPresentation.make(from: snapshot)

        XCTAssertEqual(presentation.billingAction, .manageBilling)
        XCTAssertEqual(presentation.subtitleKey, "auth.account.subscriptionInactiveHint")
        XCTAssertEqual(presentation.plan, .literal("Team Yearly"))
        XCTAssertEqual(presentation.status, .literal("Requires Action"))
    }
}
