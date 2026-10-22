import Foundation

/// What a new user says they want to use Typeflux for. The choice decides which permissions
/// first-run setup asks for and the order of the later lessons; unpicked features stay available.
enum OnboardingGoal: String, CaseIterable, Codable, Identifiable, Sendable {
    case voice
    case launcher
    case tools
    case ring
    case chat

    /// Voice input, the launcher and chat cover most first sessions.
    static let defaultSelection: Set<OnboardingGoal> = [.voice, .launcher, .chat]

    var id: String { rawValue }
    var title: String { L("onboarding.goal.\(rawValue).title") }
    var detail: String { L("onboarding.goal.\(rawValue).detail") }

    var symbol: String {
        switch self {
        case .voice: "mic"
        case .launcher: "magnifyingglass"
        case .tools: "square.grid.2x2"
        case .ring: "circle.circle"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    /// Rough length of this feature's lessons, shown in the plan.
    var estimatedMinutes: Int {
        switch self {
        case .voice, .ring: 1
        case .launcher, .tools, .chat: 2
        }
    }

    /// Permissions the feature needs before it can be used at all. Screen recording, camera and
    /// AI are asked for the first time a feature needs them, never during setup.
    var requiredPermissions: Set<PrivacyGuard.PermissionID> {
        switch self {
        case .voice: [.microphone, .accessibility]
        case .launcher, .ring: [.accessibility]
        case .chat: [.microphone]
        case .tools: []
        }
    }

    /// The goals in display order.
    static func ordered(_ goals: Set<OnboardingGoal>) -> [OnboardingGoal] {
        allCases.filter(goals.contains)
    }

    /// Permissions setup asks for, in the order the permission list shows them. Voice input also
    /// needs speech recognition when it falls back to Apple Speech.
    @MainActor
    static func requiredPermissionIDs(
        for goals: Set<OnboardingGoal>,
        settingsStore: SettingsStore
    ) -> [PrivacyGuard.PermissionID] {
        var required = goals.reduce(into: Set<PrivacyGuard.PermissionID>()) { $0.formUnion($1.requiredPermissions) }
        if goals.contains(.voice),
           PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore).contains(.speechRecognition) {
            required.insert(.speechRecognition)
        }
        return PrivacyGuard.PermissionID.allCases.filter(required.contains)
    }
}
