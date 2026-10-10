import Foundation

enum AskSearchBrowser: String, CaseIterable, Codable, Sendable, Identifiable {
    case safari, chrome, dia, arc, edge

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .dia: "Dia"
        case .arc: "Arc"
        case .edge: "Microsoft Edge"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .dia: "company.thebrowser.dia"
        case .arc: "company.thebrowser.Browser"
        case .edge: "com.microsoft.edgemac"
        }
    }

    var bookmarkRoot: String {
        switch self {
        case .safari: "Library/Safari"
        case .chrome: "Library/Application Support/Google/Chrome"
        case .dia: "Library/Application Support/Dia/User Data"
        case .arc: "Library/Application Support/Arc"
        case .edge: "Library/Application Support/Microsoft Edge"
        }
    }
}

/// Independent preferences for the two browser sources; no browser data is persisted.
struct AskBrowserSearchSettings: Codable, Equatable, Sendable {
    var tabsEnabled = true
    var bookmarksEnabled = true
    var directTabs = true
    var directBookmarks = true
    var tabBrowsers = AskSearchBrowser.allCases
    var bookmarkBrowsers = AskSearchBrowser.allCases
    /// Empty uses the bookmark's browser, `default` uses the system default.
    var bookmarkBrowser = ""
}

extension SettingsStore {
    var askBrowserSearchSettings: AskBrowserSearchSettings {
        get {
            defaults.data(forKey: "ask.search.browsers")
                .flatMap { try? JSONDecoder().decode(AskBrowserSearchSettings.self, from: $0) }
                ?? AskBrowserSearchSettings()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "ask.search.browsers") }
            NotificationCenter.default.post(name: .askLauncherSearchSettingsDidChange, object: self)
        }
    }
}
