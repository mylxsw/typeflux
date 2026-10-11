import CoreGraphics
import Foundation

/// How one pinned screenshot is shown: its zoom, its opacity and whether clicks go through it.
/// Pure, so the panel only applies it.
struct ScreenshotPinState: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4
    static let opacityRange: ClosedRange<CGFloat> = 0.2...1
    /// What one step of the buttons or the wheel changes.
    static let zoomStep: CGFloat = 0.1
    static let opacityStep: CGFloat = 0.1
    /// Scroll distance, in points, that makes one step with a trackpad or a smooth mouse.
    static let pointsPerStep: CGFloat = 12

    var zoom: CGFloat = 1
    var opacity: CGFloat = 1
    /// The pin ignores the mouse, so what is under it can be clicked.
    var clickThrough = false

    /// "80%".
    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }

    mutating func zoom(by steps: CGFloat) {
        zoom = Self.clamp(((zoom + steps * Self.zoomStep) * 100).rounded() / 100, to: Self.zoomRange)
    }

    mutating func changeOpacity(by steps: CGFloat) {
        opacity = Self.clamp(((opacity + steps * Self.opacityStep) * 100).rounded() / 100, to: Self.opacityRange)
    }

    /// The wheel zooms, or changes the opacity with ⌥. Scrolling up makes it bigger or more opaque.
    /// - Parameters:
    ///   - delta: the vertical scroll, positive upward.
    ///   - precise: a trackpad or smooth mouse reports points, not notches.
    mutating func scroll(by delta: CGFloat, precise: Bool, adjustsOpacity: Bool) {
        guard delta != 0 else { return }
        let steps = precise ? delta / Self.pointsPerStep : (delta > 0 ? 1 : -1)
        if adjustsOpacity { changeOpacity(by: steps) } else { zoom(by: steps) }
    }

    /// The window frame for an image of `size` points at this zoom, with the top-left corner of
    /// `frame` kept where it is. AppKit coordinates: y grows upward.
    func frame(keepingTopLeftOf frame: CGRect, imageSize size: CGSize) -> CGRect {
        let width = max((size.width * zoom).rounded(), 1), height = max((size.height * zoom).rounded(), 1)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
