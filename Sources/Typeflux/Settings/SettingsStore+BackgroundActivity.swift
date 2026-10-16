import Foundation

extension SettingsStore {
    /// Sends a system notification when a long model download finishes.
    var backgroundActivityNotificationsEnabled: Bool {
        get { defaults.object(forKey: "backgroundActivity.notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "backgroundActivity.notifications") }
    }
}
