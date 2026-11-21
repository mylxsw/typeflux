import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite("Prepaid membership rendering", .serialized, .exclusiveUIState)
struct PrepaidMembershipRenderingTests {
    @Test func prepaidAccountCardRendersRenewalAndExpiry() async throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let fixture = AccountViewRenderingTests.Fixture()
        fixture.subscription = BillingSubscriptionSnapshot(
            planCode: "pro", status: "active", currentPeriodStart: "2026-10-18T00:00:00Z",
            currentPeriodEnd: "2099-01-31T00:00:00Z", cancelAtPeriodEnd: false,
            entitled: true, active: true, paid: true, periodSource: "aidea", billingEnabled: true,
            billingMode: "prepaid", autoRenew: false
        )
        fixture.credits = CloudCreditSummary(limit: 400, used: 83.88, remaining: 316.12, unlimited: false,
                                            addon: CloudAddonCredits(balance: 190, usedThisPeriod: 0, remaining: 190))
        let helper = AccountViewRenderingTests()
        let auth = helper.makeAuth(fixture)
        await auth.refreshSubscription()
        await auth.refreshUsage()
        let view = try await helper.host(AccountPlanHeroCard(
            authState: auth, isOpeningBilling: false, errorMessage: nil,
            onOpenBilling: { _ in }, onSync: {}, onRefresh: {}
        ).padding(24).background(Color(nsColor: .windowBackgroundColor)), width: 900)
        #expect(view.fittingSize.height > 100)
        #expect(AccountStatusPresentation.make(subscription: auth.subscription, credits: fixture.credits,
                                              usagePeriodStart: nil, usagePeriodEnd: nil).billingLink == .plans)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PREPAID_REVIEW_DIRECTORY"] {
            view.frame.size.height = view.fittingSize.height
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("prepaid-account.png"))
        }
    }
}
