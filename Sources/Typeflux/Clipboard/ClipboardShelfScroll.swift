import CoreGraphics

/// Motion constants and wheel handling of the clipboard shelf.
enum ClipboardShelfScroll {
    /// How far below its final frame the shelf starts sliding up.
    static let slideDistance: CGFloat = 28

    /// A notched mouse wheel moves the selection one card per notch, down meaning the next card.
    /// Trackpad (precise) and mostly horizontal scrolls are left to the rail's scroll view.
    static func selectionDelta(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> Int? {
        guard !isPrecise, deltaY != 0, abs(deltaY) > abs(deltaX) else { return nil }
        return deltaY < 0 ? 1 : -1
    }
}
