import Foundation

/// Localized labels for well-known folders, without Finder metadata or other file-system calls.
enum AskFileLabels {
    static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = AskFileScope.normalize(AskLauncherSearchSettings.expand(path, home: home))
        if expanded == home { return L("ask.files.folder.home") }
        let name = (expanded as NSString).lastPathComponent
        let keys = ["Desktop": "desktop", "Documents": "documents", "Downloads": "downloads",
                    "Music": "music", "Pictures": "pictures", "Movies": "movies", "Library": "library",
                    "Applications": "applications", "Volumes": "volumes",
                    "Mobile Documents": "icloud", "CloudStorage": "cloud"]
        return keys[name].map { L("ask.files.folder." + $0) } ?? name
    }

    /// Permission guidance already names protected folders; only exceptional nonzero skips belong here.
    static func skipped(_ status: AskFileIndexStatus) -> String? {
        let counts = [(status.timedOut, "timeout"), (status.failed, "failed"), (status.nonLocalMounts, "mount")]
        let parts = counts.compactMap { count, key in
            count > 0 ? L("ask.files.skip." + key, count.formatted()) : nil
        }
        guard !parts.isEmpty else { return nil }
        return L("ask.plugin.files.skipped", parts.joined(separator: L("ask.plugin.files.separator")))
    }
}
