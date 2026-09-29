import AppKit
import SwiftUI

/// Decides whether a trackpad gesture counts as a deliberate pull-to-refresh.
/// The list itself rubber-bands natively; this only judges how far it was
/// overscrolled while the finger was down, and refreshes on release.
struct AskHistoryPullGesture {
    /// Native overscroll, in points, the user must reach before letting go.
    static let threshold: CGFloat = 56
    private(set) var armed = false
    private(set) var peak: CGFloat = 0

    /// A gesture only counts if it began while the list was already at the top,
    /// so scrolling up from mid-list and bouncing off the top never refreshes.
    mutating func begin(atTop: Bool) {
        armed = atTop
        peak = 0
    }

    /// Momentum bounces arrive after `end`, when `armed` is false again.
    mutating func update(overscroll: CGFloat) {
        guard armed else { return }
        peak = max(peak, overscroll)
    }

    mutating func end(cancelled: Bool = false) -> Bool {
        let refresh = armed && !cancelled && peak >= Self.threshold
        armed = false
        peak = 0
        return refresh
    }

    /// How far the clip view is scrolled past the top edge (0 when at rest or scrolled down).
    static func overscroll(bounds: NSRect, documentBounds: NSRect, flipped: Bool, topInset: CGFloat = 0) -> CGFloat {
        let raw = flipped ? -(bounds.minY + topInset) : bounds.maxY - documentBounds.maxY
        return max(0, raw)
    }
}

/// Observes the native scroll view without replacing SwiftUI's list, selection,
/// accessibility, or scroll position. It enables elastic overscroll (so the list
/// gives real physical feedback), reports the overscroll distance for the
/// indicator, and refreshes when a top-started trackpad pull is released past
/// the threshold. Momentum and mouse wheels never trigger a refresh.
struct AskHistoryPullRefresh: NSViewRepresentable {
    var isRefreshing: Bool
    var onDistance: (CGFloat) -> Void
    var onRefresh: () -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.isRefreshing = isRefreshing
        view.onDistance = onDistance; view.onRefresh = onRefresh
    }
    final class Probe: NSView {
        var isRefreshing = false
        var onDistance: (CGFloat) -> Void = { _ in }
        var onRefresh: () -> Void = {}
        private var monitor: Any?
        private var gesture = AskHistoryPullGesture()
        private var lastDistance: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self)
            _ = gesture.end(cancelled: true)
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.observe(event)
                return event
            }
            // SwiftUI attaches the scroll view after this view enters the window.
            DispatchQueue.main.async { [weak self] in self?.attachToScrollView() }
        }
        private func attachToScrollView() {
            guard window != nil, let scroll = enclosingScrollView else { return }
            scroll.verticalScrollElasticity = .allowed
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
        @objc private func clipBoundsChanged() { reportOverscroll() }
        private func currentOverscroll() -> CGFloat {
            guard let scroll = enclosingScrollView else { return 0 }
            return AskHistoryPullGesture.overscroll(
                bounds: scroll.contentView.bounds,
                documentBounds: scroll.documentView?.bounds ?? .zero,
                flipped: scroll.documentView?.isFlipped == true,
                topInset: scroll.contentInsets.top
            )
        }
        private func atTop() -> Bool { currentOverscroll() > 0 || restingAtTop() }
        private func restingAtTop() -> Bool {
            guard let scroll = enclosingScrollView else { return false }
            let bounds = scroll.contentView.bounds
            return scroll.documentView?.isFlipped == true
                ? bounds.minY <= -scroll.contentInsets.top + 1
                : bounds.maxY >= (scroll.documentView?.bounds.maxY ?? 0) - 1
        }
        func reportOverscroll() { report(currentOverscroll()) }
        /// Test seam: the scroll view's bounds cannot be overscrolled without a real trackpad.
        func reportOverscrollForTesting(_ distance: CGFloat) { report(distance) }
        private func report(_ distance: CGFloat) {
            gesture.update(overscroll: distance)
            if distance != lastDistance { lastDistance = distance; onDistance(distance) }
        }
        func observe(_ event: NSEvent) {
            guard event.type == .scrollWheel, event.window === window, let scroll = enclosingScrollView,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            else { return }
            observeWheel(phase: event.phase, momentum: event.momentumPhase, atTop: atTop())
        }
        func observeWheel(phase: NSEvent.Phase, momentum: NSEvent.Phase, atTop: Bool) {
            guard !isRefreshing, momentum.isEmpty else { return }
            if phase.contains(.began) || phase.contains(.mayBegin) { gesture.begin(atTop: atTop) }
            if phase.contains(.cancelled) { finish(cancelled: true) }
            else if phase.contains(.ended) { finish() }
        }
        private func finish(cancelled: Bool = false) {
            if gesture.end(cancelled: cancelled), !isRefreshing { onRefresh() }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(self)
        }
    }
}
