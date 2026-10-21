import CoreGraphics

/// Hold-to-aim, release-to-run. A quick tap leaves the ring open for clicks and keys;
/// pressing again while it is open closes it.
struct RingHotkeyGesture: Equatable {
    enum Press: Equatable {
        case show
        case dismiss
        case ignore
    }

    enum Release: Equatable {
        /// Run the slice under the pointer, or close when the pointer is back in the middle.
        case activate
        case keepOpen
    }

    /// How far the pointer must move after the press before a release runs a slice.
    static let activationDistance: CGFloat = 20

    private(set) var isHeld = false
    private var openedByPress = false
    private var pressLocation: CGPoint?

    mutating func pressBegan(isVisible: Bool, at location: CGPoint) -> Press {
        guard !isHeld else { return .ignore }
        isHeld = true
        openedByPress = !isVisible
        pressLocation = location
        return isVisible ? .dismiss : .show
    }

    mutating func pressEnded(isVisible: Bool, at location: CGPoint) -> Release {
        guard isHeld else { return .keepOpen }
        defer { reset() }
        guard openedByPress, isVisible, let origin = pressLocation,
              hypot(location.x - origin.x, location.y - origin.y) >= Self.activationDistance
        else { return .keepOpen }
        return .activate
    }

    mutating func reset() {
        isHeld = false
        openedByPress = false
        pressLocation = nil
    }
}
