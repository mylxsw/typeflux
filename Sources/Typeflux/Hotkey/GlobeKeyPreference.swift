import Foundation

/// macOS `AppleFnUsageType` in `com.apple.HIToolbox`. Controls what happens when the
/// user presses the 🌐 (Globe/Fn) key. When the value is anything other than
/// `doNothing`, macOS intercepts the key and downstream hotkeys never fire.
enum GlobeKeyUsage: Int {
    case doNothing = 0
    case changeInputSource = 1
    case showEmojiAndSymbols = 2
    case startDictation = 3
}

/// Reads the current macOS setting for the Globe key behavior. Injectable so
/// tests can simulate each state without touching real preferences.
protocol GlobeKeyPreferenceReading {
    func currentUsage() -> GlobeKeyUsage?
}

extension GlobeKeyPreferenceReading {
    /// Whether the Globe key is free to be used as a Typeflux hotkey.
    var isReadyForHotkey: Bool {
        currentUsage() == .doNothing
    }
}

/// Production reader that queries `com.apple.HIToolbox` via `CFPreferencesCopyValue`.
/// Only an explicit `.doNothing` value is treated as ready. Missing or unknown
/// values are reported as `nil` so onboarding does not show a false positive.
struct SystemGlobeKeyPreferenceReader: GlobeKeyPreferenceReading {
    static let preferenceDomain = "com.apple.HIToolbox"
    static let preferenceKey = "AppleFnUsageType"

    func currentUsage() -> GlobeKeyUsage? {
        let raw = CFPreferencesCopyValue(
            Self.preferenceKey as CFString,
            Self.preferenceDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        )
        if let number = raw as? NSNumber {
            return GlobeKeyUsage(rawValue: number.intValue)
        }
        return nil
    }
}
