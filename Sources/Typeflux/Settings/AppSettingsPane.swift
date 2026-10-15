import Foundation

/// App preferences remain under the existing Settings entry point.
enum AppSettingsPane: String, CaseIterable, SettingsPaneItem {
    case general
    case appearance
    case permissions
    case hotkeys
    case advanced

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: L("settings.general")
        case .hotkeys: L("studio.section.hotkeys")
        case .appearance: L("settings.pane.appearance")
        case .permissions: L("settings.permissions")
        case .advanced: L("settings.advanced.button")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hotkeys: "keyboard"
        case .appearance: "paintpalette"
        case .permissions: "lock.shield"
        case .advanced: "slider.horizontal.3"
        }
    }

    static var sections: [(title: String?, panes: [AppSettingsPane])] {
        [(title: nil, panes: allCases)]
    }
}
