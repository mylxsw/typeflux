import Foundation

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

    /// Shorter presses latch the ring open; holds resolve the pointer on release.
    static let holdDuration: TimeInterval = 0.3

    private(set) var isHeld = false
    private var openedByPress = false
    private var pressTime: TimeInterval?

    mutating func pressBegan(isVisible: Bool, at time: TimeInterval) -> Press {
        guard !isHeld else { return .ignore }
        isHeld = true
        openedByPress = !isVisible
        pressTime = time
        return isVisible ? .dismiss : .show
    }

    mutating func pressEnded(isVisible: Bool, at time: TimeInterval) -> Release {
        guard isHeld else { return .keepOpen }
        defer { reset() }
        guard openedByPress, isVisible, let began = pressTime,
              time - began >= Self.holdDuration
        else { return .keepOpen }
        return .activate
    }

    mutating func reset() {
        isHeld = false
        openedByPress = false
        pressTime = nil
    }
}
