import Foundation
@testable import Typeflux
import XCTest

final class AddonCreditsTests: XCTestCase {
    // MARK: Credit summary

    func testSummaryDecodesCombinedBalanceAndAddonPool() throws {
        let json = """
        {"limit":300000,"used":300000,"remaining":0,"unlimited":false,"total_remaining":128400,
         "addon":{"balance":220000,"used_this_period":91600,"remaining":128400,
                  "next_expiry":{"credits":100000,"expires_at":"2027-03-01T00:00:00Z"}}}
        """
        let credits = try JSONDecoder().decode(CloudCreditSummary.self, from: Data(json.utf8))
        XCTAssertEqual(credits.remaining, 0)
        XCTAssertEqual(credits.totalRemaining, 128_400)
        XCTAssertEqual(credits.addon?.balance, 220_000)
        XCTAssertEqual(credits.addon?.usedThisPeriod, 91600)
        XCTAssertEqual(credits.addon?.nextExpiry?.credits, 100_000)
        XCTAssertNotNil(credits.addon?.nextExpiry?.date)
        XCTAssertEqual(credits.spendableRemaining, 128_400)
        XCTAssertTrue(credits.canSpend)
    }

    func testOlderServersAndMalformedAddonsKeepTheMonthlyBalance() throws {
        let legacy = try JSONDecoder().decode(
            CloudCreditSummary.self,
            from: Data(#"{"limit":100,"used":40,"remaining":60,"unlimited":false}"#.utf8)
        )
        XCTAssertEqual(legacy, CloudCreditSummary(limit: 100, used: 40, remaining: 60, unlimited: false))
        XCTAssertEqual(legacy.spendableRemaining, 60)

        let malformed = try JSONDecoder().decode(
            CloudCreditSummary.self,
            from: Data(#"{"limit":100,"used":100,"remaining":0,"unlimited":false,"addon":"oops"}"#.utf8)
        )
        XCTAssertNil(malformed.addon)
        XCTAssertFalse(malformed.canSpend)

        let partial = try JSONDecoder().decode(
            CloudAddonCredits.self,
            from: Data(#"{"remaining":5,"next_expiry":{"credits":"bad"}}"#.utf8)
        )
        XCTAssertEqual(partial, CloudAddonCredits(balance: 0, usedThisPeriod: 0, remaining: 5))
    }

    func testSpendableBalanceWithoutTotalAddsMonthAndAddon() {
        let credits = CloudCreditSummary(limit: 100, used: 120, remaining: -20, unlimited: false,
                                         addon: .init(balance: 50, usedThisPeriod: 20, remaining: 30))
        XCTAssertEqual(credits.monthlyRemaining, 0)
        XCTAssertEqual(credits.addonRemaining, 30)
        XCTAssertEqual(credits.spendableRemaining, 30)
        let unlimited = CloudCreditSummary(limit: -1, used: 10, remaining: -1, unlimited: true, totalRemaining: 0)
        XCTAssertTrue(unlimited.canSpend)
    }

    // MARK: 402 details

    func testExhaustedEnvelopeKeepsItsDetails() throws {
        let body = """
        {"code":"CREDITS_EXHAUSTED","message":"credits exhausted",
         "details":{"monthly_remaining":0,"addon_remaining":0,"period_end":"2026-11-01T00:00:00Z","purchasable":true}}
        """
        let error = try XCTUnwrap(CloudCreditsExhaustedError.parse(data: Data(body.utf8)))
        XCTAssertEqual(error.details, CloudCreditsExhaustedDetails(monthlyRemaining: 0, addonRemaining: 0,
                                                                    periodEnd: "2026-11-01T00:00:00Z",
                                                                    purchasable: true))
        XCTAssertEqual(error.errorDescription, L("cloud.error.creditsExhausted"))
        XCTAssertNotEqual(error.errorDescription, "credits exhausted")
    }

    func testExhaustedEnvelopeToleratesMissingOrOddDetails() throws {
        let bare = try XCTUnwrap(CloudCreditsExhaustedError.parse(data: Data(#"{"code":"credits_exhausted"}"#.utf8)))
        XCTAssertNil(bare.details)
        let odd = try XCTUnwrap(CloudCreditsExhaustedError.parse(
            data: Data(#"{"code":"CREDITS_EXHAUSTED","details":[1,2]}"#.utf8)
        ))
        XCTAssertNil(odd.details)
        let nullEnd = try XCTUnwrap(CloudCreditsExhaustedError.parse(
            data: Data(#"{"code":"CREDITS_EXHAUSTED","details":{"period_end":null}}"#.utf8)
        ))
        XCTAssertEqual(nullEnd.details, CloudCreditsExhaustedDetails())
    }

    func testOtherBodiesAreNotCreditExhaustion() {
        XCTAssertNil(CloudCreditsExhaustedError.parse(data: Data(#"{"code":"QUOTA_EXCEEDED"}"#.utf8)))
        XCTAssertNil(CloudCreditsExhaustedError.parse(data: Data("not json".utf8)))
        XCTAssertNil(CloudCreditsExhaustedError.parse(data: Data()))
    }

    func testServerCodeIsLocalizedInsteadOfShowingTheEnglishMessage() {
        XCTAssertEqual(TypefluxCloudServerErrorMessage.localizationKey(for: "CREDITS_EXHAUSTED"),
                       "cloud.error.creditsExhausted")
        XCTAssertEqual(
            AuthError.serverError(code: "CREDITS_EXHAUSTED", message: "monthly credits exhausted").errorDescription,
            L("cloud.error.creditsExhausted")
        )
        XCTAssertEqual(TypefluxCloudBillingError.fromError(CloudCreditsExhaustedError(details: nil))?.reason,
                       .quotaExceeded)
    }

    // MARK: Links

    func testCreditsTabKeepsThePageTokenFragment() throws {
        let plans = try XCTUnwrap(URL(string: "https://typeflux.ai/billing/plans?lang=zh-CN#t=secret"))
        let url = BillingPlansLink.url(plans, tab: BillingPlansLink.creditsTab)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.fragment, "t=secret")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "lang", value: "zh-CN"),
                                               URLQueryItem(name: "tab", value: "credits")])
        XCTAssertEqual(BillingPlansLink.url(plans, tab: nil), plans)

        let replaced = BillingPlansLink.url(try XCTUnwrap(URL(string: "https://a.test/p?tab=plans#t=x")), tab: "credits")
        XCTAssertEqual(replaced.absoluteString, "https://a.test/p?tab=credits#t=x")
    }

    func testBillingReturnLinkMatchesOnlyItsOwnPath() throws {
        XCTAssertTrue(BillingReturnLink.matches(try XCTUnwrap(URL(string: "typeflux://billing/return"))))
        XCTAssertTrue(BillingReturnLink.matches(try XCTUnwrap(URL(string: "TYPEFLUX://Billing/return/?session_id=cs_1"))))
        XCTAssertFalse(BillingReturnLink.matches(try XCTUnwrap(URL(string: "typeflux://billing/cancel"))))
        XCTAssertFalse(BillingReturnLink.matches(try XCTUnwrap(URL(string: "ai.gulu.app.typeflux://oauth/github"))))
        XCTAssertFalse(BillingReturnLink.matches(try XCTUnwrap(URL(string: "https://billing/return"))))
    }

    @MainActor
    func testBillingReturnRefreshesTheAccountSummary() async {
        var usageFetches = 0
        let auth = AuthState(
            loadStoredToken: { ("token", Int(Date().addingTimeInterval(3600 * 24 * 30).timeIntervalSince1970)) },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in
                UserProfile(id: "user", email: "addon@test.com", name: "Test", status: 1, provider: "password",
                            createdAt: "2024-04-09T12:00:00Z", updatedAt: "2024-04-09T12:00:00Z")
            },
            refreshAccessToken: { _ in throw AuthError.unauthorized },
            fetchSubscription: { _ in .none },
            fetchCurrentPeriodUsageStats: { _ in
                usageFetches += 1
                return CloudUsageCurrentPeriodStats(
                    periodStart: "2026-10-01T00:00:00Z", periodEnd: "2026-11-01T00:00:00Z", stats: .empty,
                    credits: .init(limit: 100, used: 100, remaining: 0, unlimited: false, totalRemaining: 500,
                                   addon: .init(balance: 500, usedThisPeriod: 0, remaining: 500))
                )
            }
        )
        auth.isLoggedIn = true
        await auth.refreshAccountSummary()
        await BillingReturnLink.handle(auth: auth)
        XCTAssertEqual(usageFetches, 2)
        XCTAssertEqual(auth.usageCredits?.spendableRemaining, 500)
    }

    // MARK: Account presentation

    func testAddonRowShowsBalanceAndNextExpiry() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter.typefluxBillingDate(from: "2026-10-08T00:00:00Z"))
        let credits = CloudCreditSummary(
            limit: 100, used: 100, remaining: 0, unlimited: false, totalRemaining: 300,
            addon: .init(balance: 300, usedThisPeriod: 0, remaining: 300,
                         nextExpiry: .init(credits: 200, expiresAt: "2027-03-01T00:00:00Z"))
        )
        let presentation = AccountUsageCreditPresentation(credits: credits)
        let addon = try XCTUnwrap(presentation.addon(now: now))
        XCTAssertEqual(addon.remaining, 300)
        XCTAssertEqual(addon.expiringCredits, 200)
        XCTAssertFalse(addon.expiresSoon)
        XCTAssertFalse(presentation.isExhausted)
        let text = try XCTUnwrap(AccountStatusText.addonExpiry(addon, locale: Locale(identifier: "en_US"),
                                                              timeZone: TimeZone(identifier: "UTC")!, now: now))
        XCTAssertTrue(text.contains("200"), text)
    }

    func testAddonExpiringWithinThirtyDaysWarns() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter.typefluxBillingDate(from: "2026-10-08T00:00:00Z"))
        func addon(_ expiresAt: String, remaining: Int = 50) -> AccountUsageCreditPresentation.Addon? {
            AccountUsageCreditPresentation(credits: .init(
                limit: 100, used: 0, remaining: 100, unlimited: false,
                addon: .init(balance: remaining, usedThisPeriod: 0, remaining: remaining,
                             nextExpiry: .init(credits: 50, expiresAt: expiresAt))
            )).addon(now: now)
        }
        XCTAssertEqual(addon("2026-11-01T00:00:00Z")?.expiresSoon, true)
        XCTAssertEqual(addon("2026-11-07T00:00:00Z")?.expiresSoon, true)
        XCTAssertEqual(addon("2026-11-08T00:00:01Z")?.expiresSoon, false)
        XCTAssertEqual(addon("2026-10-07T00:00:00Z")?.expiresSoon, false)
        // Nothing left to lose: no warning, the expiry is still listed.
        XCTAssertEqual(addon("2026-10-20T00:00:00Z", remaining: 0)?.expiresSoon, false)
        let warning = try XCTUnwrap(addon("2026-10-20T00:00:00Z"))
        XCTAssertEqual(AccountStatusText.addonExpiry(warning, locale: Locale(identifier: "en_US")),
                       L("account.addon.expiringSoon", "50",
                         AccountStatusText.shortDate(try XCTUnwrap(warning.expiresAt), locale: Locale(identifier: "en_US"))))
    }

    func testNoAddonRowWithoutPurchases() {
        XCTAssertNil(AccountUsageCreditPresentation(credits: nil).addon())
        XCTAssertNil(AccountUsageCreditPresentation(credits: .init(limit: 100, used: 0, remaining: 100,
                                                                   unlimited: false)).addon())
        XCTAssertNil(AccountUsageCreditPresentation(credits: .init(
            limit: 100, used: 0, remaining: 100, unlimited: false,
            addon: .init(balance: 0, usedThisPeriod: 0, remaining: 0)
        )).addon())
        let noExpiry = AccountUsageCreditPresentation(credits: .init(
            limit: 100, used: 0, remaining: 100, unlimited: false,
            addon: .init(balance: 10, usedThisPeriod: 0, remaining: 10)
        )).addon()
        XCTAssertEqual(noExpiry?.remaining, 10)
        XCTAssertNil(AccountStatusText.addonExpiry(noExpiry!, locale: Locale(identifier: "en_US")))
    }

    func testAddonCreditsKeepTheAccountOutOfExhaustedAndLowStates() {
        let pro = BillingSubscriptionSnapshot(planCode: "pro", status: "active", currentPeriodStart: nil,
                                              currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true,
                                              billingEnabled: true)
        let monthGone = CloudCreditSummary(limit: 100, used: 100, remaining: 0, unlimited: false, totalRemaining: 40,
                                           addon: .init(balance: 40, usedThisPeriod: 0, remaining: 40))
        XCTAssertFalse(AccountUsageCreditPresentation(credits: monthGone).isExhausted)
        XCTAssertNotEqual(AccountStatusPresentation.make(subscription: pro, credits: monthGone, usagePeriodStart: nil,
                                                         usagePeriodEnd: nil).level, .exhausted)
        let low = CloudCreditSummary(limit: 100, used: 95, remaining: 5, unlimited: false, totalRemaining: 45,
                                     addon: .init(balance: 40, usedThisPeriod: 0, remaining: 40))
        XCTAssertEqual(AccountStatusPresentation.make(subscription: pro, credits: low, usagePeriodStart: nil,
                                                      usagePeriodEnd: nil).level, .normal)
        let allGone = CloudCreditSummary(limit: 100, used: 100, remaining: 0, unlimited: false, totalRemaining: 0,
                                         addon: .init(balance: 0, usedThisPeriod: 0, remaining: 0))
        XCTAssertEqual(AccountStatusPresentation.make(subscription: pro, credits: allGone, usagePeriodStart: nil,
                                                      usagePeriodEnd: nil).level, .exhausted)
    }
}
