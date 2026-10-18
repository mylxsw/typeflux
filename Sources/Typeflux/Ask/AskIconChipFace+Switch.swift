import AppKit
import SwiftUI

/// Footer switches show their active state through the icon alone.
extension AskIconChipFace {
    static let wellInset: CGFloat = 3
    static let wellCorner: CGFloat = 9
    /// The filled brain has a wider, denser drawing than the other footer symbols.
    static let memorySymbolSize: CGFloat = 9.5

    /// Active icons stay borderless; warnings and inactive hover retain feedback.
    static func wellFill(_ style: AskChip.Style, hovering: Bool) -> Color {
        switch style {
        case .active: return .clear
        case .warning: return StudioTheme.warning.opacity(0.14)
        case .unavailable: return .clear
        case .neutral: return hovering ? AskTheme.hoverFill : .clear
        }
    }

    static func wellEdge(_ style: AskChip.Style) -> Color {
        .clear
    }

    /// An on switch uses the filled form of its symbol when there is one
    /// (`brain` → `brain.fill`), so the icon itself changes shape too.
    static func symbol(_ item: AskContextItem) -> String {
        guard item.style == .active else { return item.systemImage }
        let filled = item.systemImage + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) == nil ? item.systemImage : filled
    }
}
