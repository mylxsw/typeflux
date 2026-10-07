import Foundation

/// Walks the search folders with `fts`, which reads each folder's entries and
/// their dates in one pass, many times faster than `FileManager`. Excluded and
/// guarded folders are skipped without being opened; bundles count as one entry.
enum AskFileCrawler {
    /// No index holds more than this; past it the settings ask for smaller folders.
    static let maximumEntries = 1_000_000

    struct Entry: Equatable {
        var path: String
        var kind: AskFileRecord.Kind
        var modified: Date
    }

    /// Visits every entry below `root` the scope keeps, parents before children.
    /// `visit` returns false to stop. Returns the number of entries visited.
    @discardableResult
    static func crawl(_ root: String, scope: AskFileScope, limit: Int = maximumEntries,
                      isCancelled: () -> Bool = { false }, visit: (Entry) -> Bool) -> Int {
        guard scope.includes(root, isDirectory: true) else { return 0 }
        var visited = 0
        let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        root.withCString { pointer in
            let copy = strdup(pointer)
            defer { free(copy) }
            var arguments: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let stream = fts_open(&arguments, options, nil) else { return }
            defer { fts_close(stream) }
            while let entry = fts_read(stream) {
                if visited % 512 == 0, isCancelled() { return }
                let info = Int32(entry.pointee.fts_info)
                // Children are visited after their folder; the second visit of a folder is not news.
                if info == FTS_DP { continue }
                let path = String(cString: entry.pointee.fts_path)
                if entry.pointee.fts_level == FTS_ROOTLEVEL { continue }
                let isDirectory = info == FTS_D || info == FTS_DNR || info == FTS_DC
                guard scope.includes(path, isDirectory: isDirectory) else {
                    if isDirectory { fts_set(stream, entry, FTS_SKIP) }
                    continue
                }
                let kind: AskFileRecord.Kind
                switch info {
                case FTS_D:
                    // Another search folder is scanned on its own, with its own exclusions.
                    if scope.roots.contains(path) {
                        fts_set(stream, entry, FTS_SKIP)
                        kind = .folder
                    } else if isPackage(path) {
                        fts_set(stream, entry, FTS_SKIP)
                        kind = .package
                    } else {
                        kind = .folder
                    }
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: kind = .file
                default: continue
                }
                let modified = entry.pointee.fts_statp.map {
                    Date(timeIntervalSince1970: TimeInterval($0.pointee.st_mtimespec.tv_sec))
                } ?? Date()
                visited += 1
                if !visit(Entry(path: path, kind: kind, modified: modified)) || visited >= limit { return }
            }
        }
        return visited
    }

    /// The entry at `path` as the crawler would list it, or nil when it is gone or not kept.
    static func entry(at path: String, scope: AskFileScope) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        guard scope.includes(path, isDirectory: isDirectory) else { return nil }
        let kind: AskFileRecord.Kind = isDirectory ? (isPackage(path) ? .package : .folder) : .file
        return Entry(path: path, kind: kind, modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }

    private static let knownPackages: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace",
        "playground", "plugin", "kext", "appex", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
        "band", "prefpane", "qlgenerator", "mdimporter"
    ]

    /// Folders with an extension that Finder shows as one file.
    static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        if knownPackages.contains(ext.lowercased()) { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
