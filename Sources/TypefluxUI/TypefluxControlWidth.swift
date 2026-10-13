import Foundation

/// Reference metrics from UI System §4; native controls still size themselves.
public enum TypefluxControlWidth: String, CaseIterable, Sendable {
    case toolbarItem
    case toolbarSearch
    case switchControl
    case checkbox
    case spotlightPanel

    public func value(for style: InterfaceStyle) -> CGFloat {
        switch self {
        case .toolbarItem: style == .classic ? 28 : 36
        case .toolbarSearch: style == .classic ? 200 : 240
        case .switchControl: style == .classic ? 32 : 38
        case .checkbox: style == .classic ? 14 : 16
        case .spotlightPanel: style == .classic ? 640 : 680
        }
    }
}
