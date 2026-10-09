import AppKit

/// What the launcher needs from the application index. Tests supply a fixed list.
protocol AskAppSearching: AnyObject, Sendable {
    func search(_ query: String, limit: Int) -> [AskAppMatch]
    /// Rescans in the background when the list is missing or old.
    func refreshIfStale()
    /// Remembers an application opened from the launcher, to rank it higher.
    func recordLaunch(_ entry: AskAppEntry)
}

/// The applications installed on this Mac, and System Settings' panes, kept in
/// memory. A scan reads a few hundred Info.plist files, so it runs off the main
/// thread; searches never wait for it. The folders come from Settings › Launcher ›
/// Search; FSEvents rescans them when an app is installed or removed, and
/// `maximumAge` is the fallback when no change was seen.
final class AskAppIndex: AskAppSearching, @unchecked Sendable {
    static let shared = AskAppIndex(watch: true)
    static let didChange = Notification.Name("AskAppIndex.didChange")
    static let maximumAge: TimeInterval = 300
    private static let launchesKey = "ask.quickResults.appLaunches"
    /// Where macOS 13 and later keep the System Settings panes.
    static let settingsExtensions = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
    static let settingsExtensionPoint = "com.apple.Settings.extension.ui"

    private let fixedRoots: [URL]?
    private let settings: () -> AskLauncherSearchSettings
    private let panesFolder: URL
    private let defaults: UserDefaults
    private let watches: Bool
    private let lock = NSLock()
    private var entries: [AskAppEntry] = []
    private var launches: [String: Int]
    private var scannedAt: Date?
    private var scannedFor: AskLauncherSearchSettings?
    private var scanning = false
    private var watcher: AskFileWatching?
    private var watchedFolders: [String] = []
    private var observer: NSObjectProtocol?

    /// `roots` fixes the folders (tests); otherwise they come from the search settings.
    init(roots: [URL]? = nil, defaults: UserDefaults = .standard,
         settings: @escaping () -> AskLauncherSearchSettings = { SettingsStore().askLauncherSearchSettings },
         panesFolder: URL = AskAppIndex.settingsExtensions, watch: Bool = false) {
        fixedRoots = roots
        self.settings = settings
        self.panesFolder = panesFolder
        self.defaults = defaults
        watches = watch
        launches = defaults.dictionary(forKey: Self.launchesKey) as? [String: Int] ?? [:]
        if watch {
            observer = NotificationCenter.default.addObserver(forName: .askLauncherSearchSettingsDidChange, object: nil,
                                                              queue: nil) { [weak self] _ in self?.refreshIfStale() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        watcher?.stop()
    }

    static var defaultRoots: [URL] {
        AskLauncherSearchSettings.defaultAppRoots.map { URL(fileURLWithPath: AskLauncherSearchSettings.expand($0), isDirectory: true) }
    }

    private func roots(for settings: AskLauncherSearchSettings) -> [URL] {
        fixedRoots ?? settings.appRoots.map { URL(fileURLWithPath: AskLauncherSearchSettings.expand($0), isDirectory: true) }
    }

    func search(_ query: String, limit: Int = 5) -> [AskAppMatch] {
        let (entries, launches, fuzzy) = lock.withLock { (self.entries, self.launches, scannedFor?.fuzzy ?? true) }
        return AskAppMatcher.search(query, in: entries, launches: launches, limit: limit, fuzzy: fuzzy)
    }

    func refreshIfStale() {
        let current = settings()
        let start = lock.withLock { () -> Bool in
            let old = scannedAt.map { Date().timeIntervalSince($0) > Self.maximumAge } ?? true
            let changed = scannedFor.map { $0.appRoots != current.appRoots || $0.settingsPanes != current.settingsPanes } ?? true
            if !old, !changed, scannedFor?.fuzzy != current.fuzzy { scannedFor = current }
            guard !scanning, old || changed else { return false }
            scanning = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.scanAndStore(current) }
    }

    /// Scans synchronously; for tests and callers already off the main thread.
    func refreshNow() {
        scanAndStore(settings())
    }

    private func scanAndStore(_ settings: AskLauncherSearchSettings) {
        let roots = roots(for: settings)
        let found = Self.scan(roots) + (settings.settingsPanes && fixedRoots == nil ? Self.scanPanes(panesFolder) : [])
        lock.withLock {
            entries = found
            scannedAt = Date()
            scannedFor = settings
            scanning = false
        }
        if watches { watch(roots) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Rescans soon after anything changes in the application folders.
    private func watch(_ roots: [URL]) {
        let folders = roots.map(\.path).filter { !$0.hasSuffix(".app") }
        let watcher = AskFSEventsWatcher()
        watcher.latency = 1
        // Swapped under the lock, stopped outside it: a change being reported takes the lock too.
        let replaced = lock.withLock { () -> AskFileWatching?? in
            guard folders != watchedFolders || self.watcher == nil else { return .none }
            let old = self.watcher
            self.watcher = watcher
            watchedFolders = folders
            return .some(old)
        }
        guard let replaced else { return }
        replaced?.stop()
        watcher.start(paths: folders, since: nil) { [weak self] changes, _ in
            guard let self, changes.contains(where: { $0.path.contains(".app") || $0.rescan }) else { return }
            lock.withLock { self.scannedAt = nil }
            refreshIfStale()
        }
    }

    func recordLaunch(_ entry: AskAppEntry) {
        let snapshot = lock.withLock { () -> [String: Int] in
            launches[entry.id, default: 0] += 1
            return launches
        }
        defaults.set(snapshot, forKey: Self.launchesKey)
    }

    // MARK: - Scanning

    /// Applications directly in each root and one folder down (e.g. /Applications/Utilities),
    /// first root wins for a bundle identifier found twice.
    static func scan(_ roots: [URL]) -> [AskAppEntry] {
        let files = FileManager.default
        func rank(_ url: URL) -> Int { url.pathExtension == "app" ? 0 : 1 }
        var found: [AskAppEntry] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard let entry = entry(at: url), seen.insert(entry.id).inserted else { return }
            found.append(entry)
        }
        for root in roots {
            if root.pathExtension == "app" { add(root); continue }
            // Applications first, then folders; each by name, so a scan is repeatable.
            let children = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                                                            options: [])) ?? [])
                .sorted { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }
            for child in children {
                if child.pathExtension == "app" { add(child); continue }
                guard !child.lastPathComponent.hasPrefix("."),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
                      values.isHidden != true, values.isDirectory == true else { continue }
                let nested = (try? files.contentsOfDirectory(at: child, includingPropertiesForKeys: nil,
                                                             options: [])) ?? []
                nested.filter { $0.pathExtension == "app" }.forEach(add)
            }
        }
        return found
    }

