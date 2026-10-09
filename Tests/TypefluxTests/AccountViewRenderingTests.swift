import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Hosts the account page, the Ask account card and the footer in every
/// subscription state so each branch lays out without trapping, and checks the
/// page asks for the breakdown when it appears.
@MainActor
@Suite("Account view rendering", .serialized, .exclusiveUIState)
struct AccountViewRenderingTests {
    final class Fixture {
        var subscription = BillingSubscriptionSnapshot.none
        var credits: CloudCreditSummary?
        var breakdown: CloudUsageBreakdown?
        var breakdownRequests = 0
    }

    static let start = "2026-10-01T00:00:00Z"
    static let end = "2026-11-01T00:00:00Z"

    static func snapshot(plan: String, status: String, paid: Bool, cancel: Bool = false,
                         billing: Bool = true) -> BillingSubscriptionSnapshot {
        BillingSubscriptionSnapshot(planCode: plan, status: status, currentPeriodStart: start, currentPeriodEnd: end,
                                    cancelAtPeriodEnd: cancel, entitled: status == "active" || status == "free",
                                    paid: paid, billingEnabled: billing)
    }

    static func credits(_ used: Int, _ limit: Int = 60000, unlimited: Bool = false) -> CloudCreditSummary {
        CloudCreditSummary(limit: limit, used: used, remaining: limit - used, unlimited: unlimited)
    }

    // swiftlint:disable:next large_tuple
    static let states: [(String, BillingSubscriptionSnapshot, CloudCreditSummary?)] = [
        ("free", snapshot(plan: "free", status: "free", paid: false), credits(1500)),
        ("low", snapshot(plan: "free", status: "free", paid: false), credits(51000)),
        ("exhausted", snapshot(plan: "free", status: "free", paid: false), credits(60000)),
        ("pro", snapshot(plan: "pro", status: "active", paid: true), credits(500_000, 2_000_000)),
        ("cancel", snapshot(plan: "pro", status: "active", paid: true, cancel: true), credits(10, 2_000_000)),
        ("pastDue", snapshot(plan: "pro", status: "past_due", paid: true), credits(10, 2_000_000)),
        ("unlimited", snapshot(plan: "pro", status: "active", paid: true), credits(10, 0, unlimited: true)),
        ("noBilling", snapshot(plan: "free", status: "free", paid: false, billing: false), credits(100)),
        ("unavailable", snapshot(plan: "free", status: "free", paid: false), nil)
    ]

    /// `signedIn: false` builds a session-less state rather than calling
    /// `logout()`, whose app-wide notification would reset the Ask models of
    /// suites running in parallel.
    func makeAuth(_ fixture: Fixture, signedIn: Bool = true) -> AuthState {
        AuthState(
            loadStoredToken: { signedIn ? ("valid-token", Int(Date().timeIntervalSince1970) + 3600) : nil },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: {
                signedIn ? UserProfile(id: "u", email: "demir@example.com", name: "Demir Von", status: 1,
                                       provider: "password", createdAt: "2026-03-01T00:00:00Z",
                                       updatedAt: "2026-03-01T00:00:00Z") : nil
            },
            saveStoredToken: { _, _ in }, saveStoredUserProfile: { _ in }, clearStoredSession: {},
            fetchProfile: { _ in throw AuthError.invalidResponse },
            fetchSubscription: { _ in fixture.subscription },
            fetchCurrentPeriodUsageStats: { _ in
                CloudUsageCurrentPeriodStats(periodStart: Self.start, periodEnd: Self.end, stats: CloudUsageStats(
                    asrCount: 12, asrAudioDurationMs: 90000, asrOutputChars: 800, chatCount: 3, chatOutputChars: 200,
                    chatInputTokens: 100, chatOutputTokens: 50, chatTotalTokens: 150
                ), credits: fixture.credits)
            },
            fetchCurrentPeriodUsageBreakdown: { _, _ in
                fixture.breakdownRequests += 1
                guard let value = fixture.breakdown else { throw AuthError.invalidResponse }
                return value
            }
        )
    }

    func host(_ view: some View, width: CGFloat) async throws -> NSView {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1200)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func poll(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func everyStateLaysOutOnThePageTheCardAndTheFooter() async throws {
        for (name, subscription, credits) in Self.states {
            let fixture = Fixture()
            fixture.subscription = subscription
            fixture.credits = credits
            fixture.breakdown = name == "unavailable" ? nil : CloudUsageBreakdown(
                periodStart: Self.start, periodEnd: Self.end, timezone: "UTC",
                days: name == "free" ? [] : [.init(date: "2026-10-01", voice: 30, rewrite: 10, ask: 5)],
                voice: name == "free" ? 0 : 30, rewrite: name == "free" ? 0 : 10, ask: name == "free" ? 0 : 5
            )
            let auth = makeAuth(fixture)
            await auth.refreshSubscription()
            await auth.refreshUsage()
            await auth.refreshUsageBreakdown()

            let page = try await host(AccountView(authState: auth) {}, width: 860)
            #expect(page.fittingSize.height > 300, "page \(name)")
            // The page asks for the breakdown again when it appears.
            try await poll { fixture.breakdownRequests >= 2 }
            #expect(fixture.breakdownRequests >= 2, "page \(name)")

            let card = try await host(AskAccountCard(auth: auth, onOpenAccount: {}, onDismiss: {}),
                                      width: AskAccountCard.width)
            #expect(card.fittingSize.height > 150, "card \(name)")

            let footer = try await host(AskAccountFooterIdentity(auth: auth, name: "Demir Von") {}, width: 230)
            #expect(footer.fittingSize.height > 0)
        }
    }

    @Test func narrowPagesAndSignedOutStatesLayOut() async throws {
        let fixture = Fixture()
        fixture.subscription = Self.snapshot(plan: "pro", status: "active", paid: true)
        fixture.credits = Self.credits(100, 2_000_000)
        let auth = makeAuth(fixture)
        await auth.refreshSubscription()
        await auth.refreshUsage()
        _ = try await host(AccountView(authState: auth) {}, width: 560)
        let signedOut = makeAuth(Fixture(), signedIn: false)
        #expect(!signedOut.isLoggedIn)
        let page = try await host(AccountView(authState: signedOut) {}, width: 560)
        #expect(page.fittingSize.height > 100)
        let footer = try await host(AskAccountFooterIdentity(auth: signedOut, name: "Typeflux") {}, width: 230)
        #expect(footer.fittingSize.height > 0)
    }

    @Test func helpSectionLinksAreWellFormed() {
        let contact = AccountHelpSection.contactURL
        #expect(contact?.scheme == "mailto")
        #expect(contact?.absoluteString.contains(AccountHelpSection.contactAddress) == true)
        #expect(AccountHelpSection.privacyURL.host == "typeflux.app")
        #expect(AccountCreditBreakdownView.title(.voice) != AccountCreditBreakdownView.title(.ask))
        #expect(AccountCreditBreakdownView.title(.rewrite) != AccountCreditBreakdownView.title(.ask))
    }
}
