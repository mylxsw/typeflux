import AppKit
import SwiftUI

/// Semantic roles follow the user's system appearance and accent preference.
public enum TypefluxColor: String, CaseIterable, Sendable {
    case label, secondaryLabel, tertiaryLabel, quaternaryLabel
    case windowBackground, contentBackground, controlBackground, separator
    case accent, selection, success, warning, danger

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
        }
    }

    public var color: Color {
        Color(nsColor: nsColor)
    }
}
