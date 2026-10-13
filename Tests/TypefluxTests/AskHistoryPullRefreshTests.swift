import AppKit
import Testing
@testable import Typeflux

@Suite("Ask native pull refresh", .exclusiveUIState)
@MainActor
struct AskHistoryPullRefreshTests {
    @Test func listBackgroundFindsItsNativeTableAndReleasesItOnDetach() async throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let scroll = NSScrollView(frame: container.bounds)
        scroll.documentView = NSTableView(frame: container.bounds)
        let probe = AskHistoryPullRefresh.Probe(frame: container.bounds)
        container.addSubview(scroll)
        container.addSubview(probe)
        let window = NSWindow(contentRect: container.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.enclosingScrollView == nil)
        #expect(probe.scrollView === scroll)
        probe.removeFromSuperview()
        #expect(probe.scrollView == nil)
    }

    private func pull(_ probe: AskHistoryPullRefresh.Probe, momentum: NSEvent.Phase = [], atTop: Bool = true,
                      phases: [NSEvent.Phase]) {
        for phase in phases { probe.observeWheel(phase: phase, momentum: momentum, atTop: atTop) }
    }

    @Test func releasingPastTheThresholdRefreshesOnce() {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        // Overscroll is reported by clip-view bounds changes; drive the same input.
        pull(probe, phases: [.began])
        probe.reportOverscrollForTesting(AskHistoryPullGesture.threshold + 4)
        pull(probe, phases: [.changed])
        #expect(refreshes == 0)
        pull(probe, phases: [.ended])
        #expect(refreshes == 1)
        pull(probe, phases: [.ended])
        #expect(refreshes == 1)
    }

    @Test func lightPullsCancelledGesturesAndMomentumDoNotRefresh() {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        pull(probe, phases: [.began])
        probe.reportOverscrollForTesting(AskHistoryPullGesture.threshold - 5)
        pull(probe, phases: [.ended])
        #expect(refreshes == 0)
        pull(probe, phases: [.began])
        probe.reportOverscrollForTesting(200)
        pull(probe, phases: [.cancelled])
        #expect(refreshes == 0)
        pull(probe, phases: [.began])
        probe.reportOverscrollForTesting(200)
        pull(probe, momentum: .changed, phases: [.ended])
        #expect(refreshes == 0)
    }

    @Test func gesturesNotStartedAtTopOrDuringRefreshAreIgnored() {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        pull(probe, atTop: false, phases: [.began])
        probe.reportOverscrollForTesting(200)
        pull(probe, phases: [.ended])
        #expect(refreshes == 0)
        probe.isRefreshing = true
        pull(probe, phases: [.began])
        probe.reportOverscrollForTesting(200)
        pull(probe, phases: [.ended])
        #expect(refreshes == 0)
    }
}
