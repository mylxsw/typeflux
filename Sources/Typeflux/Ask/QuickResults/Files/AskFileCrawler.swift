import Foundation

/// Walks search folders through an isolated reader. Guarded paths are filtered before I/O.
enum AskFileCrawler {
    /// No index holds more than this; past it the settings ask for smaller folders.
    static let maximumEntries = 1_000_000

    struct Entry: Equatable, Codable {
        var path: String
        var kind: AskFileRecord.Kind
        var modified: Date
    }

    enum SkipReason: Equatable { case timeout, failed, nonLocalMount }

    /// Each directory is a separate deadline-bound request, so siblings survive a blocked read.
    @discardableResult
    static func crawl(_ root: String, scope: AskFileScope, limit: Int = maximumEntries,
                      reader: AskFileReading = AskFileReader(), isCancelled: () -> Bool = { false },
                      skipped: (String, SkipReason) -> Void = { _, _ in }, visit: (Entry) -> Bool) -> Int {
        guard limit > 0, scope.includes(root, isDirectory: true) else { return 0 }
        var pending = [root]
        var visited = 0
        while let path = pending.popLast() {
            if isCancelled() { break }
            do {
                var stopped = false
                try reader.stream(.init(operation: .directory, path: path, scope: scope, limit: limit - visited),
                                  isCancelled: isCancelled) { response in
                    if response.error != nil { skipped(path, .failed) }
                    for mount in response.skippedMounts ?? [] { skipped(mount, .nonLocalMount) }
                    for entry in response.entries {
                        if isCancelled() { stopped = true; return false }
                        guard scope.includes(entry.path, isDirectory: entry.kind != .file) else { continue }
                        visited += 1
                        if !visit(entry) || visited >= limit { stopped = true; return false }
                        if entry.kind == .folder, !scope.roots.contains(entry.path) { pending.append(entry.path) }
                    }
                    return true
                }
                if stopped { return visited }
            } catch AskFileReadError.cancelled { break }
            catch AskFileReadError.timeout { skipped(path, .timeout) }
            catch { skipped(path, .failed) }
        }
        return visited
    }

    /// Resolve metadata only after the pure scope check, including FSEvents updates.
    static func entry(at path: String, scope: AskFileScope, reader: AskFileReading = AskFileReader()) -> Entry? {
        guard scope.includes(path, isDirectory: false) || scope.includes(path, isDirectory: true) else { return nil }
        return try? metadata(at: path, scope: scope, reader: reader)
    }

    static func metadata(at path: String, scope: AskFileScope, reader: AskFileReading) throws -> Entry? {
        let response = try reader.read(.init(operation: .entry, path: path, scope: scope), isCancelled: { false })
        if !(response.skippedMounts ?? []).isEmpty { throw AskFileReadError.nonLocalMount }
        if let code = response.error, code != ENOENT, code != ENOTDIR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return response.entries.first
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
        return knownPackages.contains(ext.lowercased())
    }
}
