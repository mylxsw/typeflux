import AppKit
import Testing
@testable import Typeflux

@Suite("Ask native pull refresh")
@MainActor
struct AskHistoryPullRefreshTests {
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
