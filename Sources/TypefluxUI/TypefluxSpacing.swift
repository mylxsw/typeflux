import Foundation

/// Reference metrics from UI System §4; native controls still size themselves.
public enum TypefluxSpacing: String, CaseIterable, Sendable {
    case sidebarInset
    case sidebarRowInset
    case compact, small, regular, large, section

    public func value(for style: InterfaceStyle) -> CGFloat {
        switch self {
        case .sidebarInset: style == .classic ? 0 : 8
        case .sidebarRowInset: style == .classic ? 8 : 8
        case .compact: 4
        case .small: 8
        case .regular: 12
        case .large: 16
        case .section: 24
        }
    }
}
