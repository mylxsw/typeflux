import Foundation

struct LLMConfigurationReminderPolicy {
    enum Presentation: Equatable {
        case actionDialog
        case suppressed
    }

    static let typefluxCloudLoginReminderInterval: TimeInterval = 6 * 60 * 60

    let settingsStore: SettingsStore
    var now: () -> Date = Date.init

    func presentation(for status: LLMConfigurationStatus) -> Presentation {
        guard case .notConfigured(.cloudNotLoggedIn) = status else {
            return .actionDialog
        }

        let currentTime = now()
        guard let lastShownAt = settingsStore.lastTypefluxCloudLoginReminderAt else {
            settingsStore.lastTypefluxCloudLoginReminderAt = currentTime
            return .actionDialog
        }

        if currentTime.timeIntervalSince(lastShownAt) >= Self.typefluxCloudLoginReminderInterval {
            settingsStore.lastTypefluxCloudLoginReminderAt = currentTime
            return .actionDialog
        }

        return .suppressed
    }
}
