import Foundation

extension SettingsStore {
    var askLauncherInputHistoryEnabled: Bool {
        get { defaults.object(forKey: "ask.launcher.inputHistory.enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "ask.launcher.inputHistory.enabled")
            NotificationCenter.default.post(name: .askLauncherInputHistoryDidChange, object: self)
        }
    }

    var askLauncherInputHistoryLimit: Int {
        get {
            let saved = defaults.integer(forKey: "ask.launcher.inputHistory.limit")
            return [50, 100, 200].contains(saved) ? saved : 100
        }
        set {
            defaults.set([50, 100, 200].contains(newValue) ? newValue : 100, forKey: "ask.launcher.inputHistory.limit")
            NotificationCenter.default.post(name: .askLauncherInputHistoryDidChange, object: self)
        }
    }

    func clearLauncherInputHistory() {
        defaults.removeObject(forKey: DefaultsAskLauncherInputHistoryStorage.key)
        NotificationCenter.default.post(name: .askLauncherInputHistoryDidChange, object: self)
    }
}
