import Foundation

/// Where and how the recording capsule appears. All styles share one state machine;
/// only placement, shape and information density differ.
enum VoiceCapsuleStyle: String, CaseIterable, Codable {
    /// The original capsule, centered above the bottom of the screen.
    case bottomCapsule
    /// The original capsule's place and size with the corner card's language: an orb with
    /// ripples instead of the waveform, a timer, and controls only on hover.
    case orbCapsule
    /// A Siri-like card below the menu bar, in a top corner.
    case cornerCard
    /// A black island that grows out of the MacBook camera housing.
    case notchIsland

    var displayName: String {
        switch self {
        case .bottomCapsule: L("voiceCapsule.style.bottomCapsule")
        case .orbCapsule: L("voiceCapsule.style.orbCapsule")
        case .cornerCard: L("voiceCapsule.style.cornerCard")
        case .notchIsland: L("voiceCapsule.style.notchIsland")
        }
    }

    var detail: String {
        switch self {
        case .bottomCapsule: L("voiceCapsule.style.bottomCapsule.detail")
        case .orbCapsule: L("voiceCapsule.style.orbCapsule.detail")
        case .cornerCard: L("voiceCapsule.style.cornerCard.detail")
        case .notchIsland: L("voiceCapsule.style.notchIsland.detail")
        }
    }
}

/// The top corner the corner card occupies.
enum VoiceCapsuleCornerEdge: String, CaseIterable, Codable {
    case leading
    case trailing

    var displayName: String {
        switch self {
        case .leading: L("voiceCapsule.corner.leading")
        case .trailing: L("voiceCapsule.corner.trailing")
        }
    }
}

/// What the notch island does on a display without a camera housing.
enum VoiceCapsuleNotchFallback: String, CaseIterable, Codable {
    /// Draws a black island at the top center that is hidden while idle.
    case simulateNotch
    case cornerCard
    case bottomCapsule

    var displayName: String {
        switch self {
        case .simulateNotch: L("voiceCapsule.notchFallback.simulateNotch")
        case .cornerCard: L("voiceCapsule.notchFallback.cornerCard")
        case .bottomCapsule: L("voiceCapsule.notchFallback.bottomCapsule")
        }
    }
}

/// Which display shows the capsule when several are connected.
enum VoiceCapsuleScreenChoice: String, CaseIterable, Codable {
    /// The display of the focused window; the capsule's original behavior.
    case activeWindow
    case mouse
    case main

    var displayName: String {
        switch self {
        case .mouse: L("voiceCapsule.screen.mouse")
        case .activeWindow: L("voiceCapsule.screen.activeWindow")
        case .main: L("voiceCapsule.screen.main")
        }
    }
}

/// Every capsule preference, read and written as one value.
struct VoiceCapsulePreferences: Equatable {
    var style: VoiceCapsuleStyle = .bottomCapsule
    var cornerEdge: VoiceCapsuleCornerEdge = .trailing
    var notchFallback: VoiceCapsuleNotchFallback = .simulateNotch
    var notchHoverExpands = true
    var showsLivePreview = true
    var showsTargetApp = true
    var screen: VoiceCapsuleScreenChoice = .activeWindow

    enum Key {
        static let style = "ui.voiceCapsule.style"
        static let cornerEdge = "ui.voiceCapsule.cornerEdge"
        static let notchFallback = "ui.voiceCapsule.notchFallback"
        static let notchHoverExpands = "ui.voiceCapsule.notchHoverExpand"
        static let showsLivePreview = "ui.voiceCapsule.livePreview"
        static let showsTargetApp = "ui.voiceCapsule.showContext"
        static let screen = "ui.voiceCapsule.screen"
    }

    init() {}

    init(defaults: UserDefaults) {
        style = defaults.string(forKey: Key.style).flatMap(VoiceCapsuleStyle.init(rawValue:)) ?? style
        cornerEdge = defaults.string(forKey: Key.cornerEdge).flatMap(VoiceCapsuleCornerEdge.init(rawValue:)) ?? cornerEdge
        notchFallback = defaults.string(forKey: Key.notchFallback)
            .flatMap(VoiceCapsuleNotchFallback.init(rawValue:)) ?? notchFallback
        notchHoverExpands = defaults.object(forKey: Key.notchHoverExpands) as? Bool ?? notchHoverExpands
        showsLivePreview = defaults.object(forKey: Key.showsLivePreview) as? Bool ?? showsLivePreview
        showsTargetApp = defaults.object(forKey: Key.showsTargetApp) as? Bool ?? showsTargetApp
        screen = defaults.string(forKey: Key.screen).flatMap(VoiceCapsuleScreenChoice.init(rawValue:)) ?? screen
    }

    func write(to defaults: UserDefaults) {
        defaults.set(style.rawValue, forKey: Key.style)
        defaults.set(cornerEdge.rawValue, forKey: Key.cornerEdge)
        defaults.set(notchFallback.rawValue, forKey: Key.notchFallback)
        defaults.set(notchHoverExpands, forKey: Key.notchHoverExpands)
        defaults.set(showsLivePreview, forKey: Key.showsLivePreview)
        defaults.set(showsTargetApp, forKey: Key.showsTargetApp)
        defaults.set(screen.rawValue, forKey: Key.screen)
    }
}
