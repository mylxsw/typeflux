import AppKit
import SwiftUI

enum StudioTheme {
    enum Symbol {
        static let brand = "infinity.circle.fill"
    }

    enum Layout {
        static let shellInset: CGFloat = 0
        static let contentCardInset: CGFloat = 0
        static let shellContentTopInset: CGFloat = 28
        static let shellContentBottomInset: CGFloat = 32
        static let shellContentLeadingInset: CGFloat = 0
        static let shellCornerRadius: CGFloat = 0
        static let sidebarWidth: CGFloat = AskMetrics.sidebarWidth
        static let contentMaxWidth: CGFloat = 1160
        static let contentInset: CGFloat = 24
        static let settingsWindowWidth: CGFloat = 1100
        static let settingsWindowHeight: CGFloat = 800
        static let settingsWindowMinWidth: CGFloat = 720
        static let settingsWindowMinHeight: CGFloat = 500
        static let overlayWidth: CGFloat = 320
        static let overlayHeight: CGFloat = 92
        static let historyWindowWidth: CGFloat = 680
        static let historyWindowHeight: CGFloat = 520
        static let overlayBottomOffset: CGFloat = 80
        static let floatingActionButtonSize: CGFloat = 54
        static let iconBadgeSize: CGFloat = 52
        static let compactIconBadgeSize: CGFloat = 34
        static let metricMinHeight: CGFloat = 184
        static let compactMetricMinHeight: CGFloat = 132
        static let actionCardMinHeight: CGFloat = 210
        static let modelCardMinHeight: CGFloat = 240
        static let textEditorMinHeight: CGFloat = 360
        static let heroMaxWidth: CGFloat = 680
        static let modelsArchitectureCardWidth: CGFloat = 320
        static let personasListWidth: CGFloat = 240
        static let debugActionsCardWidth: CGFloat = 320
        static let appearancePickerWidth: CGFloat = 280
        static let overviewMetricHeight: CGFloat = 150
        static let promoCardMinHeight: CGFloat = 154
        static let historyTimestampColumnWidth: CGFloat = 170
        static let historySourceColumnWidth: CGFloat = 280
        static let modelTabsMinHeight: CGFloat = 44
        static let modelProviderListWidth: CGFloat = 264
    }

