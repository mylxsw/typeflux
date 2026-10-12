import AppKit
import SwiftUI

/// Frozen compatibility values. New components use `TypefluxColor` instead.
public enum LegacyStudioPalette {
    /// An sRGB colour from a 24-bit hex value, for the light palette's exact swatches.
    public static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The selected sidebar row: a raised white block on the grey sidebar in light.
    public static let sidebarSelection = dynamic(
        light: rgb(0xFFFFFF),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.11)
    )
    /// Hairline around the raised selected row (light only; dark has no edge).
    public static let sidebarSelectionStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0)
    )
    /// Text and icon of the selected sidebar row.
    public static let accentText = dynamic(
        light: rgb(0x1D4ED8),
        dark: NSColor(calibratedWhite: 0.935, alpha: 1)
    )
    /// The sidebar panel's fill (light: #F3F4F6; dark: the existing glass graphite).
    public static let sidePanelFill = dynamic(
        light: rgb(0xF3F4F6),
        dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.204, alpha: 1)
    )
    /// The 0.5pt edge of the light glass sidebar panel.
    public static let sidePanelStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0)
    )
    /// White card on the white page, with a hairline border (light only).
    public static let cardFill = dynamic(
        light: rgb(0xFFFFFF),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    public static let cardStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.09),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.115)
    )
    /// The selected vocabulary filter chip: #F3F4F6 in light, the plain surface in dark.
    public static let filterChipSelectedFill = dynamic(
        light: rgb(0xF3F4F6),
        dark: NSColor(calibratedWhite: 0.128, alpha: 0.62)
    )
    public static let placeholder = dynamic(
        light: rgb(0xA1A1A6),
        dark: NSColor(calibratedWhite: 0.40, alpha: 1)
    )
    public static let accent = dynamic(
        light: rgb(0x2563EB),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 1)
    )
    public static let accentHover = dynamic(
        light: rgb(0x1D4ED8),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 1)
    )
    public static let accentSoft = dynamic(
        light: rgb(0x2563EB, alpha: 0.10),
        dark: NSColor(calibratedWhite: 0.175, alpha: 0.78)
    )
    public static let windowBackground = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 0.34),
        dark: NSColor(calibratedWhite: 0.058, alpha: 0.76)
    )
    public static let background = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 0.34),
        dark: NSColor(calibratedWhite: 0.058, alpha: 0.76)
    )
    public static let modalSurface = dynamic(
        light: NSColor(calibratedWhite: 0.94, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.086, alpha: 0.94)
    )
    public static let shellSurface = dynamic(
        light: NSColor(calibratedWhite: 0.99, alpha: 0.72),
        dark: NSColor(calibratedWhite: 0.118, alpha: 0.70)
    )
    public static let sidebar = windowBackground
    public static let surface = dynamic(
        light: NSColor(calibratedWhite: 0.995, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.128, alpha: 0.62)
    )
    public static let cardSurface = dynamic(
        light: NSColor(calibratedWhite: 0.985, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.162, alpha: 0.50)
    )
    public static let surfaceMuted = dynamic(
        light: NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.982, alpha: 0.84),
        dark: NSColor(calibratedWhite: 0.180, alpha: 0.52)
    )
    public static let controlSurface = dynamic(
        light: NSColor(calibratedWhite: 0.965, alpha: 0.90),
        dark: NSColor(calibratedWhite: 0.214, alpha: 0.58)
    )
    public static let rowSurface = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.92),
        dark: NSColor(calibratedWhite: 0.148, alpha: 0.72)
    )
    public static let selectionSurface = dynamic(
        light: NSColor(calibratedRed: 0.95, green: 0.965, blue: 0.988, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.212, alpha: 0.76)
    )
    public static let selectionSurfaceRaised = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.310, alpha: 0.90)
    )
    public static let localModelOptionSurface = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.86),
        dark: NSColor(calibratedWhite: 0.198, alpha: 0.62)
    )
    public static let segmentedTrack = dynamic(
        light: NSColor(calibratedWhite: 0.94, alpha: 0.84),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.075)
    )
    public static let iconTileSurface = dynamic(
        light: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1.0, alpha: 0.74),
        dark: NSColor(calibratedWhite: 0.245, alpha: 0.62)
    )
    public static let modelProviderIconPlate = Color.white
    public static let modelProviderFallbackSymbol = Color.black.opacity(0.72)
    public static let border = dynamic(
        light: rgb(0x0F172A, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.115)
    )
    public static let textPrimary = dynamic(
        light: rgb(0x1D1D1F),
        dark: NSColor(calibratedWhite: 0.935, alpha: 1)
    )
    public static let textSecondary = dynamic(
        light: rgb(0x515154),
        dark: NSColor(calibratedWhite: 0.720, alpha: 1)
    )
    public static let textTertiary = dynamic(
        light: rgb(0x6E6E73),
        dark: NSColor(calibratedWhite: 0.560, alpha: 1)
    )
    public static let success = dynamic(
        light: rgb(0x16A34A),
        dark: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.43, alpha: 1)
    )
    public static let warning = dynamic(
        light: rgb(0xD97706),
        dark: NSColor(calibratedRed: 0.92, green: 0.50, blue: 0.24, alpha: 1)
    )
    public static let danger = dynamic(
        light: rgb(0xDC2626),
        dark: NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.32, alpha: 1)
    )
    public static let tooltipBackground = dynamic(
        light: NSColor(calibratedWhite: 0.12, alpha: 1),
        dark: NSColor(calibratedRed: 0.139, green: 0.143, blue: 0.147, alpha: 1)
    )
    public static let glassTint = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.40),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.075)
    )
    public static let glassScrim = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.36),
        dark: NSColor(calibratedWhite: 0.086, alpha: 0.62)
    )
    public static let glassStrokeHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.86),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.18)
    )
    public static let glassStrokeShadow = dynamic(
        light: NSColor(calibratedRed: 0.50, green: 0.58, blue: 0.70, alpha: 0.10),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.34)
    )
    public static let glassInnerHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.62),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.12)
    )
    public static let windowHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.38),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.035)
    )
    public static let shadow = dynamic(
        light: NSColor(calibratedRed: 0.36, green: 0.43, blue: 0.56, alpha: 0.18),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.34)
    )

    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }
}
