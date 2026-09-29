import AppKit
import SwiftUI

struct AskHistoryPullGesture {
    /// Resisted distance (in points) the user must reach before release refreshes.
    static let threshold: CGFloat = 64
    /// Fraction of finger travel that counts, so a light tug never gets close.
    static let resistance: CGFloat = 0.5
    static let maxDistance: CGFloat = 96
    private(set) var distance: CGFloat = 0
    mutating func pull(_ delta: CGFloat, atTop: Bool) {
        guard atTop || distance > 0 else { return }
        distance = min(Self.maxDistance, max(0, distance + delta * Self.resistance))
    }
    mutating func end(cancelled: Bool = false) -> Bool {
        let refresh = !cancelled && distance >= Self.threshold
        distance = 0
        return refresh
    }
}

/// Observes the native scroll view without replacing SwiftUI's list, selection,
/// accessibility, or scroll position. Momentum never triggers a refresh.
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
        private var globalRelease: Any?
        private var gesture = AskHistoryPullGesture()
        private var wheelEnd: Timer?
        private var dragY: CGFloat?
        /// A trackpad gesture only counts if it began while the list was already at
        /// the top; scrolling up and reaching the top mid-gesture must not refresh.
        private var gestureArmed = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let globalRelease { NSEvent.removeMonitor(globalRelease); self.globalRelease = nil }
            wheelEnd?.invalidate(); dragY = nil
            _ = gesture.end(cancelled: true)
            guard window != nil else { return }
            globalRelease = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                guard let self, self.dragY != nil else { return }
                self.dragY = nil; self.finish()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.observe(event)
                return event
            }
        }
        func observe(_ event: NSEvent) {
            if event.type == .leftMouseUp, dragY != nil {
                dragY = nil; finish(); return
            }
            guard !isRefreshing, event.window === window, let scroll = enclosingScrollView else { return }
            let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            let bounds = scroll.contentView.bounds
            let atTop = scroll.documentView?.isFlipped == true
                ? bounds.minY <= 1
                : bounds.maxY >= (scroll.documentView?.bounds.maxY ?? 0) - 1
            switch event.type {
            case .scrollWheel:
                guard inside else { return }
                observeWheel(delta: event.scrollingDeltaY, phase: event.phase, momentum: event.momentumPhase, atTop: atTop)
            case .leftMouseDown: dragY = inside && atTop ? event.locationInWindow.y : nil
            case .leftMouseDragged:
                if let previous = dragY {
                    gesture.pull(previous - event.locationInWindow.y, atTop: atTop)
                    dragY = event.locationInWindow.y
                    onDistance(gesture.distance)
                }
            case .leftMouseUp:
                if dragY != nil { dragY = nil; finish() }
            default: break
            }
        }
        func observeWheel(delta: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, atTop: Bool) {
            guard !isRefreshing, momentum.isEmpty else { return }
            wheelEnd?.invalidate()
            if phase.contains(.began) || phase.contains(.mayBegin) { gestureArmed = atTop }
            if phase.contains(.cancelled) { gestureArmed = false; finish(cancelled: true); return }
            if phase.contains(.ended) { finish(cancelled: !gestureArmed); gestureArmed = false; return }
            // Discrete mouse wheels have no phase; they are judged per event.
            guard phase.isEmpty ? atTop : gestureArmed else { return }
            gesture.pull(delta, atTop: atTop)
            onDistance(gesture.distance)
            if phase.isEmpty {
                let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.finish() }
                wheelEnd = timer; RunLoop.main.add(timer, forMode: .common)
            }
        }
        private func finish(cancelled: Bool = false) {
            wheelEnd?.invalidate()
            let refresh = gesture.end(cancelled: cancelled)
            onDistance(0)
            if refresh, !isRefreshing { onRefresh() }
        }
        deinit {
            wheelEnd?.invalidate()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let globalRelease { NSEvent.removeMonitor(globalRelease) }
        }
    }
}
