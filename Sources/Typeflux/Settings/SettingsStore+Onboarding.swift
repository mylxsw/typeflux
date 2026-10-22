import Foundation

/// What the user picked during first-run setup, kept for the later lessons.
extension SettingsStore {
    private static let onboardingGoalsKey = "onboarding.goals"

    /// Nil until setup has been finished or closed once.
    var onboardingGoals: Set<OnboardingGoal>? {
        get {
            guard let raw = defaults.array(forKey: Self.onboardingGoalsKey) as? [String] else { return nil }
            return Set(raw.compactMap(OnboardingGoal.init(rawValue:)))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.onboardingGoalsKey)
                return
            }
            defaults.set(OnboardingGoal.ordered(newValue).map(\.rawValue), forKey: Self.onboardingGoalsKey)
        }
    }
}
