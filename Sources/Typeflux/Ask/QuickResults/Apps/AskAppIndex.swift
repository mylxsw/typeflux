import AppKit

/// What the launcher needs from the application index. Tests supply a fixed list.
protocol AskAppSearching: AnyObject, Sendable {
    func search(_ query: String, limit: Int) -> [AskAppMatch]
    /// Rescans in the background when the list is missing or old.
    func refreshIfStale()
    /// Remembers an application opened from the launcher, to rank it higher.
    func recordLaunch(_ entry: AskAppEntry)
}

/// The applications installed on this Mac, kept in memory. A scan reads a few
/// hundred Info.plist files, so it runs off the main thread when the launcher
/// is built and again when it opens after `maximumAge`; searches never wait for it.
final class AskAppIndex: AskAppSearching, @unchecked Sendable {
    static let shared = AskAppIndex()
    static let maximumAge: TimeInterval = 300
    private static let launchesKey = "ask.quickResults.appLaunches"

    private let roots: [URL]
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [AskAppEntry] = []
    private var launches: [String: Int]
    private var scannedAt: Date?
    private var scanning = false

    init(roots: [URL] = AskAppIndex.defaultRoots, defaults: UserDefaults = .standard) {
        self.roots = roots
        self.defaults = defaults
        launches = defaults.dictionary(forKey: Self.launchesKey) as? [String: Int] ?? [:]
    }

    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Applications", isDirectory: true),
               URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)]
    }

    func search(_ query: String, limit: Int = 5) -> [AskAppMatch] {
        let (entries, launches) = lock.withLock { (self.entries, self.launches) }
        return AskAppMatcher.search(query, in: entries, launches: launches, limit: limit)
    }

    func refreshIfStale() {
        let start = lock.withLock { () -> Bool in
            guard !scanning, scannedAt.map({ Date().timeIntervalSince($0) > Self.maximumAge }) ?? true else { return false }
            scanning = true
            return true
        }
        guard start else { return }
        let roots = roots
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.scan(roots)
            self?.lock.withLock {
                self?.entries = found
                self?.scannedAt = Date()
                self?.scanning = false
            }
        }
    }

    /// Scans synchronously; for tests and callers already off the main thread.
    func refreshNow() {
        let found = Self.scan(roots)
        lock.withLock { entries = found; scannedAt = Date() }
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
            let children = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? [])
                .sorted { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }
            for child in children {
                if child.pathExtension == "app" { add(child); continue }
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let nested = (try? files.contentsOfDirectory(at: child, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
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

/// Application icons for the launcher's rows, cached by path.
enum AskAppIcon {
    @MainActor private static let cache = NSCache<NSString, NSImage>()

    @MainActor static func image(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}
