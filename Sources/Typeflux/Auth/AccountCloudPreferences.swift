import Foundation

extension SettingsStore {
    /// A deliberate deferral is distinct from having seen the welcome window.
    var onboardingSpeechDeferred: Bool {
        get { defaults.bool(forKey: "onboarding.speechDeferred") }
        set { defaults.set(newValue, forKey: "onboarding.speechDeferred") }
    }

    var onboardingAIDeferred: Bool {
        get { defaults.bool(forKey: "onboarding.aiDeferred") }
        set { defaults.set(newValue, forKey: "onboarding.aiDeferred") }
    }

    var rewriteModelReference: String { defaults.string(forKey: "llm.profile.reference") ?? "" }
}
