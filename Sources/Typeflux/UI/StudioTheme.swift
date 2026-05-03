import AppKit
import SwiftUI

enum StudioTheme {
    enum Symbol {
        static let brand = "infinity.circle.fill"
    }

    enum Layout {
        static let shellInset: CGFloat = 6
        static let contentCardInset: CGFloat = 6
        static let shellContentTopInset: CGFloat = 24
        static let shellContentBottomInset: CGFloat = 24
        static let shellContentLeadingInset: CGFloat = 5
        static let shellCornerRadius: CGFloat = 12
        static let sidebarWidth: CGFloat = 196
        static let contentMaxWidth: CGFloat = 900
        static let contentInset: CGFloat = 24
        static let settingsWindowWidth: CGFloat = 1100
        static let settingsWindowHeight: CGFloat = 800
        static let settingsWindowMinWidth: CGFloat = 1080
        static let settingsWindowMinHeight: CGFloat = 620
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
        static let overviewSideMetricsWidth: CGFloat = 320
        static let overviewDonutSize: CGFloat = 148
        static let overviewActivityMinHeight: CGFloat = 178
        static let promoCardMinHeight: CGFloat = 154
        static let overviewPrimaryMinHeight: CGFloat = 286
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
        static let heroSection: CGFloat = 24
        static let pageGroup: CGFloat = 20
        static let cardGroup: CGFloat = 18
        static let cardCompact: CGFloat = 16
        static let contentCompact: CGFloat = 14
        static let contentTight: CGFloat = 12
        static let textStack: CGFloat = 10
        static let textCompact: CGFloat = 8
        static let textMicro: CGFloat = 6
        static let sidebarHeaderText: CGFloat = 2
    }

