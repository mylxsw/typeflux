import SwiftUI

/// Extents along the scroll axis of the rows (or shelf cards) SwiftUI has built, in the viewport's
/// coordinates: vertical in the list, horizontal on the shelf. A reference type so updating it
/// while scrolling does not redraw the panel.
final class ClipboardRowFrames {
    var frames: [Int: ClosedRange<CGFloat>] = [:]
    /// The viewport's length along the scroll axis (the shelf stores its width here).
    var viewportHeight: CGFloat = 0
}

/// Collects each built row's extent keyed by its index among the visible entries.
struct ClipboardRowFramesKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]

    static func reduce(value: inout [Int: ClosedRange<CGFloat>], nextValue: () -> [Int: ClosedRange<CGFloat>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
