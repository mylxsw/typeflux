import AppKit
import ApplicationServices
import CoreGraphics

/// Scrolls the app under the region by sending wheel events, for automatic scrolling capture.
@MainActor
protocol ScrollDriving: AnyObject {
    /// Sending events needs Accessibility access; without it the user scrolls by hand.
    var canScroll: Bool { get }
    /// Where the pointer was put for scrolling, in global Quartz points; nil before `begin`.
    var anchor: CGPoint? { get }
    /// Puts the pointer inside the region (global Quartz points) when it is elsewhere, so the wheel
    /// events reach the app there; `end()` puts it back.
    func begin(in region: CGRect)
    /// Scrolls forward along `axis` by about `points`; negative scrolls back.
    func scroll(by points: CGFloat, axis: ScrollCaptureAxis)
    /// Puts the pointer back where it was, unless the user has moved it since.
    func end()
}

/// Wheel events from `ScrollDriver` carry this, so the activity monitor can tell them from the user's.
enum ScrollDriverEventMark {
    static let userData: Int64 = 0x5459_5046_5343_524C
}

/// Pixel-precise wheel events through Quartz Event Services.
@MainActor
final class ScrollDriver: ScrollDriving {
    private let isTrusted: () -> Bool
    private let pointerLocation: () -> CGPoint
    private let warp: (CGPoint) -> Void
    private let post: (CGEvent) -> Void
    /// Where the pointer was before it was moved into the region.
    private var restoreLocation: CGPoint?
    /// Where the pointer was put.
    private(set) var anchor: CGPoint?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         pointerLocation: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         warp: @escaping (CGPoint) -> Void = { point in
             CGWarpMouseCursorPosition(point)
             // Without this the pointer stays frozen for a moment after the warp.
             CGAssociateMouseAndMouseCursorPosition(1)
         },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.isTrusted = isTrusted
        self.pointerLocation = pointerLocation
        self.warp = warp
        self.post = post
    }

    var canScroll: Bool {
        isTrusted()
    }

    func begin(in region: CGRect) {
        let pointer = pointerLocation()
        guard !region.insetBy(dx: 1, dy: 1).contains(pointer) else {
            anchor = pointer
            return
        }
        let center = CGPoint(x: region.midX, y: region.midY)
        restoreLocation = pointer
        anchor = center
        warp(center)
    }

    func scroll(by points: CGFloat, axis: ScrollCaptureAxis = .vertical) {
        guard let event = Self.wheelEvent(points: points, axis: axis, at: anchor ?? pointerLocation()) else { return }
        post(event)
    }

    func end() {
        defer {
            restoreLocation = nil
            anchor = nil
        }
        guard let restoreLocation, let anchor else { return }
        let pointer = pointerLocation()
        guard hypot(pointer.x - anchor.x, pointer.y - anchor.y) < 2 else { return }
        warp(restoreLocation)
    }

    /// A pixel wheel event along the selected axis, marked as Typeflux's; negative points rewind.
    static func wheelEvent(points: CGFloat, axis: ScrollCaptureAxis = .vertical, at location: CGPoint) -> CGEvent? {
        guard points.isFinite else { return nil }
        let delta = Int32(min(max(-points.rounded(), CGFloat(Int32.min)), CGFloat(Int32.max)))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: axis == .vertical ? delta : 0,
                                  wheel2: axis == .horizontal ? delta : 0, wheel3: 0) else { return nil }
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: ScrollDriverEventMark.userData)
        return event
    }
}
