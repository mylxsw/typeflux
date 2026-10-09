import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Real mouse events on the Ask sidebar's account name: a click opens the glass
/// account card above it, a second click closes it. Part of the serialized
/// event-delivery suite so clicks never overlap the hold-to-talk monitors.
extension AskComposerInteractionTests {
    @Test func accountNameClickTogglesTheAccountCard() async throws {
        let auth = makeFooterAuth()
        #expect(auth.isLoggedIn)
        var openedAccount = 0
        // At the foot of the usable screen, like the sidebar's footer, so the card has room
        // above it even on a short display.
        let visible = try #require(NSScreen.main?.visibleFrame)
        let window = AccountFooterClickWindow(contentRect: NSRect(x: visible.minX + 200, y: visible.minY + 12,
                                                                  width: 248, height: 50),
                                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: HStack {
            AskAccountFooterIdentity(auth: auth, name: "Demir Von") { openedAccount += 1 }
            Spacer()
        }.padding(.leading, 18).frame(width: 248, height: 50))
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            AskGlassMenuPresenter.shared.hide()
            window.close()
        }
        try await poll { auth.usageCredits != nil }
        // The badge reflects the quota once the summary loads: 15% left.
        #expect(AccountStatusPresentation.make(subscription: auth.subscription, credits: auth.usageCredits,
                                               usagePeriodStart: auth.usagePeriodStart,
                                               usagePeriodEnd: auth.usagePeriodEnd).badge == .low(percent: 15))

        let point = NSPoint(x: 40, y: 25)
        let presenter = AskGlassMenuPresenter.shared
        try click(point, in: window)
        try await poll { presenter.isShowing && presenter.panel?.frame.width ?? 0 > 0 }
        #expect(presenter.isShowing)
        let panel = try #require(presenter.panel)
        #expect(panel.isVisible)
        #expect(abs(panel.frame.width - AskAccountCard.width) < 1)
        // Above the name, its leading edge just left of it.
        #expect(panel.frame.minY >= window.convertPoint(toScreen: point).y + 15 - 1)
        #expect(presenter.containsPointer(NSPoint(x: panel.frame.midX, y: panel.frame.midY)))
        #expect(presenter.containsPointer(window.convertPoint(toScreen: point)))
        #expect(!presenter.containsPointer(NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)))

        try click(point, in: window)
        try await poll { !presenter.isShowing }
        #expect(!presenter.isShowing)
        #expect(openedAccount == 0)
    }

    private func makeFooterAuth() -> AuthState {
        AuthState(
            loadStoredToken: { ("valid-token", Int(Date().timeIntervalSince1970) + 3600) },
            loadStoredRefreshToken: { nil },
            loadStoredUserProfile: {
                UserProfile(id: "u", email: "demir@example.com", name: "Demir Von", status: 1, provider: "google",
                            createdAt: "2026-03-01T00:00:00Z", updatedAt: "2026-03-01T00:00:00Z")
            },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in throw AuthError.invalidResponse },
            fetchSubscription: { _ in
                BillingSubscriptionSnapshot(planCode: "free", status: "free", currentPeriodStart: nil,
                                            currentPeriodEnd: nil, cancelAtPeriodEnd: false, entitled: true,
                                            billingEnabled: true)
            },
            fetchCurrentPeriodUsageStats: { _ in
                CloudUsageCurrentPeriodStats(periodStart: "2026-10-01T00:00:00Z", periodEnd: "2026-11-01T00:00:00Z",
                                             stats: .empty,
                                             credits: CloudCreditSummary(limit: 60000, used: 51000, remaining: 9000,
                                                                         unlimited: false))
            },
            fetchCurrentPeriodUsageBreakdown: { _, _ in throw AuthError.invalidResponse }
        )
    }

    private func poll(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }
}

@MainActor
private final class AccountFooterClickWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
