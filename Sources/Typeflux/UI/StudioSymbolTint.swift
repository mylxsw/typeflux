import SwiftUI

extension StudioTheme {
    /// AI feature glyphs use gold; controls and text keep their interaction colors.
    static let aiIcon = dynamic(light: rgb(0xA66C00), dark: rgb(0xF2C14E))

    /// An sRGB colour from a 24-bit hex value, for the light palette's exact swatches.
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Apply directly to the glyph, before inherited foreground and button styles.
extension View {
    @ViewBuilder
    func aiSymbolTint(_ symbol: String) -> some View {
        if symbol == "sparkles" || symbol == "sparkle" {
            foregroundStyle(StudioTheme.aiIcon)
        } else {
            self
        }
    }
}
