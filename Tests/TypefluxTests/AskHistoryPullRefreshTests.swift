import AppKit
import Testing
@testable import Typeflux

@Suite("Ask native pull refresh")
@MainActor
struct AskHistoryPullRefreshTests {
    @Test func trackpadMomentumAndCancelledPullsDoNotRefresh() {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        probe.observeWheel(delta: 80, phase: .changed, momentum: .changed, atTop: true)
        probe.observeWheel(delta: 0, phase: .ended, momentum: [], atTop: true)
        #expect(refreshes == 0)
        probe.observeWheel(delta: 60, phase: .began, momentum: [], atTop: true)
        probe.observeWheel(delta: 0, phase: .cancelled, momentum: [], atTop: true)
        #expect(refreshes == 0)
        probe.observeWheel(delta: 70, phase: .began, momentum: [], atTop: true)
        probe.observeWheel(delta: 70, phase: .changed, momentum: [], atTop: true)
        probe.observeWheel(delta: 0, phase: .ended, momentum: [], atTop: true)
        #expect(refreshes == 1)
    }

    @Test func lightTugAndGesturesNotStartedAtTopDoNotRefresh() {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        // A light tug (60pt of finger travel = 30pt resisted) stays under the threshold.
        probe.observeWheel(delta: 30, phase: .began, momentum: [], atTop: true)
        probe.observeWheel(delta: 30, phase: .changed, momentum: [], atTop: true)
        probe.observeWheel(delta: 0, phase: .ended, momentum: [], atTop: true)
        #expect(refreshes == 0)
        // Scrolling up from mid-list and arriving at the top mid-gesture is ignored.
        probe.observeWheel(delta: 10, phase: .began, momentum: [], atTop: false)
        probe.observeWheel(delta: 400, phase: .changed, momentum: [], atTop: true)
        probe.observeWheel(delta: 0, phase: .ended, momentum: [], atTop: true)
        #expect(refreshes == 0)
    }

    @Test func unphasedWheelSettlesBeforeRefreshingAndCoalesces() async throws {
        let probe = AskHistoryPullRefresh.Probe()
        var refreshes = 0
        probe.onRefresh = { refreshes += 1 }
        probe.observeWheel(delta: 70, phase: [], momentum: [], atTop: true)
        probe.observeWheel(delta: 70, phase: [], momentum: [], atTop: true)
        #expect(refreshes == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(refreshes == 1)
        probe.isRefreshing = true
        probe.observeWheel(delta: 100, phase: [], momentum: [], atTop: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(refreshes == 1)
    }

    @Test func nativeDragOnlyRefreshesAtTopAndOnceOnRelease() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        let probe = AskHistoryPullRefresh.Probe(frame: document.bounds)
        document.addSubview(probe); scroll.documentView = document; window.contentView = scroll
        var refreshes = 0, distance: CGFloat = 0
        probe.onRefresh = { refreshes += 1 }
        probe.onDistance = { distance = $0 }
        // Native pointer dragging exercises the same top-edge gate without
        // depending on system scroll-wheel event synthesis or device settings.
        func mouse(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        scroll.contentView.scroll(to: .zero)
        probe.observe(try mouse(.leftMouseDown, y: 150))
        probe.observe(try mouse(.leftMouseDragged, y: 80))
        probe.observe(try mouse(.leftMouseUp, y: 80))
        #expect(refreshes == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        probe.observe(try mouse(.leftMouseDown, y: 150))
        probe.observe(try mouse(.leftMouseDragged, y: 0))
        #expect(distance >= AskHistoryPullGesture.threshold)
        #expect(refreshes == 0)
        probe.observe(try mouse(.leftMouseUp, y: 80))
        probe.observe(try mouse(.leftMouseUp, y: 80))
        #expect(refreshes == 1 && distance == 0)
        probe.isRefreshing = true
        probe.observe(try mouse(.leftMouseDown, y: 150))
        probe.observe(try mouse(.leftMouseDragged, y: 80))
        probe.observe(try mouse(.leftMouseUp, y: 80))
        #expect(refreshes == 1)
    }
}
