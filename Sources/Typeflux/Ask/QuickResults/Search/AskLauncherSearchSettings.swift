import Foundation

/// How the launcher searches applications and files: Settings › Launcher › Search.
/// Paths are kept as typed, with `~` for the home folder.
struct AskLauncherSearchSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Applications first, with files added as their search completes.
        case mixed
        case appsFirst
        case filesFirst
    }

    enum FileIcons: String, Codable, CaseIterable, Sendable {
        /// Pictures and PDFs show what is in them.
        case thumbnails
        case icons
    }

    static let defaultAppRoots = ["/Applications", "~/Applications", "/System/Applications",
                                  "/System/Cryptexes/App/System/Applications",
                                  "/System/Library/CoreServices/Applications",
                                  "/System/Library/CoreServices/Finder.app"]
    static let defaultFileRoots = ["~"]
    static let defaultExcludedPaths = ["~/Library"]
    static let defaultExcludedFolderNames = ["node_modules", ".git", ".svn", ".hg", "DerivedData", ".build", "build",
                                             "Pods", "__pycache__", ".venv", "venv", ".Trash", ".gradle", ".next"]
    static let limits = [10, 20, 30, 50]

    var mode: Mode = .mixed
    /// Letters in order count as a match (`tbpls` → TablePlus).
    var fuzzy = true
    /// At most this many files in file mode.
    var limit = 30
    var fileIcons: FileIcons = .thumbnails
    var appRoots = Self.defaultAppRoots
    /// Lists System Settings panes such as Network.
    var settingsPanes = true
    var fileRoots = Self.defaultFileRoots
    var excludedPaths = Self.defaultExcludedPaths
    /// Extensions without the dot, lowercased.
    var excludedExtensions: [String] = []
    var excludedFolderNames = Self.defaultExcludedFolderNames
    var includeHidden = false

    init() {}

    /// Missing fields keep their defaults, so settings saved by an older version still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AskLauncherSearchSettings()
        // Search always uses the built-in application-first mixed policy, including older saves.
        mode = .mixed
        fuzzy = try container.decodeIfPresent(Bool.self, forKey: .fuzzy) ?? defaults.fuzzy
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? defaults.limit
        fileIcons = try container.decodeIfPresent(FileIcons.self, forKey: .fileIcons) ?? defaults.fileIcons
        appRoots = try container.decodeIfPresent([String].self, forKey: .appRoots) ?? defaults.appRoots
        settingsPanes = try container.decodeIfPresent(Bool.self, forKey: .settingsPanes) ?? defaults.settingsPanes
        fileRoots = try container.decodeIfPresent([String].self, forKey: .fileRoots) ?? defaults.fileRoots
        excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? defaults.excludedPaths
        excludedExtensions = try container.decodeIfPresent([String].self, forKey: .excludedExtensions) ?? []
        excludedFolderNames = try container.decodeIfPresent([String].self, forKey: .excludedFolderNames)
            ?? defaults.excludedFolderNames
        includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? defaults.includeHidden
        limit = Self.limits.contains(limit) ? limit : defaults.limit
    }

    /// What the file index depends on: when this changes, the index is built again.
    var fileIndexFingerprint: String {
        let parts = [fileRoots.map { Self.expand($0) }.sorted().joined(separator: "\u{1}"),
                     excludedPaths.map { Self.expand($0) }.sorted().joined(separator: "\u{1}"),
                     excludedExtensions.map { $0.lowercased() }.sorted().joined(separator: "\u{1}"),
                     excludedFolderNames.sorted().joined(separator: "\u{1}"),
                     includeHidden ? "hidden" : ""]
        return parts.joined(separator: "\u{2}")
    }

    /// `~` and `~/…` become the home folder; trailing slashes go.
    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        var expanded = path.trimmingCharacters(in: .whitespaces)
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst()
        }
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }

    /// The home folder as `~`, for showing a path.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A folder name or extension as the user typed it, cleaned up; nil when nothing is left.
    static func cleanExtension(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".*"))
            .lowercased()
        return cleaned.isEmpty || cleaned.contains("/") ? nil : cleaned
    }

    static func cleanFolderName(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.contains("/") ? nil : cleaned
    }
}

extension Notification.Name {
    /// Posted by `SettingsStore` when the launcher's search settings change; the indexes follow.
    static let askLauncherSearchSettingsDidChange = Notification.Name("AskLauncherSearchSettings.didChange")
}
