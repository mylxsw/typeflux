import Foundation
import Observation
import SwiftUI

enum ChatAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system: NSLocalizedString("Follow system", comment: "Appearance choice")
        case .light: NSLocalizedString("Light appearance", comment: "Appearance choice")
        case .dark: NSLocalizedString("Dark appearance", comment: "Appearance choice")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Device preferences are independent of the signed-in account.
@MainActor @Observable
final class ChatPreferences {
    static let appearanceKey = "ui.appearance"
    static let syntheticDomain = "app.typeflux.ios.synthetic-preferences"
    private let defaults: UserDefaults

    var appearance: ChatAppearance {
        didSet {
            if appearance != oldValue {
                defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard, resetAppearance: Bool = false) {
        self.defaults = defaults
        if resetAppearance {
            defaults.removeObject(forKey: Self.appearanceKey)
        }
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(ChatAppearance.init(rawValue:)) ?? .system
    }

    /// Preview launches start clean unless a persistence test explicitly keeps them.
    /// They never use the real application's preferences domain.
    static func synthetic(arguments: [String], defaults: UserDefaults? = nil) -> ChatPreferences {
        guard let storage = defaults ?? UserDefaults(suiteName: syntheticDomain) else {
            preconditionFailure("The dedicated preview preferences domain must be available.")
        }
        return ChatPreferences(defaults: storage,
                               resetAppearance: !arguments.contains("--synthetic-preserve-settings"))
    }
}

enum ChatSettingsInfo {
    /// Matches the existing Mac account help page.
    static let privacyURL = URL(string: "https://typeflux.app/privacy")!

    static func languageName(preferredLocalizations: [String] = Bundle.main.preferredLocalizations) -> String {
        preferredLocalizations.first?.hasPrefix("zh-Hans") == true ? "简体中文" : "English"
    }

    static func version(shortVersion: String?, build: String?) -> String {
        let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if version.isEmpty {
            return build.isEmpty ? "—" : build
        }
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    static var version: String {
        version(shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
