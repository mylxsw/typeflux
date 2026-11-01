import Foundation

/// Feature permission metadata retained for setup and recovery.
enum OnboardingFeature: String, CaseIterable, Identifiable, Sendable {
    case voice
    case launcher
    case tools
    case ring
    case chat

    var id: String { rawValue }
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

    /// Permissions setup asks for, in the order the permission list shows them. Voice input also
    /// needs speech recognition when it falls back to Apple Speech.
    @MainActor
    static func requiredPermissionIDs(settingsStore: SettingsStore) -> [PrivacyGuard.PermissionID] {
        var required = allCases.reduce(into: Set<PrivacyGuard.PermissionID>()) { $0.formUnion($1.requiredPermissions) }
        if PrivacyGuard.requiredPermissionIDs(settingsStore: settingsStore).contains(.speechRecognition) {
            required.insert(.speechRecognition)
        }
        return PrivacyGuard.PermissionID.allCases.filter(required.contains)
    }

}