    enum CornerRadius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 12
        static let xLarge: CGFloat = 12
        static let xxLarge: CGFloat = 12
        static let hero: CGFloat = 12
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
        static let overviewDonut: CGFloat = 22
    }

    enum Shadow {
        static let cardRadius: CGFloat = 12
        static let cardY: CGFloat = 4
        static let floatingRadius: CGFloat = 16
        static let floatingY: CGFloat = 8
    }

    enum Typography {
        static let sidebarTitle: CGFloat = 13
        static let sidebarEyebrow: CGFloat = 9
        static let heroEyebrow: CGFloat = 10
        static let heroTitle: CGFloat = 24
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
        static let displayLarge: CGFloat = 28
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
        static let shellBorder: Double = 1
        static let cardBorder: Double = 1
        static let divider: Double = 0.72
        static let listDivider: Double = 0.78
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
        static let glassBackgroundTint: Double = 0.78
        static let glassSurfaceTint: Double = 0.92
        static let glassSurfaceScrim: Double = 0.88
        static let glassCardTint: Double = 0.78
        static let glassCardScrim: Double = 0.68
        static let glassControlTint: Double = 0.72
        static let glassControlScrim: Double = 0.66
        static let glassHighlight: Double = 1
    }

    enum Durations {
        static let overlayDismissDelay: TimeInterval = 0.4
    }

    enum Angles {
        static let overviewProgressStart: Double = -90
    }

    enum LineLimit {
        static let detail: Int = 2
        static let personaPrompt: Int = 1
    }

    enum Count {
        static let homeRecentRecords: Int = 10
        static let personaInitials: Int = 2
    }

    enum ControlSize {
        static let sidebarLogoSymbol: CGFloat = 22
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
        static let overviewMiniIcon: CGFloat = 30
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
        static let sidebarOuterHorizontal: CGFloat = 16
        static let sidebarOuterVertical: CGFloat = 14
        static let sidebarHeaderTop: CGFloat = 18
        static let sidebarItemHorizontal: CGFloat = 14
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
        static let historyRowVertical: CGFloat = 16
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

    static let sidebarSelection = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.42), dark: NSColor(calibratedWhite: 1.0, alpha: 0.11))
    static let accent = dynamic(light: NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.90, alpha: 1), dark: NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.00, alpha: 1))
    static let accentSoft = dynamic(light: NSColor(calibratedRed: 0.875, green: 0.925, blue: 1.0, alpha: 0.62), dark: NSColor(calibratedWhite: 0.175, alpha: 0.78))
    static let windowBackground = dynamic(light: NSColor(calibratedWhite: 0.945, alpha: 0.78), dark: NSColor(calibratedWhite: 0.058, alpha: 0.76))
    static let background = dynamic(light: NSColor(calibratedWhite: 0.945, alpha: 0.78), dark: NSColor(calibratedWhite: 0.058, alpha: 0.76))
    static let modalSurface = dynamic(light: NSColor(calibratedWhite: 0.900, alpha: 0.92), dark: NSColor(calibratedWhite: 0.086, alpha: 0.94))
    static let shellSurface = dynamic(light: NSColor(calibratedWhite: 0.805, alpha: 0.68), dark: NSColor(calibratedWhite: 0.118, alpha: 0.70))
    static let sidebar = windowBackground
    static let surface = dynamic(light: NSColor(calibratedWhite: 0.955, alpha: 0.82), dark: NSColor(calibratedWhite: 0.128, alpha: 0.62))
    static let cardSurface = dynamic(light: NSColor(calibratedWhite: 0.835, alpha: 0.62), dark: NSColor(calibratedWhite: 0.162, alpha: 0.50))
    static let surfaceMuted = dynamic(light: NSColor(calibratedWhite: 0.925, alpha: 0.66), dark: NSColor(calibratedWhite: 0.180, alpha: 0.52))
    static let controlSurface = dynamic(light: NSColor(calibratedWhite: 0.955, alpha: 0.70), dark: NSColor(calibratedWhite: 0.214, alpha: 0.58))
    static let rowSurface = dynamic(light: NSColor(calibratedWhite: 0.955, alpha: 0.78), dark: NSColor(calibratedWhite: 0.148, alpha: 0.72))
    static let selectionSurface = dynamic(light: NSColor(calibratedWhite: 0.895, alpha: 0.84), dark: NSColor(calibratedWhite: 0.212, alpha: 0.76))
    static let selectionSurfaceRaised = dynamic(light: NSColor(calibratedWhite: 0.955, alpha: 0.84), dark: NSColor(calibratedWhite: 0.310, alpha: 0.90))
    static let localModelOptionSurface = dynamic(light: NSColor(calibratedWhite: 0.940, alpha: 0.68), dark: NSColor(calibratedWhite: 0.198, alpha: 0.62))
    static let segmentedTrack = dynamic(light: NSColor(calibratedWhite: 0.845, alpha: 0.68), dark: NSColor(calibratedWhite: 1.0, alpha: 0.075))
    static let iconTileSurface = dynamic(light: NSColor(calibratedWhite: 0.955, alpha: 0.62), dark: NSColor(calibratedWhite: 0.245, alpha: 0.62))
    static let border = dynamic(light: NSColor(calibratedWhite: 0.30, alpha: 0.22), dark: NSColor(calibratedWhite: 1.0, alpha: 0.115))
    static let textPrimary = dynamic(light: NSColor(calibratedWhite: 0.08, alpha: 1), dark: NSColor(calibratedWhite: 0.935, alpha: 1))
    static let textSecondary = dynamic(light: NSColor(calibratedWhite: 0.28, alpha: 1), dark: NSColor(calibratedWhite: 0.720, alpha: 1))
    static let textTertiary = dynamic(light: NSColor(calibratedWhite: 0.40, alpha: 1), dark: NSColor(calibratedWhite: 0.560, alpha: 1))
    static let success = dynamic(light: NSColor(calibratedRed: 0.12, green: 0.67, blue: 0.39, alpha: 1), dark: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.43, alpha: 1))
    static let warning = dynamic(light: NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.16, alpha: 1), dark: NSColor(calibratedRed: 0.92, green: 0.50, blue: 0.24, alpha: 1))
    static let danger = dynamic(light: NSColor(calibratedRed: 0.85, green: 0.22, blue: 0.22, alpha: 1), dark: NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.32, alpha: 1))
    static let tooltipBackground = dynamic(light: NSColor(calibratedWhite: 0.12, alpha: 1), dark: NSColor(calibratedRed: 0.139, green: 0.143, blue: 0.147, alpha: 1))
    static let glassTint = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.58), dark: NSColor(calibratedWhite: 1.0, alpha: 0.075))
    static let glassScrim = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.66), dark: NSColor(calibratedWhite: 0.086, alpha: 0.62))
    static let glassStrokeHighlight = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.70), dark: NSColor(calibratedWhite: 1.0, alpha: 0.18))
    static let glassStrokeShadow = dynamic(light: NSColor(calibratedWhite: 0.0, alpha: 0.16), dark: NSColor(calibratedWhite: 0.0, alpha: 0.34))
    static let glassInnerHighlight = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.52), dark: NSColor(calibratedWhite: 1.0, alpha: 0.12))
    static let windowHighlight = dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 0.30), dark: NSColor(calibratedWhite: 1.0, alpha: 0.035))
    static let shadow = dynamic(light: NSColor(calibratedWhite: 0.0, alpha: 0.12), dark: NSColor(calibratedWhite: 0.0, alpha: 0.34))

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            },
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
