import Foundation

/// Reference metrics from UI System §4; native controls still size themselves.
public enum TypefluxRadius: String, CaseIterable, Sendable {
    case window
    case sidebar
    case sidebarRow
    case navigationIcon
    case toolbarItem
    case toolbarSearch
    case button
    case largeButton
    case popup
    case textField
    case segmented
    case checkbox
    case form
    case menu
    case menuHighlight
    case popover
    case sheet
    case spotlightInput
    case spotlightResults
    /// Custom composer menus have a 6pt inset around their choice rows.
    case menuCard
    case menuRow
    case hoverCard

    // Each exhaustive case is one row of the specification's metric table.
    // swiftlint:disable:next cyclomatic_complexity
    public func value(for style: InterfaceStyle) -> CGFloat {
        switch self {
        case .window: style == .classic ? 10 : 26
        case .sidebar: style == .classic ? 0 : 18
        case .sidebarRow: style == .classic ? 5 : 10
        case .navigationIcon: 6
        case .toolbarItem: style == .classic ? 0 : 18
        case .toolbarSearch: style == .classic ? 6 : 18
        case .button: style == .classic ? 5.5 : 8
        case .largeButton: style == .classic ? 7 : 17
        case .popup: style == .classic ? 5.5 : 8
        case .textField: style == .classic ? 5 : 8
        case .segmented: style == .classic ? 6 : 14
        case .checkbox: style == .classic ? 3.5 : 5
        case .form: style == .classic ? 8 : 14
        case .menu: style == .classic ? 6 : 14
        case .menuHighlight: style == .classic ? 4 : 8
        case .popover: style == .classic ? 10 : 18
        case .sheet: style == .classic ? 10 : 22
        case .spotlightInput: style == .classic ? 12 : 28
        case .spotlightResults: style == .classic ? 12 : 24
        case .menuCard: style == .classic ? 14 : 18
        case .menuRow: style == .classic ? 8 : 10
        case .hoverCard: style == .classic ? 10 : 14
        }
    }
}
