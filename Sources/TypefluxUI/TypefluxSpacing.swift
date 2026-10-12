import Foundation

/// Reference metrics from UI System §4; native controls still size themselves.
public enum TypefluxSpacing: String, CaseIterable, Sendable {
    case sidebarInset
    case sidebarRowInset

    public func value(for style: InterfaceStyle) -> CGFloat {
        switch self {
        case .sidebarInset: style == .classic ? 0 : 8
        case .sidebarRowInset: style == .classic ? 8 : 8
        }
    }
}
