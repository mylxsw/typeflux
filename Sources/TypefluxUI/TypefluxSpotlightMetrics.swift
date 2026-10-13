import AppKit

/// Display input metrics for the custom Spotlight template in UI System C.
public enum TypefluxSpotlightMetrics {
    public static func inputFont(for style: InterfaceStyle) -> NSFont {
        NSFont.systemFont(ofSize: style == .classic ? 20 : 21, weight: .regular)
    }
}
