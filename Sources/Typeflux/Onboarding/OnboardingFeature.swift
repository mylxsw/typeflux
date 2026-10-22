import Foundation

/// The features first-run setup walks every new user through, in order. Each gets one short
/// guide screen; the permissions they need are asked for once, up front.
enum OnboardingFeature: String, CaseIterable, Identifiable, Sendable {
    case voice
    case launcher
    case tools
    case ring
    case chat

    var id: String { rawValue }
    var title: String { L("onboarding.feature.\(rawValue).title") }
    /// One line under the title of the feature's guide screen.
    var caption: String { L("onboarding.feature.\(rawValue).caption") }

    var symbol: String {
        switch self {
        case .voice: "mic"
        case .launcher: "magnifyingglass"
        case .tools: "square.grid.2x2"
        case .ring: "circle.circle"
        case .chat: "bubble.left.and.bubble.right"
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

    /// The features that need a permission, for the chips under it.
    static func features(using permission: PrivacyGuard.PermissionID) -> [OnboardingFeature] {
        allCases.filter { $0.requiredPermissions.contains(permission) || (permission == .speechRecognition && $0 == .voice) }
    }

    /// The keys the guide teaches, read from the user's current shortcuts so a changed key shows
    /// everywhere. Features reached through another one (translate via the launcher) say so.
    @MainActor
    func shortcuts(settingsStore: SettingsStore) -> [OnboardingShortcut] {
        let keys = { (binding: HotkeyBinding?) in binding.map(HotkeyFormat.components) ?? [] }
        let voice = keys(settingsStore.activationHotkey ?? .defaultActivation)
        let launcher = keys(settingsStore.hotkey(.ask))
        let screenshot = keys(settingsStore.hotkey(.screenshot))
        let actions = settingsStore.actionHotkeys
        switch self {
        case .voice:
            return [
                .init(id: "voice.talk", keys: voice, title: L("onboarding.tip.voice.talk")),
                .init(id: "voice.rewrite", keys: voice, title: L("onboarding.tip.voice.rewrite"))
            ]
        case .launcher:
            return [
                .init(id: "launcher.open", keys: launcher, title: L("onboarding.tip.launcher.open")),
                .init(id: "launcher.clipboard", keys: keys(settingsStore.hotkey(.history)),
                      title: L("onboarding.tip.launcher.clipboard")),
                .init(id: "launcher.screenshot", keys: screenshot, title: L("onboarding.tip.launcher.screenshot"))
            ]
        case .tools:
            let translate = actions[.translate].map(HotkeyFormat.components) ?? Self.through(launcher, "fy")
            return [
                .init(id: "tools.translate", keys: translate, title: L("onboarding.tip.tools.translate")),
                .init(id: "tools.record", keys: Self.through(screenshot, "⏺"), title: L("onboarding.tip.tools.record")),
                .init(id: "tools.workflow", keys: launcher, title: L("onboarding.tip.tools.workflow"))
            ]
        case .ring:
            return [.init(id: "ring.swipe", keys: keys(actions[.ring]), title: L("onboarding.tip.ring.swipe"))]
        case .chat:
            var result = [OnboardingShortcut(id: "chat.ask", keys: Self.through(launcher, "↩"),
                                             title: L("onboarding.tip.chat.ask"))]
            if let window = actions[.openChat] {
                result.append(.init(id: "chat.window", keys: HotkeyFormat.components(window),
                                    title: L("onboarding.tip.chat.window")))
            }
            return result
        }
    }

    /// Keys for a step reached through another shortcut; nothing when that shortcut is unset.
    private static func through(_ keys: [String], _ next: String) -> [String] {
        keys.isEmpty ? [] : keys + [next]
    }
}

/// One key the guide teaches: what to press and what it does. No keys means the shortcut is
/// not set; the guide says where to set it instead.
struct OnboardingShortcut: Identifiable, Equatable {
    let id: String
    let keys: [String]
    let title: String
}
