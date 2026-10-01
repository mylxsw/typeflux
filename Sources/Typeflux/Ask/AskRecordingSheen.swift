import AppKit
import QuartzCore
import SwiftUI

/// A highlight that travels around the composer's accent edge while recording.
///
/// It runs entirely in Core Animation: a conic gradient spins behind a fixed,
/// stroke-shaped mask, and the render server animates the rotation. Nothing in
/// SwiftUI or AppKit redraws per frame, so the glass card behind it is never
/// re-composited. A SwiftUI `TimelineView` version re-rendered the composer 30
/// times a second, which made the launcher panel and its edge flicker.
struct AskRecordingSheen: NSViewRepresentable {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    /// False under Reduce Motion: the highlight is not drawn at all.
    var animated: Bool

    func makeNSView(context _: Context) -> SheenView {
        let view = SheenView()
        view.configure(cornerRadius: cornerRadius, lineWidth: lineWidth, animated: animated)
        return view
    }

    func updateNSView(_ view: SheenView, context _: Context) {
        view.configure(cornerRadius: cornerRadius, lineWidth: lineWidth, animated: animated)
    }

    static let animationKey = "ask.recording.sheen"
    /// One lap of the highlight around the edge.
    static let period: CFTimeInterval = 3

    /// The spinning gradient must cover the edge at every angle, so it is a
    /// square as wide as the edge's diagonal, centred on it.
    static func gradientFrame(for bounds: CGRect) -> CGRect {
        let side = ceil(hypot(bounds.width, bounds.height))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// The stroke runs inside the bounds, like SwiftUI's `strokeBorder`.
    static func edgePath(in bounds: CGRect, cornerRadius: CGFloat, lineWidth: CGFloat) -> CGPath {
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        let radius = max(0, min(cornerRadius - lineWidth / 2, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func rotation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -2 * Double.pi
        animation.duration = period
        animation.repeatCount = .infinity
        // Survives the panel being ordered out and back in.
        animation.isRemovedOnCompletion = false
        return animation
    }

    final class SheenView: NSView {
        private let gradient = CAGradientLayer()
        private let mask = CAShapeLayer()
        private(set) var cornerRadius: CGFloat = 0
        private(set) var lineWidth: CGFloat = 1.5
        private(set) var animated = true

        var gradientLayer: CAGradientLayer { gradient }
        var maskLayer: CAShapeLayer { mask }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = [NSColor.clear, NSColor.white.withAlphaComponent(0.75), NSColor.clear, NSColor.clear]
                .map(\.cgColor)
            gradient.locations = [0, 0.12, 0.25, 1]
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            layer?.addSublayer(gradient)
            layer?.mask = mask
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_: NSPoint) -> NSView? { nil }

        func configure(cornerRadius: CGFloat, lineWidth: CGFloat, animated: Bool) {
            let geometryChanged = cornerRadius != self.cornerRadius || lineWidth != self.lineWidth
            self.cornerRadius = cornerRadius
            self.lineWidth = lineWidth
            self.animated = animated
            if geometryChanged { needsLayout = true }
            updateAnimation()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = bounds
            mask.lineWidth = lineWidth
            mask.path = AskRecordingSheen.edgePath(in: bounds, cornerRadius: cornerRadius, lineWidth: lineWidth)
            let frame = AskRecordingSheen.gradientFrame(for: bounds)
            gradient.bounds = CGRect(origin: .zero, size: frame.size)
            gradient.position = CGPoint(x: frame.midX, y: frame.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAnimation()
        }

        private func updateAnimation() {
            gradient.isHidden = !animated
            if animated {
                if gradient.animation(forKey: AskRecordingSheen.animationKey) == nil {
                    gradient.add(AskRecordingSheen.rotation(), forKey: AskRecordingSheen.animationKey)
                }
            } else {
                gradient.removeAnimation(forKey: AskRecordingSheen.animationKey)
            }
        }
    }
}
