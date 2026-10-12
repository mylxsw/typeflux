import Foundation

/// App preferences remain under the existing Settings entry point.
enum AppSettingsPane: String, CaseIterable, SettingsPaneItem {
    case general
    case appearance

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: L("settings.general")
        case .appearance: L("settings.pane.appearance")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        }
    }

    static var sections: [(title: String?, panes: [AppSettingsPane])] {
        [(title: nil, panes: allCases)]
    }
}
