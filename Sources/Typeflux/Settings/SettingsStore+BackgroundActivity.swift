import Foundation

extension SettingsStore {
    /// Shows a dot beside the menu bar icon while background work runs.
    var backgroundActivityIndicatorEnabled: Bool {
        get { defaults.object(forKey: "backgroundActivity.indicator") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "backgroundActivity.indicator") }
    }

    /// Sends a system notification when a long model download finishes.
    var backgroundActivityNotificationsEnabled: Bool {
        get { defaults.object(forKey: "backgroundActivity.notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "backgroundActivity.notifications") }
    }
}
