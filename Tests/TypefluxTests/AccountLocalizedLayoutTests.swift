import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The prepaid expiry note and the account surfaces in the CJK languages, whose
/// longer labels used to squeeze the sidebar name and the breakdown titles.
/// With `ACCOUNT_LAYOUT_REVIEW_DIR` set, the renders are written as PNGs.
@MainActor
@Suite("Account localized layout", .serialized, .exclusiveUIState)
struct AccountLocalizedLayoutTests {
    private let rendering = AccountViewRenderingTests()
    private static let languages: [AppLanguage] = [.english, .japanese, .korean, .traditionalChinese,
                                                   .simplifiedChinese]
    private static let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

    static func prepaid(end: String = "2027-02-01T00:00:00Z") -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(
            planCode: "pro", status: "active", currentPeriodStart: AccountViewRenderingTests.start,
            currentPeriodEnd: end, cancelAtPeriodEnd: false, entitled: true, active: true, paid: true,
            periodSource: "aidea", billingEnabled: true, billingMode: "prepaid", autoRenew: false
        )
    }

    // MARK: - Prepaid expiry

    @Test func prepaidMembershipShowsItsExpiryUnderThePlan() throws {
        let status = AccountStatusPresentation.make(subscription: Self.prepaid(), credits: nil,
                                                    usagePeriodStart: nil, usagePeriodEnd: nil)
        let end = try #require(ISO8601DateFormatter.typefluxBillingDate(from: "2027-02-01T00:00:00Z"))
        #expect(status.heroPeriodNote(isPrepaidMembership: true) == .ends(end))
    }

    @Test func cancelledSubscriptionLeavesItsEndDateToTheRestoreOffer() throws {
        let cancelled = AccountViewRenderingTests.snapshot(plan: "pro", status: "active", paid: true, cancel: true)
        let status = AccountStatusPresentation.make(subscription: cancelled, credits: nil,
                                                    usagePeriodStart: nil, usagePeriodEnd: nil)
        #expect(status.periodNote != nil)
        #expect(status.heroPeriodNote(isPrepaidMembership: false) == nil)
        guard case .restore = status.offer else {
            Issue.record("A cancelled subscription offers to restore")
            return
        }
    }

    @Test func otherNotesAreUnchanged() throws {
        let renewing = AccountViewRenderingTests.snapshot(plan: "pro", status: "active", paid: true)
        let status = AccountStatusPresentation.make(subscription: renewing, credits: nil,
                                                    usagePeriodStart: nil, usagePeriodEnd: nil)
        #expect(status.heroPeriodNote(isPrepaidMembership: false) == status.periodNote)
        guard case .renews = status.periodNote else {
            Issue.record("An active subscription renews")
            return
        }
        let free = AccountViewRenderingTests.snapshot(plan: "free", status: "free", paid: false)
        let freeStatus = AccountStatusPresentation.make(subscription: free, credits: nil,
                                                        usagePeriodStart: nil, usagePeriodEnd: AccountViewRenderingTests.end)
        #expect(freeStatus.heroPeriodNote(isPrepaidMembership: false) == freeStatus.periodNote)
    }

    @Test func prepaidExpiryTextIsLocalized() throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let end = try #require(ISO8601DateFormatter.typefluxBillingDate(from: "2027-02-01T00:00:00Z"))
        AppLocalization.shared.setLanguage(.english)
        let english = AccountStatusText.period(.ends(end), locale: AppLocalization.shared.locale)
        for language in Self.languages where language != .english {
            AppLocalization.shared.setLanguage(language)
            let text = AccountStatusText.period(.ends(end), locale: AppLocalization.shared.locale)
            #expect(!text.contains("account.status"), "\(language)")
            #expect(text != english, "\(language)")
        }
    }

    // MARK: - Renders

    @Test func prepaidAccountPageRendersInBothAppearances() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        for language in Self.languages {
            AppLocalization.shared.setLanguage(language)
            let auth = try await makeAuth(Self.prepaid())
            for (name, scheme) in Self.schemes {
                let host = try await host(AccountView(authState: auth) {}.padding(24), width: 900, scheme: scheme)
                #expect(host.bounds.height > 300)
                try save(host, "prepaid/\(language.rawValue)-\(name).png")
            }
        }
    }

    @Test func breakdownTitlesFitInEveryLanguage() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let breakdown = CloudUsageBreakdown(
            periodStart: AccountViewRenderingTests.start, periodEnd: AccountViewRenderingTests.end, timezone: "UTC",
            days: [.init(date: "2026-10-02", voice: 120, rewrite: 30, ask: 12)], voice: 560, rewrite: 106, ask: 52
        )
        for language in Self.languages {
            AppLocalization.shared.setLanguage(language)
            let font = NSFont.systemFont(ofSize: StudioTheme.Typography.bodySmall)
            let widest = [AccountCreditChart.Feature.voice, .rewrite, .ask]
                .map { (AccountCreditBreakdownView.title($0) as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            // The feature box is 270pt wide; the title column must leave room for the bar and percentage.
            #expect(widest < 150, "\(language)")
            for (name, scheme) in Self.schemes {
                let host = try await host(AccountCreditBreakdownView(breakdown: breakdown).padding(16),
                                          width: 700, scheme: scheme)
                try save(host, "breakdown/\(language.rawValue)-\(name).png")
            }
        }
    }

    @Test func sidebarCardKeepsTheNameReadableInEveryLanguage() async throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let cases: [(String, BillingSubscriptionSnapshot, CloudCreditSummary)] = [
            ("free", AccountViewRenderingTests.snapshot(plan: "free", status: "free", paid: false),
             CloudCreditSummary(limit: 600, used: 128, remaining: 472, unlimited: false)),
            ("prepaid", Self.prepaid(), CloudCreditSummary(limit: 2000, used: 84, remaining: 1916, unlimited: false))
        ]
        for language in Self.languages {
            AppLocalization.shared.setLanguage(language)
            for (label, subscription, credits) in cases {
                let presentation = SidebarAccountCardPresentation.make(
                    isLoggedIn: true, subscription: subscription, credits: credits,
                    subscriptionError: nil, usageError: nil, displayName: "Demir Von"
                )
                // This app's sidebar and Classic's narrower 210pt one.
                for width in Set([StudioTheme.sidebarWidth, 210]).sorted() {
                    for (name, scheme) in Self.schemes {
                        let card = StudioSidebarAccountCard(presentation: presentation, action: {}, identityAction: {},
                                                            footer: { EmptyView() })
                            .padding(.horizontal, StudioTheme.Insets.sidebarOuterHorizontal)
                            .padding(.vertical, StudioTheme.Spacing.large)
                            .background(StudioTheme.sidebar)
                        let host = try await host(card, width: width, scheme: scheme)
                        #expect(host.bounds.height > 60)
                        try save(host, "sidebar/\(Int(width))/\(language.rawValue)-\(label)-\(name).png")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeAuth(_ subscription: BillingSubscriptionSnapshot) async throws -> AuthState {
        let fixture = AccountViewRenderingTests.Fixture()
        fixture.subscription = subscription
        fixture.credits = CloudCreditSummary(limit: 2000, used: 83.88, remaining: 1916.12, unlimited: false,
                                             addon: CloudAddonCredits(balance: 190, usedThisPeriod: 0, remaining: 190))
        fixture.breakdown = CloudUsageBreakdown(
            periodStart: AccountViewRenderingTests.start, periodEnd: AccountViewRenderingTests.end, timezone: "UTC",
            days: [.init(date: "2026-10-02", voice: 120, rewrite: 30, ask: 12),
                   .init(date: "2026-10-08", voice: 260, rewrite: 54, ask: 40)],
            voice: 380, rewrite: 84, ask: 52
        )
        let auth = rendering.makeAuth(fixture)
        await auth.refreshSubscription()
        await auth.refreshUsage()
        await auth.refreshUsageBreakdown()
        return auth
    }

    private func host(_ view: some View, width: CGFloat, scheme: ColorScheme) async throws -> NSView {
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, AppLocalization.shared.locale)
        ))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1200)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.frame.size.height = max(hosting.fittingSize.height, 1)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func save(_ view: NSView, _ relativePath: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ACCOUNT_LAYOUT_REVIEW_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
