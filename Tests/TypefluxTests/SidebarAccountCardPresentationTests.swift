@testable import Typeflux
import XCTest

final class SidebarAccountCardPresentationTests: XCTestCase {
    func testSignedOutStateInvitesSignIn() {
        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: false,
            subscription: .none,
            credits: nil,
            subscriptionError: nil,
            usageError: nil
        )

        XCTAssertEqual(presentation.state, .signedOut)
        XCTAssertEqual(presentation.action, .signIn)
        XCTAssertNil(presentation.progress)
        XCTAssertFalse(presentation.usesFilledIdentityIcon)
    }

    func testUnresolvedSignedInStateLoadsWithoutPretendingUserIsFree() {
        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: true,
            subscription: .none,
            credits: nil,
            subscriptionError: nil,
            usageError: nil
        )

        XCTAssertEqual(presentation.state, .loading)
        XCTAssertEqual(presentation.action, .viewDetails)
        XCTAssertNil(presentation.planName)
        XCTAssertTrue(presentation.usesFilledIdentityIcon)
    }

    func testFailedSignedInStateIsUnavailable() {
        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: true,
            subscription: .none,
            credits: nil,
            subscriptionError: "offline",
            usageError: nil
        )

        XCTAssertEqual(presentation.state, .unavailable)
    }

    func testFreePlanShowsUpgradeAndRemainingCreditProgress() {
        let subscription = BillingSubscriptionSnapshot(
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
        let credits = CloudCreditSummary(limit: 4_500, used: 1_280, remaining: 3_220, unlimited: false)

        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: true,
            subscription: subscription,
            credits: credits,
            subscriptionError: nil,
            usageError: nil,
            displayName: "  Alex  "
        )

        XCTAssertEqual(presentation.state, .account)
        XCTAssertEqual(presentation.action, .upgrade)
        XCTAssertEqual(presentation.displayName, "Alex")
        XCTAssertEqual(presentation.planName, "Free")
        XCTAssertEqual(presentation.progress ?? 0, 3_220.0 / 4_500.0, accuracy: 0.0001)
    }

    func testSidebarAndAccountCenterShareRemainingCreditSemantics() {
        let summaries: [CloudCreditSummary?] = [
            nil,
            .init(limit: 100, used: 30, remaining: 55, unlimited: false),
            .init(limit: 100, used: 0, remaining: 100, unlimited: false),
            .init(limit: 100, used: 125, remaining: 0, unlimited: false),
            .init(limit: -1, used: 100, remaining: -1, unlimited: true),
            .init(limit: 0, used: 0, remaining: 0, unlimited: false),
            .init(limit: -1, used: 0, remaining: 0, unlimited: false)
        ]
        for credits in summaries {
            let sidebar = SidebarAccountCardPresentation.make(
                isLoggedIn: true, subscription: .none, credits: credits,
                subscriptionError: nil, usageError: nil
            )
            let account = AccountUsageCreditPresentation(credits: credits)
            XCTAssertEqual(sidebar.creditPresentation.balance, account.balance)
            XCTAssertEqual(sidebar.progress, account.progress)
        }
    }

    func testPaidPlanShowsBillingManagement() {
        let subscription = BillingSubscriptionSnapshot(
            planCode: "premium",
            status: "active",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: true,
            planName: "Premium",
            active: true,
            paid: true,
            billingEnabled: true
        )

        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: true,
            subscription: subscription,
            credits: nil,
            subscriptionError: nil,
            usageError: nil
        )

        XCTAssertEqual(presentation.action, .manageBilling)
        XCTAssertEqual(presentation.planName, "Premium")
        XCTAssertFalse(presentation.needsAttention)
    }

    func testInactivePaidPlanCallsAttentionToBilling() {
        let subscription = BillingSubscriptionSnapshot(
            planCode: "pro",
            status: "past_due",
            currentPeriodStart: nil,
            currentPeriodEnd: nil,
            cancelAtPeriodEnd: false,
            entitled: false,
            active: false,
            paid: true,
            billingEnabled: true
        )

        let presentation = SidebarAccountCardPresentation.make(
            isLoggedIn: true,
            subscription: subscription,
            credits: nil,
            subscriptionError: nil,
            usageError: nil
        )

        XCTAssertEqual(presentation.action, .resolveBilling)
        XCTAssertTrue(presentation.needsAttention)
    }
}
