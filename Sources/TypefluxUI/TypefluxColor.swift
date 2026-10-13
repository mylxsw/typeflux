import AppKit
import SwiftUI

/// Semantic roles follow the user's system appearance and accent preference.
public enum TypefluxColor: String, CaseIterable, Sendable {
    case label, secondaryLabel, tertiaryLabel, quaternaryLabel
    case windowBackground, contentBackground, controlBackground, separator
    case accent, selection, success, warning, danger
    case sidebarBackground

    public var nsColor: NSColor {
        switch self {
        case .label: .labelColor
        case .secondaryLabel: .secondaryLabelColor
        case .tertiaryLabel: .tertiaryLabelColor
        case .quaternaryLabel: .quaternaryLabelColor
        case .windowBackground: .windowBackgroundColor
        case .contentBackground: .textBackgroundColor
        case .controlBackground: .controlBackgroundColor
        case .separator: .separatorColor
        case .accent: .controlAccentColor
        case .selection: .selectedContentBackgroundColor
        case .success: .systemGreen
        case .warning: .systemOrange
        case .danger: .systemRed
        case .sidebarBackground: Self.sidebarColor
        }
    }

    /// A system label wash keeps sidebar backing distinct when Tahoe resolves both base surfaces alike.
    private static let sidebarColor = NSColor(name: nil) { appearance in
        var color = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = (NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .labelColor)
                ?? .windowBackgroundColor).withAlphaComponent(1)
        }
        return color
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }
}
