import Foundation

/// Reference metrics from UI System §4; native controls still size themselves.
public enum TypefluxControlHeight: String, CaseIterable, Sendable {
    case toolbar
    case sidebarRow
    case toolbarItem
    case toolbarSearch
    case button
    case largeButton
    case popup
    case textField
    case segmented
    case switchControl
    case checkbox
    case formRow
    case tableRow
    case menuItem
    case spotlightInput
    case spotlightModeButton

    // Each exhaustive case is one row of the specification's metric table.
    // swiftlint:disable:next cyclomatic_complexity
    public func value(for style: InterfaceStyle) -> CGFloat {
        switch self {
        case .toolbar: style == .classic ? 52 : 52
        case .sidebarRow: style == .classic ? 28 : 32
        case .toolbarItem: style == .classic ? 24 : 36
        case .toolbarSearch: style == .classic ? 24 : 36
        case .button: style == .classic ? 22 : 26
        case .largeButton: style == .classic ? 28 : 34
        case .popup: style == .classic ? 22 : 26
        case .textField: style == .classic ? 22 : 26
        case .segmented: style == .classic ? 22 : 28
        case .switchControl: style == .classic ? 18 : 22
        case .checkbox: style == .classic ? 14 : 16
        case .formRow: style == .classic ? 36 : 40
        case .tableRow: style == .classic ? 24 : 28
        case .menuItem: style == .classic ? 22 : 24
        case .spotlightInput: style == .classic ? 52 : 56
        case .spotlightModeButton: style == .classic ? 52 : 56
        }
    }
}
