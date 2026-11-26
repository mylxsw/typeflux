import Foundation

extension SettingsStore {
    var onboardingPermissionsDeferred: Bool {
        get { defaults.bool(forKey: "onboarding.permissionsDeferred") }
        set { defaults.set(newValue, forKey: "onboarding.permissionsDeferred") }
    }
}

/// Shared by onboarding and recording preflight; missing configuration is actionable.
enum FeatureSetupStatus {
    static func speechReason(settings: SettingsStore, loggedIn: Bool,
                             cloudAllowed: Bool, localAvailable: Bool,
                             googleAuthorized: Bool) -> String? {
        if settings.sttProvider == .typefluxOfficial {
            return cloudAllowed || localAvailable ? nil : L("setup.speech.cloudUnavailable")
        }
        return ModelAvailability.speechReason(settings.sttProvider, settings: settings,
                                              loggedIn: loggedIn, localModelAvailable: localAvailable,
                                              googleAuthorized: googleAuthorized)
    }
}
