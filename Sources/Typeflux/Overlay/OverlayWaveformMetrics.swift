import CoreGraphics

enum OverlayWaveformMetrics {
    static let barCount = 9

    static let maximumBarHeight: CGFloat = 24

    // Recorder levels map -60...0 dBFS to 0...1. Use -54...-18 dBFS
    // for the display so speech has room to move without amplifying the audio.
    private static let quietLevel: CGFloat = 0.1
    private static let fullHeightLevel: CGFloat = 0.7
    private static let responseCurveExponent: CGFloat = 0.8
    private static let baseBarHeight: CGFloat = 3
    private static let profile: [CGFloat] = [0.34, 0.52, 0.72, 0.9, 1.0, 0.86, 0.7, 0.5, 0.32]

    static func barHeight(for index: Int, level: Float) -> CGFloat {
        guard profile.indices.contains(index) else { return baseBarHeight }

        guard !level.isNaN else { return baseBarHeight }
        let speechLevel = (CGFloat(level) - quietLevel) / (fullHeightLevel - quietLevel)
        let responsiveLevel = pow(max(0, min(1, speechLevel)), responseCurveExponent)
        return baseBarHeight + ((maximumBarHeight - baseBarHeight) * responsiveLevel * profile[index])
    }
}
