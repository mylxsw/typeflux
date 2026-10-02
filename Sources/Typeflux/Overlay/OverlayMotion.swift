import SwiftUI

/// Capsule motion timings. `scale` stretches every duration uniformly; production uses 1, while
/// rendering tests slow motion down so intermediate frames can be sampled without depending on
/// wall-clock timing.
enum OverlayMotion {
    static let morphDuration: TimeInterval = 0.32
    static let appearanceDuration: TimeInterval = 0.20
    static let dismissalDuration: TimeInterval = 0.16

    static func morph(scale: Double = 1) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: morphDuration * scale)
    }

    static func appearance(scale: Double = 1) -> Animation {
        .easeOut(duration: appearanceDuration * scale)
    }

    static func dismissal(scale: Double = 1) -> Animation {
        .easeIn(duration: dismissalDuration * scale)
    }

    static func geometrySettleDelay(scale: Double = 1) -> TimeInterval {
        (morphDuration + 0.05) * scale
    }

    static func processingWidth(for title: String) -> CGFloat {
        min(188, max(118, CGFloat(title.count) * 8.5 + 52))
    }
}
