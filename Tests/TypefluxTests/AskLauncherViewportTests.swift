import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Launcher viewport motion", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherViewportTests {
    @Test func `results follow the visible card once a panel drives it`() {
        let viewport = AskLauncherViewport()
        #expect(viewport.resultsHeight(chrome: 120, natural: 300) == 300, "no panel yet: natural height")
        #expect(viewport.resultsHeight(chrome: 120, available: 480, natural: 300) == 360,
                "a plain host lets the results fill its height")
        viewport.show(400)
        #expect(viewport.resultsHeight(chrome: 120, natural: 300) == 280)
        #expect(viewport.resultsHeight(chrome: 120, available: 480, natural: 300) == 280, "a driven card wins")
        viewport.show(80)
        #expect(viewport.resultsHeight(chrome: 120, natural: 300) == 0, "never negative while the card is short")
    }

    @Test func `showing the same height does not publish`() {
        let viewport = AskLauncherViewport()
        var changes = 0
        let subscription = viewport.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        viewport.show(200)
        viewport.show(200)
        #expect(changes == 1, "only a new visible height re-renders the clip")
    }

    @Test func `a display clock in a window ticks until its callback stops`() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        let clock = AskDisplayClock()
        var times: [TimeInterval] = []
        clock.start(view: window.contentView) { time in
            times.append(time)
            return times.count < 3
        }
        #expect(clock.isRunning)
        for _ in 0 ..< 400 where clock.isRunning {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!clock.isRunning, "returning false ends the clock")
        #expect(times.count == 3)
        #expect(times == times.sorted(), "frames arrive in order")
    }

    @Test func `a callback that restarts the clock keeps the new run`() async throws {
        let clock = AskDisplayClock()
        var restarted = 0
        clock.start(view: nil) { _ in
            clock.start(view: nil) { _ in restarted += 1; return restarted < 2 }
            return false
        }
        for _ in 0 ..< 400 where clock.isRunning {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(restarted == 2, "the first run's end must not stop the run it started")
        clock.stop()
        #expect(!clock.isRunning)
    }

    @Test func `an animator that goes away stops its clock`() async throws {
        var animator: AskLauncherHeightAnimator? = AskLauncherHeightAnimator()
        var applied = 0
        animator?.update(from: 100, to: 500, animated: true, rate: 2) { _ in applied += 1 }
        try await Task.sleep(for: .milliseconds(40))
        animator = nil
        let count = applied
        try await Task.sleep(for: .milliseconds(80))
        #expect(applied == count, "no frames are applied for an animator that no longer exists")
    }

    @Test func `the panel resizes once per motion while the card animates`() async throws {
        _ = NSApplication.shared
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        fixture.model.appIndex = AskTestAppIndex((0 ..< 5).map {
            AskTestAppIndex.app("Alpha \($0)", id: "viewport.\($0)")
        })
        let suite = "ask-viewport-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        await fixture.model.prepareLauncher()
        let controller = AskConversationWindowController(
            settings: settings, model: fixture.model,
            dockVisibility: DockVisibilityController(app: ViewportActivationPolicy()),
            launcherInputSource: ViewportInputSource()
        )
        defer { controller.dismissLauncher() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        try await fixture.wait { !fixture.model.capturing && !fixture.model.quickSearch.isSearching }
        try await fixture.wait { !controller.launcherIsResizing }
        var resizes: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                              queue: nil) { _ in
            MainActor.assumeIsolated { resizes.append(window.frame.height) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // No match keeps the results area empty; five matches need far more room.
        fixture.model.launcherDraft.text = "zzqqxx"
        try await Task.sleep(for: .milliseconds(900))
        try await fixture.wait { !controller.launcherIsResizing }
        for text in ["alpha", "zzqqxx"] {
            resizes = []
            let start = controller.launcherVisibleHeight
            var visible: [CGFloat] = []
            fixture.model.launcherDraft.text = text
            // Long enough for the reserve to settle after typing pauses, and for the motion.
            for _ in 0 ..< 250 {
                try await Task.sleep(for: .milliseconds(4))
                visible.append(controller.launcherVisibleHeight)
                #expect(window.frame.height >= controller.launcherVisibleHeight - 0.5)
            }
            try await fixture.wait { !controller.launcherIsResizing }
            let end = controller.launcherVisibleHeight
            let label = text == "alpha" ? "growing" : "shrinking"
            #expect(abs(end - start) > 40, "\(label) must change the card's height: \(start) → \(end)")
            #expect(resizes.count <= 2, "\(label) resized the panel \(resizes.count) times")
            let between = Set(visible.filter { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 }
                .map { $0.rounded() })
            #expect(between.count >= 3, "\(label) must pass through intermediate heights: \(visible)")
            #expect(abs(window.frame.height - end) < 0.5, "the panel matches the card at rest")
        }
    }
}

private final class ViewportActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
    }
}

@MainActor
private struct ViewportInputSource: AskLauncherInputSourceSelecting {
    func select(sourceID _: String) {}
}
