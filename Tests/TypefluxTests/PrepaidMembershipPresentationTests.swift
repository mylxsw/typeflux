@testable import Typeflux
import XCTest

final class PrepaidMembershipPresentationTests: XCTestCase {
    private func snapshot(cancelAtPeriodEnd: Bool = false) -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: "pro", status: "active", currentPeriodStart: "2026-10-18T00:00:00Z",
            currentPeriodEnd: "2099-01-31T00:00:00Z", cancelAtPeriodEnd: cancelAtPeriodEnd,
            entitled: true, active: true, paid: true, periodSource: "aidea", billingEnabled: true,
            billingMode: "prepaid", autoRenew: false
        )
    }

    func testPrepaidSnapshotDecodesServerContractAndPreservesPurchaseMode() throws {
        let data = Data("""
        {"billing_enabled":true,"plan_code":"pro","status":"active","active":true,"paid":true,
         "current_period_end":"2099-01-31T00:00:00Z","period_source":"aidea",
         "billing_mode":"prepaid","auto_renew":false,"cancel_at_period_end":false}
        """.utf8)
        let value = try JSONDecoder().decode(BillingSubscriptionSnapshot.self, from: data)
        XCTAssertTrue(value.isPrepaidMembership)
        XCTAssertFalse(value.renewsAutomatically)
        XCTAssertTrue(value.hasPaidSubscription)
        let hidden = value.disablingBilling()
        XCTAssertFalse(hidden.billingEnabled)
        XCTAssertTrue(hidden.isPrepaidMembership)
        XCTAssertFalse(hidden.renewsAutomatically)
    }

    func testLegacyStripeSnapshotsKeepAutomaticRenewalBehavior() throws {
        let data = Data("""
        {"billing_enabled":true,"plan_code":"pro","status":"active","active":true,"paid":true,
         "current_period_end":"2099-01-31T00:00:00Z","cancel_at_period_end":false}
        """.utf8)
        let value = try JSONDecoder().decode(BillingSubscriptionSnapshot.self, from: data)
        XCTAssertFalse(value.isPrepaidMembership)
        XCTAssertTrue(value.renewsAutomatically)
        XCTAssertNil(value.billingMode)
    }

    func testPrepaidPresentationEndsWithoutAnAutomaticRenewalOrRestoreOffer() throws {
        let value = snapshot(cancelAtPeriodEnd: true)
        let presentation = AccountSubscriptionPresentation.make(from: value)
        XCTAssertEqual(presentation.subtitleKey, "auth.account.subscriptionPrepaidHint")
        XCTAssertEqual(presentation.billingAction, .subscribe)
        XCTAssertEqual(presentation.period, .endsOn("2099-01-31T00:00:00Z"))
        let status = AccountStatusPresentation.make(
            subscription: value, credits: nil, usagePeriodStart: nil, usagePeriodEnd: nil
        )
        XCTAssertEqual(status.billingLink, .plans)
        XCTAssertNil(status.offer)
        let end = try XCTUnwrap(ISO8601DateFormatter.typefluxBillingDate(from: "2099-01-31T00:00:00Z"))
        XCTAssertEqual(status.periodNote, .ends(end))
    }

    func testPrepaidRenewalOpensPlansWithoutCreatingStripePortal() async throws {
        var plans = 0
        var portals = 0
        let destination = try await AccountBillingFlow.destination(
            for: AccountSubscriptionPresentation.make(from: snapshot()).billingAction,
            requestBillingPageToken: { plans += 1; return URL(string: "https://typeflux.app/billing/plans#t=synthetic")! },
            createPortalSession: { portals += 1; return URL(string: "https://billing.stripe.com/portal")! }
        )
        XCTAssertEqual(destination.host, "typeflux.app")
        XCTAssertEqual(plans, 1)
        XCTAssertEqual(portals, 0)
    }
}
