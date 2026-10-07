import Foundation

/// Which files the index keeps: under a search folder, outside the exclusions,
/// and away from folders macOS guards until Typeflux has Full Disk Access.
struct AskFileScope: Equatable, Sendable {
    /// Absolute folders, deepest first, so the folder that decides for a path is found first.
    var roots: [String]
    var excludedPaths: [String]
    var excludedFolderNames: Set<String>
    var excludedExtensions: Set<String>
    var includeHidden: Bool
    /// Folders skipped for now: listing them would make macOS ask for permission out of the blue.
    var blocked: [String]

    /// Folders macOS asks about before an app may read them (Desktop, Documents, Downloads,
    /// iCloud Drive, file providers, other volumes).
    static func protectedFolders(home: String = NSHomeDirectory()) -> [String] {
        ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 } + ["/Volumes"]
    }

    init(settings: AskLauncherSearchSettings, fullDiskAccess: Bool, home: String = NSHomeDirectory()) {
        // Real paths, as FSEvents reports them: a folder added through a symlink (/tmp) still hears its changes.
        let expand = { (path: String) in Self.canonical(AskLauncherSearchSettings.expand(path, home: home)) }
        roots = Self.unique(settings.fileRoots.map(expand).filter { $0.hasPrefix("/") })
            .sorted { $0.count > $1.count }
        excludedPaths = Self.unique(settings.excludedPaths.map(expand).filter { $0.hasPrefix("/") })
        excludedFolderNames = Set(settings.excludedFolderNames.map { $0.lowercased() })
        excludedExtensions = Set(settings.excludedExtensions.compactMap(AskLauncherSearchSettings.cleanExtension))
        includeHidden = settings.includeHidden
        blocked = fullDiskAccess ? [] : Self.protectedFolders(home: home)
    }

    /// The guarded folders the user asked to search: what the launcher offers to unlock.
    var blockedInScope: [String] {
        blocked.filter { folder in roots.contains { Self.isInside(folder, $0) || Self.isInside($0, folder) } }
    }

    /// The search folder `path` falls under, the deepest one.
    func root(of path: String) -> String? {
        roots.first { Self.isInside(path, $0) }
    }

    /// Whether the index keeps `path`. `isDirectory` decides whether excluded folder names apply to its own name.
    func includes(_ path: String, isDirectory: Bool) -> Bool {
        guard let root = root(of: path) else { return false }
        // An exclusion only wins over a folder the user did not add below it (~/Library vs ~/Library/Mobile Documents).
        if excludedPaths.contains(where: { Self.isInside(path, $0) && !Self.isInside(root, $0) }) { return false }
        if blocked.contains(where: { Self.isInside(path, $0) }) { return false }
        let relative = path == root ? "" : String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            if !includeHidden, component.hasPrefix(".") { return false }
            if (!isLast || isDirectory), excludedFolderNames.contains(component.lowercased()) { return false }
        }
        if !isDirectory, let last = components.last, let dot = last.lastIndex(of: "."), dot != last.startIndex {
            let ext = last[last.index(after: dot)...].lowercased()
            if excludedExtensions.contains(ext) { return false }
        }
        return true
    }

    /// `path` with symlinks resolved, the way the file system reports it; as it is when it does not exist.
    static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is `folder` or inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        if folder == "/" { return path.hasPrefix("/") }
        return path == folder || path.hasPrefix(folder + "/")
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// Whether Typeflux has Full Disk Access. The system's privacy database can only
/// be opened with it, and trying does not ask the user anything.
enum AskFullDiskAccess {
    static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        let path = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let handle = open(path, O_RDONLY)
        guard handle >= 0 else { return false }
        close(handle)
        return true
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
