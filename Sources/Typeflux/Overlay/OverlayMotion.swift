import SwiftUI

enum OverlayMotion {
    static let morphDuration: TimeInterval = 0.32
    static let geometrySettleDelay: TimeInterval = morphDuration + 0.05
    static let appearanceDuration: TimeInterval = 0.20
    static let dismissalDuration: TimeInterval = 0.16

    static let morph = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: morphDuration)
    static let appearance = Animation.easeOut(duration: appearanceDuration)
    static let dismissal = Animation.easeIn(duration: dismissalDuration)

    static func processingWidth(for title: String) -> CGFloat {
        min(188, max(118, CGFloat(title.count) * 8.5 + 52))
    }
}
