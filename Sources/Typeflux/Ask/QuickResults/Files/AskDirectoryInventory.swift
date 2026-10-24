import Foundation

/// A bounded, process-local handoff between filename scans and content discovery.
/// Readers validate directory identity/mtime/ctime in the isolated worker before every reuse.
final class AskDirectoryInventory: @unchecked Sendable {
    static let shared = AskDirectoryInventory()
    struct Listing {
        let id = UUID().uuidString
        let scope: AskFileScope
        let version: String
        let entries: [AskFileCrawler.Entry]
        var skippedMounts: [String] = []
        var bytes: Int {
            entries.reduce(128) { $0 + 64 + $1.path.utf8.count }
                + skippedMounts.reduce(0) { $0 + 32 + $1.utf8.count }
        }
    }
    private struct Stored { let listing: Listing; let bytes: Int; var used: UInt64 }
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes = 0
    private var clock: UInt64 = 0
    private var listings: [String: Stored] = [:]

    init(maximumBytes: Int = 16 * 1024 * 1024) { self.maximumBytes = max(0, maximumBytes) }

    func listing(path: String, scope: AskFileScope) -> Listing? {
        lock.withLock {
            guard var stored = listings[path], Self.covers(stored.listing.scope, scope) else { return nil }
            clock &+= 1; stored.used = clock; listings[path] = stored
            return stored.listing
        }
    }

    func store(path: String, listing: Listing) {
        let size = listing.bytes
        guard size <= maximumBytes else { return }
        lock.withLock {
            if let previous = listings.removeValue(forKey: path) { bytes -= previous.bytes }
            while bytes + size > maximumBytes || listings.count >= 4096 {
                guard let oldest = listings.min(by: { $0.value.used < $1.value.used })?.key else { break }
                bytes -= listings.removeValue(forKey: oldest)!.bytes
            }
            clock &+= 1; listings[path] = Stored(listing: listing, bytes: size, used: clock); bytes += size
        }
    }

    func invalidate(path: String, id: String) {
        lock.withLock {
            guard listings[path]?.listing.id == id, let previous = listings.removeValue(forKey: path) else { return }
            bytes -= previous.bytes
        }
    }

    private static func covers(_ source: AskFileScope, _ target: AskFileScope) -> Bool {
        // Exact roots/path exclusions preserve explicit-root overrides. Content can be more restrictive.
        source.roots == target.roots && source.excludedPaths == target.excludedPaths && source.blocked == target.blocked
            && (source.includeHidden || !target.includeHidden)
            && source.excludedFolderNames.isSubset(of: target.excludedFolderNames)
            && source.excludedExtensions.isSubset(of: target.excludedExtensions)
    }
}
