import Foundation

public enum TypefluxSpotlightMetrics {
    public static func resultsSpacing(for style: InterfaceStyle) -> CGFloat {
        style == .classic ? 0 : 12
    }
}
