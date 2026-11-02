import Foundation

extension StatusBarController {
    /// Opens the settings page a link in the usage guide points at.
    func showSettings(for destination: HelpSettingsDestination) {
        switch destination {
        case .shortcuts: showAppSettings(.hotkeys)
        case .keywords: showLauncherSettings(.keywords)
        case .workflows: showLauncherSettings(.workflows)
        case .vocabulary: showSettings(section: .vocabulary)
        case .models: showSettings(section: .models)
        }
    }
}
