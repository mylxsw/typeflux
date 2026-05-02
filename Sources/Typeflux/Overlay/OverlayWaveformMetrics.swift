import CoreGraphics

enum OverlayWaveformMetrics {
    static let barCount = 9

    private static let minimumResponsiveLevel: CGFloat = 0.06
    private static let responseCurveExponent: CGFloat = 0.58
    private static let baseBarHeight: CGFloat = 3.8
    private static let dynamicBarHeight: CGFloat = 11.2
    private static let profile: [CGFloat] = [0.34, 0.52, 0.72, 0.9, 1.0, 0.86, 0.7, 0.5, 0.32]

    static func barHeight(for index: Int, level: Float) -> CGFloat {
        guard profile.indices.contains(index) else { return baseBarHeight }

        let clampedLevel = max(0, min(1.0, CGFloat(level)))
        let responsiveLevel = max(minimumResponsiveLevel, pow(clampedLevel, responseCurveExponent))
        return baseBarHeight + (dynamicBarHeight * responsiveLevel * profile[index])
    }
}
