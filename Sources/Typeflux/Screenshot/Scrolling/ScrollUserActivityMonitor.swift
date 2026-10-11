import AppKit

/// The user touched the mouse during automatic scrolling.
enum ScrollUserActivity: Equatable {
    case scrolled
    case clicked
    /// The pointer moved, to this point in global Quartz points.
    case moved(CGPoint)
    case dragged(CGPoint)
}

/// Watches for the user's own mouse input in other apps, so automatic scrolling can step aside.
@MainActor
protocol ScrollUserActivityMonitoring: AnyObject {
    func start(_ handler: @escaping (ScrollUserActivity) -> Void)
    func stop()
}

@MainActor
final class ScrollUserActivityMonitor: ScrollUserActivityMonitoring {
    private var monitor: Any?

    func start(_ handler: @escaping (ScrollUserActivity) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .mouseMoved, .leftMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            let cgEvent = event.cgEvent
            guard let activity = Self.activity(type: event.type,
                                               userData: cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                                               location: cgEvent?.location ?? .zero) else { return }
            MainActor.assumeIsolated { handler(activity) }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// What an event means, or nil for Typeflux's own wheel events and anything else.
    nonisolated static func activity(type: NSEvent.EventType, userData: Int64,
                                     location: CGPoint) -> ScrollUserActivity? {
        guard userData != ScrollDriverEventMark.userData else { return nil }
        switch type {
        case .scrollWheel: return .scrolled
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .clicked
        case .mouseMoved: return .moved(location)
        case .leftMouseDragged: return .dragged(location)
        default: return nil
        }
    }
}
