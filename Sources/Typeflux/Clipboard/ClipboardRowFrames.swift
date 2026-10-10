import SwiftUI

/// Vertical extents of the clipboard rows SwiftUI has built, in the list viewport's coordinates.
/// A reference type so updating it while scrolling does not redraw the panel.
final class ClipboardRowFrames {
    var frames: [Int: ClosedRange<CGFloat>] = [:]
    var viewportHeight: CGFloat = 0
}

/// Collects each built row's extent keyed by its index among the visible entries.
struct ClipboardRowFramesKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]

    static func reduce(value: inout [Int: ClosedRange<CGFloat>], nextValue: () -> [Int: ClosedRange<CGFloat>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
