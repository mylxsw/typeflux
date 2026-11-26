import SwiftUI

struct AccountProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AccountTone.chip)
                Capsule().fill(color).frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

enum AccountTone {
    static let hoverFill = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.06),
        dark: NSColor(calibratedWhite: 1, alpha: 0.08)
    )

    static let separator = StudioTheme.dynamic(
        light: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )

    static let accentText = StudioTheme.dynamic(
        light: NSColor(srgbRed: 29 / 255, green: 78 / 255, blue: 216 / 255, alpha: 1),
        dark: NSColor(calibratedRed: 0.557, green: 0.741, blue: 1.0, alpha: 1)
    )

    /// A faint wash for the card's blocks, readable on glass in both appearances.
    static let chip = StudioTheme.dynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.045),
        dark: NSColor(calibratedWhite: 1, alpha: 0.07)
    )

    static func foreground(_ tone: AccountStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: StudioTheme.textSecondary
        case .accent: accentText
        case .warning: StudioTheme.warning
        case .danger: StudioTheme.danger
        }
    }

    static func fill(_ tone: AccountStatusPresentation.Tone) -> Color {
        switch tone {
        case .neutral: chip
        case .accent: StudioTheme.accent.opacity(0.18)
        case .warning: StudioTheme.warning.opacity(0.16)
        case .danger: StudioTheme.danger.opacity(0.16)
        }
    }

    static func bar(_ level: AccountStatusPresentation.QuotaLevel) -> Color {
        switch level {
        case .normal: StudioTheme.accent
        case .low: StudioTheme.warning
        case .exhausted: StudioTheme.danger
        }
    }
}