    /// Reads one bundle: Finder's name, the bundle's own and localized names,
    /// and its Simplified Chinese name, so "微信", "WeChat" and "weixin" all find it.
    static func entry(at url: URL) -> AskAppEntry? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        if info["LSBackgroundOnly"] as? Bool == true { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        var display = FileManager.default.displayName(atPath: url.path)
        if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
        var names = [fileName]
        for dictionary in [bundle.localizedInfoDictionary, info, chineseInfo(bundle)].compactMap({ $0 }) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = dictionary[key] as? String { names.append(name) }
            }
        }
        return AskAppEntry(name: display.isEmpty ? fileName : display, url: url,
                           bundleID: bundle.bundleIdentifier, names: names)
    }

    /// The panes of System Settings: its extensions for the settings extension point.
    static func scanPanes(_ folder: URL) -> [AskAppEntry] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return children.filter { $0.pathExtension == "appex" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(pane(at:))
    }

    static func pane(at url: URL) -> AskAppEntry? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let attributes = info["EXAppExtensionAttributes"] as? [String: Any]
        guard attributes?["EXExtensionPointIdentifier"] as? String == settingsExtensionPoint else { return nil }
        var names: [String] = []
        for dictionary in [bundle.localizedInfoDictionary, info, chineseInfo(bundle)].compactMap({ $0 }) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = dictionary[key] as? String { names.append(name) }
            }
        }
        guard let display = names.first(where: { !$0.isEmpty }) else { return nil }
        return AskAppEntry(name: display, url: url, bundleID: id, names: names, kind: .settingsPane)
    }

    private static let chineseLocalizations = ["zh-Hans", "zh_CN", "zh-CN", "zh_Hans", "zh"]

    /// Third-party apps ship `zh-Hans.lproj/InfoPlist.strings`; Apple's own keep
    /// every language in one `InfoPlist.loctable`.
    static func chineseInfo(_ bundle: Bundle) -> [String: Any]? {
        for localization in chineseLocalizations {
            if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil,
                                      forLocalization: localization),
               let strings = NSDictionary(contentsOfFile: path) as? [String: Any] {
                return strings
            }
        }
        if let url = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
           let table = NSDictionary(contentsOf: url) as? [String: Any] {
            for localization in chineseLocalizations {
                if let strings = table[localization] as? [String: Any] { return strings }
            }
        }
        return nil
    }
}

/// Loads a resolved application's Finder icon off the main thread. The result
/// cache owns coalescing and caching; only image construction happens on MainActor.
enum AskAppIcon {
    @MainActor static func image(for resolvedURL: URL) async -> NSImage? {
        let data = await Task.detached(priority: .utility) {
            NSWorkspace.shared.icon(forFile: resolvedURL.path).tiffRepresentation
        }.value
        guard !Task.isCancelled else { return nil }
        return data.flatMap { NSImage(data: $0) }
    }
}