    enum Spacing {
        static let none: CGFloat = 0
        static let xxxSmall: CGFloat = 4
        static let xxSmall: CGFloat = 6
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 10
        static let smallMedium: CGFloat = 12
        static let medium: CGFloat = 14
        static let mediumLarge: CGFloat = 16
        static let large: CGFloat = 18
        static let xLarge: CGFloat = 20
        static let xxLarge: CGFloat = 22
        static let xxxLarge: CGFloat = 24
        static let section: CGFloat = 24
        static let heroSection: CGFloat = 30
        static let pageGroup: CGFloat = 24
        static let cardGroup: CGFloat = 20
        static let cardCompact: CGFloat = 16
        static let contentCompact: CGFloat = 14
        static let contentTight: CGFloat = 12
        static let textStack: CGFloat = 10
        static let textCompact: CGFloat = 8
        static let textMicro: CGFloat = 6
        static let sidebarHeaderText: CGFloat = 2
    }

    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 10
        static let large: CGFloat = 12
        static let xLarge: CGFloat = 16
        static let xxLarge: CGFloat = 18
        static let hero: CGFloat = 14
        static let capsule: CGFloat = 999
        static let overlay: CGFloat = 12
        static let historyBadge: CGFloat = 8
        static let meter: CGFloat = 6
        static let miniMetricIcon: CGFloat = 10
        static let promoIllustration: CGFloat = 12
        static let architectureOption: CGFloat = 12
        static let segmentedControl: CGFloat = 12
        static let segmentedItem: CGFloat = 12
        static let tooltip: CGFloat = 10
    }

    enum BorderWidth {
        static let thin: CGFloat = 1
        static let emphasis: CGFloat = 1.5
        static let overviewDonut: CGFloat = 24
    }

    enum Shadow {
        static let cardRadius: CGFloat = 18
        static let cardY: CGFloat = 8
        static let floatingRadius: CGFloat = 16
        static let floatingY: CGFloat = 8
    }

    enum Typography {
        static let sidebarTitle: CGFloat = 13
        static let sidebarEyebrow: CGFloat = 9
        static let heroEyebrow: CGFloat = 10
        static let heroTitle: CGFloat = 26
        static let heroMetric: CGFloat = 26
        static let pageTitle: CGFloat = 22
        static let sectionTitle: CGFloat = 18
        static let subsectionTitle: CGFloat = 16
        static let cardTitle: CGFloat = 15
        static let settingTitle: CGFloat = 15
        static let bodyLarge: CGFloat = 14
        static let body: CGFloat = 13
        static let bodySmall: CGFloat = 12
        static let caption: CGFloat = 11
        static let eyebrow: CGFloat = 10
        static let displayLarge: CGFloat = 32
        static let iconLarge: CGFloat = 24
        static let iconMediumLarge: CGFloat = 20
        static let iconMedium: CGFloat = 16
        static let iconRegular: CGFloat = 14
        static let iconSmall: CGFloat = 13
        static let iconXSmall: CGFloat = 11
        static let iconTiny: CGFloat = 10
        static let tooltip: CGFloat = 12
    }

    enum Opacity {
        static let shellBorder: Double = 0.85
        static let cardBorder: Double = 0.72
        static let divider: Double = 0.55
        static let listDivider: Double = 0.62
        static let sidebarSelectionFill: Double = 1
        static let textFieldFill: Double = 1
        static let overviewPanelFill: Double = 1
        static let overviewActivityFill: Double = 1
        static let overviewProgress: Double = 0.85
        static let promoIconFill: Double = 0.8
        static let modelCardMuted: Double = 0.56
        static let overlayStroke: Double = 0.12
        static let overlayTrack: Double = 0.12
        static let overlayLevel: Double = 0.7
        static let historyAccent: Double = 0.12
        static let historyAccentStrong: Double = 0.82
        static let segmentedControlFill: Double = 1
        static let pressedFade: Double = 0.86
        static let glassBackgroundTint: Double = 0.72
        static let glassSurfaceTint: Double = 0.96
        static let glassSurfaceScrim: Double = 0.96
        static let glassCardTint: Double = 0.94
        static let glassCardScrim: Double = 0.92
        static let glassControlTint: Double = 0.28
        static let glassControlScrim: Double = 0.56
        static let glassHighlight: Double = 1
        /// The light Liquid Glass sidebar panel's fill (#F3F4F6 at ~94%).
        static let sidePanelFill: Double = 0.94
    }

    enum Durations {
        static let overlayDismissDelay: TimeInterval = 0.4
    }

    enum LineLimit {
        static let detail: Int = 2
        static let personaPrompt: Int = 1
    }

    enum Count {
        static let personaInitials: Int = 2
    }

    enum ControlSize {
        static let sidebarLogoSymbol: CGFloat = 20
        static let sidebarNavigationIcon: CGFloat = 16
        static let sidebarNavigationSymbol: CGFloat = 15
        static let buttonMinWidth: CGFloat = 84
        static let buttonHeight: CGFloat = 34
        static let sidebarUtilityButton: CGFloat = 28
        static let personaAddButton: CGFloat = 36
        static let personaAvatar: CGFloat = 36
        static let personaStatusDot: CGFloat = 10
        static let appearanceBadge: CGFloat = 48
        static let hotkeyBadge: CGFloat = 48
        static let overviewMiniIcon: CGFloat = 34
        static let overviewMiniSymbol: CGFloat = 12
        static let overviewBadge: CGFloat = 34
        static let overviewBadgeSymbol: CGFloat = 14
        static let promoIllustration: CGFloat = 92
        static let architectureBadge: CGFloat = 52
        static let modelProviderBadge: CGFloat = 36
        static let modelProviderBadgeSymbol: CGFloat = 13
        static let modelProviderStatusDot: CGFloat = 8
        static let selectionIndicator: CGFloat = 22
        static let selectionIndicatorInner: CGFloat = 10
        static let historyBadge: CGFloat = 26
        static let overlayLevelWidth: CGFloat = 56
        static let overlayLevelHeight: CGFloat = 12
    }

    enum Insets {
        static let none: CGFloat = 0
        static let sidebarOuterHorizontal: CGFloat = 24
        static let sidebarOuterVertical: CGFloat = 28
        static let sidebarHeaderTop: CGFloat = 26
        static let sidebarItemHorizontal: CGFloat = 16
        static let sidebarItemVertical: CGFloat = 12

        static let toastHorizontal: CGFloat = 18
        static let toastVertical: CGFloat = 12
        static let toastBottom: CGFloat = 18

        static let buttonHorizontal: CGFloat = 16
        static let buttonVertical: CGFloat = 10
        static let pillHorizontal: CGFloat = 12
        static let pillVertical: CGFloat = 7
        static let segmentedControlHorizontal: CGFloat = 6
        static let segmentedControlVertical: CGFloat = 6
        static let segmentedItemHorizontal: CGFloat = 18
        static let segmentedItemVertical: CGFloat = 8

        static let cardDefault: CGFloat = 24
        static let cardCompact: CGFloat = 16
        static let cardDense: CGFloat = 18
        static let personaRow: CGFloat = 10
        static let textEditor: CGFloat = 16
        static let textFieldHorizontal: CGFloat = 16
        static let textFieldVertical: CGFloat = 12
        static let historyRowHorizontal: CGFloat = 20
        static let historyRowVertical: CGFloat = 15
        static let historyHeaderHorizontal: CGFloat = 18
        static let historyHeaderTop: CGFloat = 18
        static let historyHeaderBottom: CGFloat = 10
        static let historyEmptyVertical: CGFloat = 44
        static let sessionEmptyVertical: CGFloat = 40
        static let promoCard: CGFloat = 22
        static let overlay: CGFloat = 14
        static let errorEmptyVertical: CGFloat = 18
        static let windowContent: CGFloat = 12
        static let tooltipHorizontal: CGFloat = 12
        static let tooltipVertical: CGFloat = 8
    }

    enum Colors {
        static let promoWorkflowStart = Color(red: 0.86, green: 0.97, blue: 0.99)
        static let promoWorkflowEnd = Color(red: 0.78, green: 0.90, blue: 1.00)
        static let promoSetupStart = Color(red: 0.99, green: 0.93, blue: 0.89)
        static let promoSetupEnd = Color(red: 0.99, green: 0.92, blue: 0.95)
        static let actionCardWarm = Color(red: 0.98, green: 0.93, blue: 0.90)
        static let actionCardCool = Color(red: 0.93, green: 0.97, blue: 0.98)
        static let historyPurple = Color.purple
        static let historyGreen = Color.green
        static let historyOrange = Color.orange
        static let overlayLevel = Color.green
        static let white = Color.white
    }

    static let sidebarWidth = Layout.sidebarWidth
    static let contentMaxWidth = Layout.contentMaxWidth
    static let contentInset = Layout.contentInset

    /// An sRGB colour from a 24-bit hex value, for the light palette's exact swatches.
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The selected sidebar row: a raised white block on the grey sidebar in light.
    static let sidebarSelection = dynamic(
        light: rgb(0xFFFFFF),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.11)
    )
    /// Hairline around the raised selected row (light only; dark has no edge).
    static let sidebarSelectionStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0)
    )
    /// Text and icon of the selected sidebar row.
    static let accentText = dynamic(
        light: rgb(0x1D4ED8),
        dark: NSColor(calibratedWhite: 0.935, alpha: 1)
    )
    /// The sidebar panel's fill (light: #F3F4F6; dark: the existing glass graphite).
    static let sidePanelFill = dynamic(
        light: rgb(0xF3F4F6),
        dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.204, alpha: 1)
    )
    /// The 0.5pt edge of the light glass sidebar panel.
    static let sidePanelStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0)
    )
    /// White card on the white page, with a hairline border (light only).
    static let cardFill = dynamic(
        light: rgb(0xFFFFFF),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )
    static let cardStroke = dynamic(
        light: rgb(0x0F172A, alpha: 0.09),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.115)
    )
    /// The selected vocabulary filter chip: #F3F4F6 in light, the plain surface in dark.
    static let filterChipSelectedFill = dynamic(
        light: rgb(0xF3F4F6),
        dark: NSColor(calibratedWhite: 0.128, alpha: 0.62)
    )
    static let placeholder = dynamic(
        light: rgb(0xA1A1A6),
        dark: NSColor(calibratedWhite: 0.40, alpha: 1)
    )
    static let accent = dynamic(
        light: rgb(0x2563EB),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 1)
    )
    static let accentHover = dynamic(
        light: rgb(0x1D4ED8),
        dark: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1.00, alpha: 1)
    )
    static let accentSoft = dynamic(
        light: rgb(0x2563EB, alpha: 0.10),
        dark: NSColor(calibratedWhite: 0.175, alpha: 0.78)
    )
    static let windowBackground = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 0.34),
        dark: NSColor(calibratedWhite: 0.058, alpha: 0.76)
    )
    static let background = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 0.34),
        dark: NSColor(calibratedWhite: 0.058, alpha: 0.76)
    )
    static let modalSurface = dynamic(
        light: NSColor(calibratedWhite: 0.94, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.086, alpha: 0.94)
    )
    static let shellSurface = dynamic(
        light: NSColor(calibratedWhite: 0.99, alpha: 0.72),
        dark: NSColor(calibratedWhite: 0.118, alpha: 0.70)
    )
    static let sidebar = windowBackground
    static let surface = dynamic(
        light: NSColor(calibratedWhite: 0.995, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.128, alpha: 0.62)
    )
    static let cardSurface = dynamic(
        light: NSColor(calibratedWhite: 0.985, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.162, alpha: 0.50)
    )
    static let surfaceMuted = dynamic(
        light: NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.982, alpha: 0.84),
        dark: NSColor(calibratedWhite: 0.180, alpha: 0.52)
    )
    static let controlSurface = dynamic(
        light: NSColor(calibratedWhite: 0.965, alpha: 0.90),
        dark: NSColor(calibratedWhite: 0.214, alpha: 0.58)
    )
    static let rowSurface = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.92),
        dark: NSColor(calibratedWhite: 0.148, alpha: 0.72)
    )
    static let selectionSurface = dynamic(
        light: NSColor(calibratedRed: 0.95, green: 0.965, blue: 0.988, alpha: 0.94),
        dark: NSColor(calibratedWhite: 0.212, alpha: 0.76)
    )
    static let selectionSurfaceRaised = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.96),
        dark: NSColor(calibratedWhite: 0.310, alpha: 0.90)
    )
    static let localModelOptionSurface = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.86),
        dark: NSColor(calibratedWhite: 0.198, alpha: 0.62)
    )
    static let segmentedTrack = dynamic(
        light: NSColor(calibratedWhite: 0.94, alpha: 0.84),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.075)
    )
    static let iconTileSurface = dynamic(
        light: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1.0, alpha: 0.74),
        dark: NSColor(calibratedWhite: 0.245, alpha: 0.62)
    )
    static let modelProviderIconPlate = Color.white
    static let modelProviderFallbackSymbol = Color.black.opacity(0.72)
    static let border = dynamic(
        light: rgb(0x0F172A, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.115)
    )
    static let textPrimary = dynamic(
        light: rgb(0x1D1D1F),
        dark: NSColor(calibratedWhite: 0.935, alpha: 1)
    )
    static let textSecondary = dynamic(
        light: rgb(0x515154),
        dark: NSColor(calibratedWhite: 0.720, alpha: 1)
    )
    static let textTertiary = dynamic(
        light: rgb(0x6E6E73),
        dark: NSColor(calibratedWhite: 0.560, alpha: 1)
    )
    static let success = dynamic(
        light: rgb(0x16A34A),
        dark: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.43, alpha: 1)
    )
    static let warning = dynamic(
        light: rgb(0xD97706),
        dark: NSColor(calibratedRed: 0.92, green: 0.50, blue: 0.24, alpha: 1)
    )
    static let danger = dynamic(
        light: rgb(0xDC2626),
        dark: NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.32, alpha: 1)
    )
    static let tooltipBackground = dynamic(
        light: NSColor(calibratedWhite: 0.12, alpha: 1),
        dark: NSColor(calibratedRed: 0.139, green: 0.143, blue: 0.147, alpha: 1)
    )
    static let glassTint = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.40),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.075)
    )
    static let glassScrim = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.36),
        dark: NSColor(calibratedWhite: 0.086, alpha: 0.62)
    )
    static let glassStrokeHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.86),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.18)
    )
    static let glassStrokeShadow = dynamic(
        light: NSColor(calibratedRed: 0.50, green: 0.58, blue: 0.70, alpha: 0.10),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.34)
    )
    static let glassInnerHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.62),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.12)
    )
    static let windowHighlight = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.38),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.035)
    )
    static let shadow = dynamic(
        light: NSColor(calibratedRed: 0.36, green: 0.43, blue: 0.56, alpha: 0.18),
        dark: NSColor(calibratedWhite: 0.0, alpha: 0.34)
    )

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }
}

extension Font {
    static func studioDisplay(_ size: CGFloat, weight: Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }

    static func studioBody(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func studioMono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
