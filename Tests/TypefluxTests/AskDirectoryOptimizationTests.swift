import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized)
struct AskDirectoryOptimizationTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: AskFileScope.canonical(root.path))
    }

    private func scope(_ root: URL) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]; settings.excludedPaths = []
        return AskFileScope(settings: settings, fullDiskAccess: true)
    }

    @Test func bulkAndPOSIXAgreeOnUnicodePackagesAndSymlinksWithoutFollowingTargets() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["普通文档.txt", "résumé.md", ".hidden", "empty"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        for name in ["folder", "slides.key", "node_modules"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: root.path + "/loop", withDestinationPath: root.path)
        let scope = scope(root)
        func read(_ strategy: AskDirectoryIterator.Strategy) throws -> [AskFileCrawler.Entry] {
            let open = { AskFileWorkerCommand.openDirectory(root.path, blocked: []) }
            let iterator = try AskDirectoryIterator(descriptor: open(), strategy: strategy, reopen: open)
            var entries: [AskFileCrawler.Entry] = []
            while let item = try iterator.next() {
                let path = root.path + "/" + item.name
                guard item.name != ".", item.name != "..", scope.includes(path, isDirectory: item.isDirectory) else { continue }
                if let entry = item.entry(parent: iterator.descriptor, path: path, scope: scope) { entries.append(entry) }
            }
            return entries.sorted { $0.path < $1.path }
        }
        let bulk = try read(.automatic)
        #expect(bulk == (try read(.posix)))
        #expect(bulk.count == 6)
        #expect(bulk.first { $0.path.hasSuffix("loop") }?.kind == .file)
        #expect(bulk.first { $0.path.hasSuffix("slides.key") }?.kind == .package)
        #expect(!bulk.contains { $0.path.contains("node_modules") || $0.path.hasSuffix(".hidden") })
    }

    @Test func malformedBulkPacketsFailInsteadOfPublishingPartialMetadata() throws {
        let bytes = [UInt8](repeating: 0, count: 64)
        #expect(throws: NSError.self) { try bytes.withUnsafeBytes { try AskDirectoryIterator.decode($0, count: 1) } }
        #expect(throws: NSError.self) { try bytes.prefix(8).withUnsafeBytes { try AskDirectoryIterator.decode($0, count: 1) } }
    }

    @Test func unsupportedBulkReadReopensBeforeFallingBackToPOSIX() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("readme.md"))
        var reopened = 0
        let iterator = try AskDirectoryIterator(descriptor: AskFileWorkerCommand.openDirectory(root.path, blocked: []),
            reopen: { reopened += 1; return AskFileWorkerCommand.openDirectory(root.path, blocked: []) },
            bulkRead: { _, _, _, _ in errno = ENOTSUP; return -1 })
        var found: [String] = []
        while let item = try iterator.next() {
            if item.name != ".", item.name != ".." { found.append(item.name) }
        }
        #expect(found == ["readme.md"] && reopened == 1)
    }

    @Test func completedFilenameScanFeedsPagedContentDiscoveryAndDirectoryChangesInvalidateIt() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0 ..< 257 { try Data().write(to: root.appendingPathComponent("\(i).txt")) }
        let inventory = AskDirectoryInventory(), scope = scope(root)
        let names = AskFileReader(inventory: inventory)
        let all = try names.read(.init(operation: .directory, path: root.path, scope: scope, limit: nil))
        #expect(all.entries.count == 257)
        let cached = try #require(inventory.listing(path: root.path, scope: scope))
        var request = AskFileReadRequest(operation: .directory, path: root.path, scope: scope, directoryCursor: .init())
        let content = AskFileReader(inventory: inventory)
        var found = Set<String>()
        repeat {
            let page = try content.read(request)
            found.formUnion(page.entries.map(\.path))
            #expect(page.entries.count <= 128)
            if let cursor = page.directoryCursor { #expect(cursor.session == cached.id) }
            request.directoryCursor = page.directoryCursor
        } while request.directoryCursor != nil
        #expect(found == Set(all.entries.map(\.path)))
        try Data().write(to: root.appendingPathComponent("new.txt"))
        request.directoryCursor = .init()
        let fresh = try content.read(request)
        #expect(fresh.directoryCursor?.session != cached.id)
        #expect(inventory.listing(path: root.path, scope: scope) == nil)
        var current = Set(fresh.entries.map(\.path)); request.directoryCursor = fresh.directoryCursor
        while request.directoryCursor != nil {
            let page = try content.read(request); current.formUnion(page.entries.map(\.path))
            request.directoryCursor = page.directoryCursor
        }
        #expect(current.count == 258 && current.contains(root.path + "/new.txt"))
    }

    @Test func cachedListingOnlyServesNarrowerScopesAndDoesNotCachePartialScans() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent("b.txt"))
        let inventory = AskDirectoryInventory(), original = scope(root), reader = AskFileReader(inventory: inventory)
        _ = try reader.read(.init(operation: .directory, path: root.path, scope: original, limit: 1))
        #expect(inventory.listing(path: root.path, scope: original) == nil)
        _ = try reader.read(.init(operation: .directory, path: root.path, scope: original, limit: nil))
        var narrower = original; narrower.excludedExtensions.insert("txt")
        #expect(inventory.listing(path: root.path, scope: narrower) != nil)
        #expect(try reader.read(.init(operation: .directory, path: root.path, scope: narrower,
                                     directoryCursor: .init())).entries.isEmpty)
        var broader = original; broader.includeHidden = true
        #expect(inventory.listing(path: root.path, scope: broader) == nil)
        var revoked = original; revoked.blocked = [root.path]
        #expect(inventory.listing(path: root.path, scope: revoked) == nil)
        #expect(throws: AskFileReadError.self) {
            try reader.read(.init(operation: .directory, path: root.path, scope: original, directoryCursor: .init()),
                            isCancelled: { true })
        }
    }

    @Test func cachedCallbacksRetainReaderOwnershipAndRejectReentrancyAndRetirement() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("readme.md"))
        let cache = AskDirectoryInventory(), scope = scope(root), owner = AskFileReaderOwnership()
        let reader = AskFileReader(ownership: owner, inventory: cache)
        _ = try reader.read(.init(operation: .directory, path: root.path, scope: scope, limit: nil))
        var callbacks = 0, retained = false, rejected = false
        #expect(throws: AskFileReadError.self) {
            try reader.stream(.init(operation: .directory, path: root.path, scope: scope, directoryCursor: .init())) { _ in
                callbacks += 1
                retained = owner.isOccupied
                do { _ = try reader.resolve(root.path, blocked: []) }
                catch AskFileReadError.unavailable { rejected = true }
                catch { Issue.record("Unexpected reentrant read error: \(error)") }
                reader.stop()
                return true
            }
        }
        #expect(callbacks == 1 && retained && rejected && !reader.isRunning)
    }

    @Test func inventoryEvictsOldEntriesAndRejectsOversizedDirectories() {
        let scope = scope(URL(fileURLWithPath: "/tmp/inventory"))
        let cache = AskDirectoryInventory(maximumBytes: 256)
        let a = AskDirectoryInventory.Listing(scope: scope, version: "a", entries: [])
        let b = AskDirectoryInventory.Listing(scope: scope, version: "b", entries: [])
        cache.store(path: "a", listing: a); cache.store(path: "b", listing: b)
        #expect(cache.listing(path: "a", scope: scope)?.version == "a")
        cache.store(path: "c", listing: .init(scope: scope, version: "c", entries: []))
        #expect(cache.listing(path: "b", scope: scope) == nil)
        cache.invalidate(path: "a", id: "stale")
        #expect(cache.listing(path: "a", scope: scope) != nil)
        cache.invalidate(path: "a", id: a.id)
        #expect(cache.listing(path: "a", scope: scope) == nil)
        cache.store(path: "huge", listing: .init(scope: scope, version: "huge", entries: [
            .init(path: String(repeating: "x", count: 512), kind: .file, modified: .distantPast)
        ]))
        #expect(cache.listing(path: "huge", scope: scope) == nil)
    }

    @Test func cachedDiscoveryPreservesSkippedMountAccounting() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = scope(root), inventory = AskDirectoryInventory(), reader = AskFileReader(inventory: inventory)
        let version = try #require(reader.read(.init(operation: .directoryVersion, path: root.path, scope: scope)).version)
        inventory.store(path: root.path, listing: .init(scope: scope, version: version, entries: [],
                                                        skippedMounts: [root.path + "/Remote"]))
        let page = try reader.read(.init(operation: .directory, path: root.path, scope: scope, directoryCursor: .init()))
        #expect(page.skippedMounts == [root.path + "/Remote"])
        #expect(page.entries.isEmpty && page.directoryCursor == nil)
    }

    @Test func progressRemainsFrequentWithoutCopyingTheGrowingTablesAtEveryTick() {
        var publication = AskFileBuildPublication(now: 0)
        #expect(publication.update(found: 100, now: 0.1) == .none)
        #expect(publication.update(found: 1000, now: 0.25) == .snapshot)
        #expect(publication.update(found: 2000, now: 0.5) == .progress)
        #expect(publication.update(found: 3000, now: 0.75) == .progress)
        #expect(publication.update(found: 21000, now: 0.8) == .snapshot)
        #expect(publication.update(found: 22000, now: 2.9) == .snapshot)
    }
}
