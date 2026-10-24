import Foundation

/// Defaults include window frames, application usage and other runtime bookkeeping.
/// A broadcast refresh must not pretend every user-facing preference changed.
@MainActor
struct FeaturePreferenceChanges {
    private var previous: [String: Any]

    init(defaults: UserDefaults) { previous = defaults.dictionaryRepresentation() }

    mutating func notifications(in defaults: UserDefaults) -> [Notification.Name] {
        let next = defaults.dictionaryRepresentation()
        let keys = Set(previous.keys).union(next.keys).filter {
            (previous[$0] as? NSObject) != (next[$0] as? NSObject)
        }
        previous = next
        func matches(_ prefixes: [String]) -> Bool {
            keys.contains { key in prefixes.contains { key.hasPrefix($0) } }
        }
        var result: [Notification.Name] = []
        if matches(["ui.overlayStyle", "ui.liquidGlassIntensity"]) { result.append(.interfaceStyleDidChange) }
        if keys.contains("ui.appearance") { result.append(.appearanceModeDidChange) }
        if matches(["agent."]) { result.append(.agentConfigurationDidChange) }
        if keys.contains("ui.language") { result.append(.appLanguageDidChange) }
        if keys.contains("ui.appIconStyle") { result.append(.appIconStyleDidChange) }
        if matches(["ui.voiceCapsule."]) { result.append(.voiceCapsuleDidChange) }
        if keys.contains("audio.input.preferredMicrophoneID") { result.append(.preferredMicrophoneDidChange) }
        if keys.contains("audio.recording.instantVoiceInput") { result.append(.instantVoiceInputDidChange) }
        if matches(["persona.items"]) { result.append(.personaStoreDidChange) }
        if matches(["persona."]) { result.append(.personaSelectionDidChange) }
        if matches(["ring."]) { result.append(.ringSettingsDidChange) }
        if keys.contains("clipboard.pausedUntil") { result.append(.clipboardRecordingPauseDidChange) }
        return result
    }
}
