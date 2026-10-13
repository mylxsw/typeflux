import AppKit
import SwiftUI

/// How a footer switch shows its state: an on switch sits in a tinted well and
/// uses the filled form of its symbol, so "on" reads by shape as well as colour.
extension AskIconChipFace {
    static let wellInset: CGFloat = 3
    static let wellCorner: CGFloat = 9

    /// The well behind the icon: tinted when the switch is on, a warning wash
    /// when it failed, and the hover wash under an off icon.
    static func wellFill(_ style: AskContextItem.Style, hovering: Bool) -> Color {
        switch style {
        case .active: return LegacyAskPalette.switchOnFill
        case .warning: return TypefluxColor.warning.color.opacity(0.14)
        case .unavailable: return .clear
        case .neutral: return hovering ? TypefluxColor.label.color.opacity(0.06) : .clear
        }
    }

    static func wellEdge(_ style: AskContextItem.Style) -> Color {
        style == .active ? LegacyAskPalette.switchOnEdge : .clear
    }

    /// An on switch uses the filled form of its symbol when there is one
    /// (`brain` → `brain.fill`), so the icon itself changes shape too.
    static func symbol(_ item: AskContextItem) -> String {
        guard item.style == .active else { return item.systemImage }
        let filled = item.systemImage + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) == nil ? item.systemImage : filled
    }
}
