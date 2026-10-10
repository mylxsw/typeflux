import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite("Billing consumer operations", .serialized, .exclusiveUIState)
struct BillingOperationBehaviorTests {
    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func currentSuccessOpensTheRequestedDestinationOnce(_ entry: BillingOperationFixture.Entry) async throws {
        try await withEntry(entry) { fixture, host in
            let button = try fixture.button(in: host)
            try button.press()
            if entry.isCard { try button.press() }
            let task = try await fixture.started()
            #expect(fixture.lifetime.isBusy)
            fixture.lifetime.start { Issue.record("A busy request must retain its ownership") }
            #expect(fixture.calls == ["a1"])
            fixture.auth.lastAccountSummaryRefresh = Date()
            fixture.succeed("current")
            await task.value
            #expect(fixture.links == [fixture.expectedURL("current")])
            #expect(fixture.dismissals == (entry.isCard ? 1 : 0))
            #expect(fixture.auth.lastAccountSummaryRefresh == nil)
            #expect(!fixture.lifetime.isBusy)
            #expect(fixture.auth.checkoutPollingTask == nil)
            #expect(!fixture.auth.pendingCheckoutSubscriptionEntitlement)
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func currentFailureIsVisibleAndRetryClearsIt(_ entry: BillingOperationFixture.Entry) async throws {
        try await withEntry(entry) { fixture, host in
            try fixture.button(in: host).press()
            let task = try await fixture.started()
            fixture.fail()
            await task.value
            try await SettingsBehaviorTestSupport.wait {
                SettingsBehaviorTestSupport.contains(BillingOperationFixture.failure.localizedDescription, in: host)
            }
            #expect(fixture.links.isEmpty)
            #expect(fixture.dismissals == 0)
            try fixture.button(in: host).press()
            let retry = try await fixture.started(count: 2)
            #expect(!SettingsBehaviorTestSupport.contains(
                BillingOperationFixture.failure.localizedDescription, in: host
            ))
            fixture.succeed("retry")
            await retry.value
            #expect(fixture.links == [fixture.expectedURL("retry")])
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func replacedSessionSuppressesSuccessAndPrivateFailure(_ entry: BillingOperationFixture.Entry) async throws {
        for replacement in SessionReplacement.allCases {
            for succeeds in [true, false] {
                try await withEntry(entry) { fixture, host in
                    try fixture.button(in: host).press()
                    let task = try await fixture.started()
                    if replacement == .logout {
                        fixture.auth.logout(clearRecentInputMemory: false)
                    } else {
                        await fixture.auth.handleLoginSuccess(token: "b1", expiresAt: fixture.expiry)
                    }
                    let freshSummary = Date()
                    fixture.auth.lastAccountSummaryRefresh = freshSummary
                    if succeeds { fixture.succeed("old-account") } else { fixture.fail() }
                    await task.value
                    #expect(fixture.links.isEmpty)
                    #expect(fixture.dismissals == 0)
                    #expect(fixture.auth.lastAccountSummaryRefresh == freshSummary)
                    #expect(!SettingsBehaviorTestSupport.contains(BillingOperationFixture.failure.localizedDescription,
                                                                  in: host))
                    #expect(fixture.auth.checkoutPollingTask == nil)
                    #expect(!fixture.auth.pendingCheckoutSubscriptionEntitlement)
                }
            }
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func tokenRotationKeepsTheCurrentSessionOutcome(_ entry: BillingOperationFixture.Entry) async throws {
        for succeeds in [true, false] {
            try await withEntry(entry) { fixture, host in
                fixture.auth.cachedRefreshToken = "refresh-a"
                try fixture.button(in: host).press()
                let task = try await fixture.started()
                let generation = fixture.auth.sessionGeneration
                #expect(await fixture.auth.refreshStoredAccessToken(force: true) == .refreshed)
                #expect(fixture.auth.sessionGeneration == generation)
                #expect(fixture.auth.accessToken == "a2")
                if succeeds { fixture.succeed("rotated") } else { fixture.fail() }
                await task.value
                if succeeds {
                    #expect(fixture.links == [fixture.expectedURL("rotated")])
                } else {
                    try await SettingsBehaviorTestSupport.wait {
                        SettingsBehaviorTestSupport.contains(BillingOperationFixture.failure.localizedDescription,
                                                              in: host)
                    }
                    #expect(fixture.links.isEmpty)
                }
                // Do not let fixture logout submit a refresh token to the real service.
                fixture.auth.cachedRefreshToken = nil
            }
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func callerCancellationCannotOpenAnOldURLOrReleaseANewerRequest(_ entry: BillingOperationFixture.Entry) async throws {
        try await withEntry(entry) { fixture, host in
            try fixture.button(in: host).press()
            let old = try await fixture.started()
            fixture.lifetime.cancel()
            #expect(old.isCancelled)
            try await SettingsBehaviorTestSupport.wait { fixture.hasButton(in: host) }
            try fixture.button(in: host).press()
            let current = try await fixture.started(count: 2)
            fixture.succeed("cancelled")
            await old.value
            #expect(fixture.lifetime.isBusy)
            #expect(fixture.lifetime.task != nil)
            #expect(fixture.links.isEmpty)
            #expect(fixture.dismissals == 0)
            fixture.succeed("new")
            await current.value
            #expect(fixture.links == [fixture.expectedURL("new")])
            #expect(!fixture.lifetime.isBusy)
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func newSessionCanStartAnActionBeforeTheOldResponseArrives(_ entry: BillingOperationFixture.Entry) async throws {
        try await withEntry(entry) { fixture, host in
            try fixture.button(in: host).press()
            let old = try await fixture.started()
            await fixture.auth.handleLoginSuccess(token: "b1", expiresAt: fixture.expiry)
            await fixture.auth.refreshSubscription()
            fixture.conversation.sessionState.owner = "b1"
            await fixture.seedConversation()
            try await SettingsBehaviorTestSupport.wait { old.isCancelled && fixture.hasButton(in: host) }
            try fixture.button(in: host).press()
            let current = try await fixture.started(count: 2)
            #expect(fixture.calls == ["a1", "b1"])
            fixture.succeed("old-session")
            await old.value
            #expect(fixture.lifetime.isBusy)
            #expect(fixture.links.isEmpty)
            fixture.succeed("new-session")
            await current.value
            #expect(fixture.links == [fixture.expectedURL("new-session")])
        }
    }

    @Test(arguments: BillingOperationFixture.Entry.allCases)
    func removingTheViewCancelsItsRequest(_ entry: BillingOperationFixture.Entry) async throws {
        try await withEntry(entry) { fixture, host in
            try fixture.button(in: host).press()
            let task = try await fixture.started()
            host.window?.contentView = nil
            try await SettingsBehaviorTestSupport.wait { task.isCancelled }
            fixture.fail()
            await task.value
            #expect(fixture.links.isEmpty)
            #expect(fixture.dismissals == 0)
            #expect(!fixture.lifetime.isBusy)
        }
    }

    @Test(arguments: [true, false])
    func outerCancellationAndThrowingExitJoinTheRequestAndCloseTheWindow(_ cancel: Bool) async throws {
        var ready = false
        var terminal = false
        var window: NSWindow?
        var request: Task<Void, Never>?
        var lifetime: BillingActionLifetime?
        let outer = Task { @MainActor in
            defer { terminal = true }
            try await withEntry(.cardPlans) { fixture, host in
                window = host.window
                lifetime = fixture.lifetime
                try fixture.button(in: host).press()
                request = try await fixture.started()
                ready = true
                if cancel { try await Task.sleep(for: .seconds(30)) } else { throw FixtureExit() }
            }
        }
        do {
            try await SettingsBehaviorTestSupport.wait { ready || terminal }
            #expect(ready, "The fixture must reach its held request before exiting")
            if cancel { outer.cancel() }
            let result = await outer.result
            if case .failure(let error) = result {
                #expect(cancel ? error is CancellationError : error is FixtureExit)
            } else {
                Issue.record("The fixture must propagate its cancellation or throwing exit")
            }
            #expect(request?.isCancelled == true)
            #expect(lifetime?.isBusy == false)
            #expect(window?.isVisible == false)
            #expect(window?.contentView == nil)
        } catch {
            outer.cancel()
            _ = await outer.result
            throw error
        }
    }

    private struct FixtureExit: Error {}

    private func withEntry(_ entry: BillingOperationFixture.Entry,
                           check: (BillingOperationFixture, NSView) async throws -> Void) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try BillingOperationFixture(entry, defaults: settings.defaults)
            do {
                await fixture.prepare()
                try await SettingsBehaviorTestSupport.withWindow(fixture.view(), width: 860, height: 1000) { _, host in
                    try await SettingsBehaviorTestSupport.wait { fixture.hasButton(in: host) }
                    try await check(fixture, host)
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }
}

@MainActor
final class BillingOperationFixture {
    enum Entry: CaseIterable {
        case accountPlans, accountPortal, cardPlans, cardPortal, credits, upgrade

        var isPortal: Bool { self == .accountPortal || self == .cardPortal }
        var isCard: Bool { self == .cardPlans || self == .cardPortal }
        var title: String {
            switch self {
            case .accountPlans: L("account.offer.upgradeTitle")
            case .accountPortal: L("account.page.openPortal")
            case .cardPlans: L("account.card.plans")
            case .cardPortal: L("account.card.manage")
            case .credits: L("ask.credits.buy")
            case .upgrade: L("ask.credits.upgrade")
            }
        }
    }

    static let failure = NSError(domain: "BillingFixture", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Private account billing failure"])
    let entry: Entry
    let lifetime = BillingActionLifetime()
    let pages = BillingHeldCalls<BillingPageTokenResponse>()
    let portals = BillingHeldCalls<BillingPortalSession>()
    let syncs = BillingHeldCalls<BillingSubscriptionSnapshot>()
    let conversation: AskTestFixture
    let expiry = Int(Date().timeIntervalSince1970) + 3600
    private(set) var auth: AuthState!
    var links: [URL] = []
    var dismissals = 0
    private var tasks: [Task<Void, Never>] = []

    init(_ entry: Entry, defaults: UserDefaults) throws {
        self.entry = entry
        conversation = try AskTestFixture(
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        )
        auth = AuthState(
            loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil },
            saveStoredToken: { _, _ in }, saveStoredSession: { _, _, _ in }, saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { token in
                UserProfile(id: token, email: "fixture@example.com", name: "Billing Fixture", status: 1,
                            provider: "password", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
            },
            refreshAccessToken: { _ in
                .init(accessToken: "a2", expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                      refreshToken: "refresh-a2")
            },
            fetchSubscription: { _ in Self.subscription(paid: entry.isPortal) },
            syncSubscription: { [syncs] token in try await syncs.next(token) },
            fetchCurrentPeriodUsageStats: { _ in
                .init(periodStart: "2026-10-01T00:00:00Z", periodEnd: "2026-11-01T00:00:00Z", stats: .empty,
                      credits: .init(limit: 100, used: 100, remaining: 0, unlimited: false))
            },
            fetchCurrentPeriodUsageBreakdown: { _, _ in
                .init(periodStart: "2026-10-01T00:00:00Z", periodEnd: "2026-11-01T00:00:00Z", timezone: "UTC",
                      days: [], voice: 0, rewrite: 0, ask: 0)
            },
            createPortalSession: { [portals] token in try await portals.next(token) },
            issueBillingPageToken: { [pages] token in try await pages.next(token) }
        )
    }

    static func subscription(paid: Bool) -> BillingSubscriptionSnapshot {
        .init(planCode: paid ? "pro" : "free", status: paid ? "active" : "free", currentPeriodStart: nil,
              currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true, paid: paid, billingEnabled: true)
    }

    func prepare() async {
        await auth.handleLoginSuccess(token: "a1", expiresAt: expiry)
        await auth.refreshSubscription()
        await auth.refreshUsage()
        await seedConversation()
    }

    func seedConversation() async {
        let run = AskRun(id: "paused", deviceId: "device", status: "paused_credits", steps: 1,
                         updatedAt: Date(), tools: [], pending: [])
        await conversation.api.seed(.init(id: "paused", title: "Credit checkpoint", revision: 1,
                                          updatedAt: Date(), messages: [], run: run))
        await conversation.model.refreshHistory()
        await conversation.model.select("paused")
    }

    func view() -> some View {
        let content: AnyView
        switch entry {
        case .accountPlans, .accountPortal:
            content = AnyView(AccountView(authState: auth, onLogout: {}, billingLifetime: self.lifetime))
        case .cardPlans, .cardPortal:
            content = AnyView(AskAccountCard(auth: auth, onOpenAccount: {}, onDismiss: { self.dismissals += 1 },
                                             billingLifetime: self.lifetime))
        case .credits, .upgrade:
            content = AnyView(AskCreditPauseSection(
                model: conversation.model, auth: auth, billingLifetime: self.lifetime
            ))
        }
        return content.environment(\.openURL, OpenURLAction { url in
            self.links.append(url)
            return .handled
        })
    }

    func hasButton(in host: NSView) -> Bool {
        SettingsBehaviorTestSupport.elements(in: host).contains {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label.hasPrefix(entry.title)
                && ($0.value("isAccessibilityEnabled") as? Bool == true)
        }
    }

    func button(in host: NSView) throws -> SettingsBehaviorTestSupport.Element {
        try #require(SettingsBehaviorTestSupport.elements(in: host).first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label.hasPrefix(entry.title)
        }, "Missing billing entry: \(entry) / \(entry.title)")
    }

    var calls: [String] { entry.isPortal ? portals.calls : pages.calls }

    func started(count: Int = 1) async throws -> Task<Void, Never> {
        try await SettingsBehaviorTestSupport.wait { self.calls.count >= count || !self.lifetime.isBusy }
        #expect(calls.count >= count, "The consumer terminated before submitting the request")
        let task = try #require(lifetime.task, "The real consumer must own the pending request")
        track(task)
        return task
    }

    func track(_ task: Task<Void, Never>) { tasks.append(task) }

    func expectedURL(_ path: String) -> URL {
        let url = URL(string: "https://billing.example/\(path)")!
        return entry == .credits ? BillingPlansLink.url(url, tab: BillingPlansLink.creditsTab) : url
    }

    func succeed(_ path: String) {
        let url = URL(string: "https://billing.example/\(path)")!
        if entry.isPortal { portals.resolveNext(with: .success(.init(url: url))) } else {
            pages.resolveNext(with: .success(.init(token: path, plansURL: url)))
        }
    }

    func fail() {
        if entry.isPortal { portals.resolveNext(with: .failure(Self.failure)) } else {
            pages.resolveNext(with: .failure(Self.failure))
        }
    }

    func close() async {
        if let task = lifetime.task { tasks.append(task) }
        lifetime.cancel()
        tasks.forEach { $0.cancel() }
        pages.close(); portals.close(); syncs.close()
        for task in tasks { await task.value }
        auth.refreshTimer?.invalidate()
        conversation.model.resetSession()
        try? FileManager.default.removeItem(at: conversation.root)
    }
}
