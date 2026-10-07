import AppKit
import SwiftUI

/// How a footer switch shows its state: an on switch sits in a tinted well and
/// uses the filled form of its symbol, so "on" reads by shape as well as colour.
extension AskIconChipFace {
    static let wellInset: CGFloat = 3
    static let wellCorner: CGFloat = 9

    /// The well behind the icon: tinted when the switch is on, a warning wash
    /// when it failed, and the hover wash under an off icon.
    static func wellFill(_ style: AskChip.Style, hovering: Bool) -> Color {
        switch style {
        case .active: return AskTheme.switchOnFill
        case .warning: return StudioTheme.warning.opacity(0.14)
        case .unavailable: return .clear
        case .neutral: return hovering ? AskTheme.hoverFill : .clear
        }
    }

    static func wellEdge(_ style: AskChip.Style) -> Color {
        style == .active ? AskTheme.switchOnEdge : .clear
    }

    /// An on switch uses the filled form of its symbol when there is one
    /// (`brain` → `brain.fill`), so the icon itself changes shape too.
    static func symbol(_ item: AskContextItem) -> String {
        guard item.style == .active else { return item.systemImage }
        let filled = item.systemImage + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) == nil ? item.systemImage : filled
    }
}
