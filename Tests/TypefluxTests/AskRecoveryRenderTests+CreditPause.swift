import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The credit-pause flow as the user sees it: paused, balance back, continued.
/// `TYPEFLUX_RECOVERY_SCREENSHOTS=<dir>` also writes the PNGs.
extension AskRecoveryRenderTests {
    private func creditAuth(_ credits: CloudCreditSummary?) -> AuthState {
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil },
                             saveStoredToken: { _, _ in }, saveStoredUserProfile: { _ in }, clearStoredSession: {})
        auth.subscription = BillingSubscriptionSnapshot(
            planCode: "pro", status: "active", currentPeriodStart: "2026-10-01T00:00:00Z",
            currentPeriodEnd: "2026-11-01T00:00:00Z", cancelAtPeriodEnd: false, entitled: true, planName: "Pro",
            billingEnabled: true
        )
        auth.usageCredits = credits
        auth.usagePeriodStart = "2026-10-01T00:00:00Z"
        auth.usagePeriodEnd = "2026-11-01T00:00:00Z"
        return auth
    }

    private func pausedConversation(chinese: Bool) -> AskConversation {
        var run = AskRun(id: "credit-run", deviceId: "device", status: "paused_credits", steps: 3, updatedAt: Date(),
                         tools: [], pending: [])
        run.stopReason = "credits_exhausted"
        run.creditsPausedAt = Date()
        return AskConversation(id: "credit-pause", title: chinese ? "整理竞品调研" : "Competitor research",
                               revision: 4, updatedAt: Date(), messages: [
                                   .init(id: "question", role: "user",
                                         text: chinese ? "帮我整理三家竞品的定价和功能差异。"
                                             : "Compare pricing and features of three competitors.",
                                         createdAt: Date(), runId: "credit-run")
                               ], run: run)
    }

    private static let exhausted = CloudCreditSummary(
        limit: 300_000, used: 300_000, remaining: 0, unlimited: false, totalRemaining: 0,
        addon: .init(balance: 0, usedThisPeriod: 0, remaining: 0)
    )
    private static let toppedUp = CloudCreditSummary(
        limit: 300_000, used: 300_000, remaining: 0, unlimited: false, totalRemaining: 220_000,
        addon: .init(balance: 220_000, usedThisPeriod: 0, remaining: 220_000,
                     nextExpiry: .init(credits: 220_000, expiresAt: "2027-10-08T00:00:00Z"))
    )

    private func renderWorkspace(_ model: AskConversationModel, auth: AuthState, name: String, dark: Bool,
                                 language: AppLanguage) async throws -> String {
        let size = NSSize(width: 1100, height: 720)
        func content() -> some View {
            AskConversationView(model: model, auth: auth)
                .environment(\.askGlassMaterialOverride, .opaque)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(AskTheme.surface)
        }
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content())
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(language)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        hosting.rootView = content()
        model.objectWillChange.send()
        return try snapshot(hosting, name: name, language: language)
    }

    @Test func `credit pause flow shows the balance, the purchase entry and continue`() async throws {
        for (language, chinese) in [(AppLanguage.english, false), (.simplifiedChinese, true)] {
            for dark in [false, true] {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                let value = pausedConversation(chinese: chinese)
                await fixture.api.seed(value)
                await fixture.model.refreshHistory()
                await fixture.model.select(value.id)
                let suffix = (chinese ? "zh" : "en") + (dark ? "-dark" : "")

                // 1. Paused: both balances at zero, buy and upgrade offered, no "unknown result".
                let auth = creditAuth(Self.exhausted)
                let paused = try await renderWorkspace(fixture.model, auth: auth, name: "credit-1-paused-" + suffix,
                                                       dark: dark, language: language)
                #expect(readable(paused).contains(readable(localized("ask.credits.exhausted.title", language: language))))
                #expect(readable(paused).contains(readable(localized("ask.credits.buy", language: language))))
                #expect(readable(paused).contains(readable(localized("ask.credits.upgrade", language: language))))
                #expect(!readable(paused).contains(readable(localized("ask.recovery.unknown", language: language))))

                // 2. Back from the billing page: the refreshed balance turns the card into Continue.
                auth.usageCredits = Self.toppedUp
                let available = try await renderWorkspace(fixture.model, auth: auth,
                                                          name: "credit-2-available-" + suffix,
                                                          dark: dark, language: language)
                #expect(readable(available).contains(readable(localized("ask.credits.continue", language: language))))
                #expect(readable(available).contains("220,000") || readable(available).contains("220000"))

                // 3. Continue resumes the pinned run, which finishes its answer.
                fixture.model.resumeCreditPause()
                try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
                let resumed = try await renderWorkspace(fixture.model, auth: auth, name: "credit-3-resumed-" + suffix,
                                                        dark: dark, language: language)
                #expect(resumed.contains("Resumed answer"))
                #expect(!readable(resumed).contains(readable(localized("ask.credits.exhausted.title", language: language))))
                #expect(await fixture.api.resumes == ["credit-run"])
            }
        }
    }

    @Test func `account card lists add-on credits and their next expiry`() throws {
        for dark in [false, true] {
            for language in [AppLanguage.english, .simplifiedChinese] {
                let credits = CloudCreditSummary(
                    limit: 300_000, used: 120_000, remaining: 180_000, unlimited: false, totalRemaining: 400_000,
                    addon: .init(balance: 220_000, usedThisPeriod: 0, remaining: 220_000,
                                 nextExpiry: .init(credits: 100_000,
                                                   expiresAt: ISO8601DateFormatter().string(
                                                       from: Date().addingTimeInterval(12 * 86400))))
                )
                let auth = creditAuth(credits)
                let text = try render(
                    AskAccountCard(auth: auth, onOpenAccount: {}, onDismiss: {}).padding(20),
                    name: "credit-account-card-\(language == .english ? "en" : "zh")\(dark ? "-dark" : "")",
                    dark: dark, language: language, size: .init(width: 360, height: 420)
                )
                // Vision misreads the small CJK label; the English pass checks the title.
                if language == .english {
                    #expect(readable(text).contains(readable(localized("account.addon.title", language: language))))
                }
                #expect(readable(text).contains("220,000") || readable(text).contains("220000"))
            }
        }
    }
}
