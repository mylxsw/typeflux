import Foundation

/// The global shortcuts Typeflux has always had. Each is stored under its own
/// `SettingsStore` key and some are gestures (hold, double tap, modifier chords).
enum BuiltInHotkey: String, CaseIterable, Codable, Sendable {
    case activation
    case auxiliary
    case persona
    case ask
    case history
    case screenshot

    var defaultBinding: HotkeyBinding {
        switch self {
        case .activation: .defaultActivation
        case .auxiliary: .defaultAuxiliary
        case .persona: .defaultPersona
        case .ask: .defaultAsk
        case .history: .defaultHistory
        case .screenshot: .defaultScreenshot
        }
    }

    var title: String {
        L("hotkeys.builtIn.\(rawValue).title")
    }
}

/// Core features that had no global shortcut before the Shortcuts page. They have
/// no default, so a new shortcut never takes keys from the user or another app.
enum AppHotkeyAction: String, CaseIterable, Codable, Sendable {
    case openChat
    case screenshotText
    case translate
    case screenshotTranslation
    case openNotes
    case openWordBook
    case openStudio
    case openHelp
    /// Hold to open the ring at the pointer; releasing runs the slice under it.
    case ring

    var title: String {
        L("hotkeys.action.\(rawValue).title")
    }

    static let translation: [Self] = [.translate, .screenshotTranslation]
}

/// Anything on the Shortcuts page that can own a key combination.
enum HotkeyTarget: Hashable, Sendable {
    case builtIn(BuiltInHotkey)
    case action(AppHotkeyAction)
    case keyword(UUID)
}
