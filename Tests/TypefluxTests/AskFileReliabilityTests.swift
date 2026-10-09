import Darwin
import Foundation
import Testing
@testable import Typeflux

/// Direct worker calls cover the syscall policy; separate tests exercise the actual process boundary.
final class AskRecordingFileReader: AskFileReading {
    var requests: [AskFileReadRequest] = []
    var respond: (AskFileReadRequest) throws -> AskFileReadResponse = AskFileWorkerCommand.handle

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() { throw AskFileReadError.cancelled }
        requests.append(request)
        return try respond(request)
    }
}

@Suite("File scan reliability", .serialized)
struct AskFileReliabilityTests {
    private func tree() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        for name in ["Projects/readme.md", "Music/song.txt", "Pictures/photo.txt", "Movies/video.txt",
                     "Library/Containers/private.txt", "Desktop/private.txt", "Documents/private.txt",
                     "Downloads/private.txt", "Projects/App.app/Contents/Info.plist", "Projects/.hidden", "Projects/a.log"] {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: file)
        }
        return root
    }

    private func scope(_ root: URL, access: Bool = false) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]
        settings.excludedPaths = []
        settings.excludedExtensions = ["log"]
        return AskFileScope(settings: settings, fullDiskAccess: access, home: root.path)
    }

    @Test func protectedFoldersNeverReachTheReaderIncludingExplicitRoots() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        var scope = scope(root)
        let reader = AskRecordingFileReader()
        var paths: [String] = []
        AskFileCrawler.crawl(root.path, scope: scope, reader: reader) { paths.append($0.path); return true }
        #expect(paths.contains(root.path + "/Projects/readme.md"))
        #expect(!paths.contains { $0.hasSuffix("/private.txt") || $0.hasSuffix(".log") || $0.hasSuffix(".hidden") })
        #expect(Set(scope.blockedInScope.map { ($0 as NSString).lastPathComponent })
            == ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies", "Library"])
        for folder in scope.blockedInScope {
            scope.roots.append(folder)
            #expect(AskFileCrawler.crawl(folder, scope: scope, reader: reader) { _ in true } == 0)
            #expect(AskFileCrawler.entry(at: folder + "/private.txt", scope: scope, reader: reader) == nil)
        }
        #expect(reader.requests.allSatisfy { request in !scope.blocked.contains { AskFileScope.isInside(request.path, $0) } })
        var defaultSettings = AskLauncherSearchSettings()
        let excluded = AskFileScope(settings: defaultSettings, fullDiskAccess: false, home: root.path)
        #expect(!excluded.blockedInScope.contains(root.path + "/Library"), "access does not override user exclusions")
        defaultSettings.fileRoots.append("~/Library/Containers")
        #expect(AskFileScope(settings: defaultSettings, fullDiskAccess: false, home: root.path).blockedInScope.contains(root.path + "/Library/Containers"))
    }

    @Test func workerFiltersMetadataAndDoesNotFollowAliases() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = scope(root)
        let link = root.appendingPathComponent("Projects/alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Music"))
        let reader = AskRecordingFileReader()
        #expect(try reader.resolve(link.path + "/song.txt", blocked: scope.blocked) == root.path + "/Music/song.txt")
        #expect(AskFileWorkerCommand.handle(.init(operation: .directory, path: link.path, scope: scope)).error != nil)
        #expect(AskFileWorkerCommand.handle(.init(operation: .entry, path: link.path + "/song.txt", scope: scope)).error != nil)
        #expect(AskFileWorkerCommand.handle(.init(operation: .directory, path: root.path + "/Music", scope: scope)).error == EACCES)
        #expect(AskFileWorkerCommand.handle(.init(operation: .directory, path: root.path + "/missing", scope: scope)).error != nil)
        #expect(AskFileWorkerCommand.handle(.init(operation: .entry, path: root.path + "/missing", scope: scope)).entries.isEmpty)
        #expect(AskFileWorkerCommand.handle(.init(operation: .directory, path: root.path, scope: scope, limit: 0)).entries.isEmpty)
        #expect(AskFileCrawler.entry(at: link.path, scope: scope, reader: reader)?.kind == .file)
        #expect(AskFileCrawler.entry(at: root.path + "/Projects", scope: scope, reader: reader)?.kind == .folder)
        #expect(AskFileCrawler.entry(at: root.path + "/Projects/App.app", scope: scope, reader: reader)?.kind == .package)
        #expect(AskFileScope.normalize("/a//b/.././c/") == "/a/c")
        #expect(AskFileScope.normalize("relative") == "relative")
        #expect(AskFileScope.normalize("/../../") == "/")
        var aliasSettings = AskLauncherSearchSettings()
        aliasSettings.fileRoots = ["/System/Volumes/Data/Users/test"]
        let aliasScope = AskFileScope(settings: aliasSettings, fullDiskAccess: false, home: "/Users/test")
        #expect(!aliasScope.includes("/System/Volumes/Data/Users/test/Music/song", isDirectory: false))
        #expect(!aliasScope.includes("/System/Volumes/Data/Users/test/mUsIc/song", isDirectory: false))
        aliasSettings.fileRoots = ["/Users/test/mUsIc"]
        let mixedCase = AskFileScope(settings: aliasSettings, fullDiskAccess: false, home: "/Users/test")
        #expect(!mixedCase.includes("/Users/test/mUsIc/song", isDirectory: false))
        #expect(mixedCase.blockedInScope == ["/Users/test/mUsIc"])
        #expect(aliasScope.includes("/System/Volumes/Data/Users/test/Projects/readme", isDirectory: false))
        let relative = root.appendingPathComponent("relative")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "Projects")
        #expect(try reader.resolve(relative.path, blocked: []) == root.path + "/Projects")
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        #expect(try reader.resolve(loop.path, blocked: []) == loop.path)
        #expect(try reader.resolve("/", blocked: []) == "/")
    }

    @Test func timeoutAndFailureLeaveSiblingResultsSearchable() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = scope(root, access: true)
        let reader = AskRecordingFileReader()
        reader.respond = { request in
            if request.path.hasSuffix("/Music") { throw AskFileReadError.timeout }
            if request.path.hasSuffix("/Movies") { return AskFileReadResponse(error: EACCES) }
            return AskFileWorkerCommand.handle(request)
        }
        var found: [String] = []
        var skipped: [String] = []
        AskFileCrawler.crawl(root.path, scope: scope, reader: reader, skipped: { path, _ in skipped.append(path) }) {
            found.append($0.path); return true
        }
        #expect(Set(skipped) == [root.path + "/Music", root.path + "/Movies"])
        #expect(found.contains(root.path + "/Projects/readme.md"))
        #expect(!found.contains(root.path + "/Music/song.txt"))
        #expect(AskFileCrawler.crawl(root.path, scope: scope, limit: 0, reader: reader) { _ in true } == 0)
        #expect(AskFileCrawler.crawl(root.path, scope: scope, reader: reader, isCancelled: { true }) { _ in true } == 0)
        reader.respond = { _ in throw AskFileReadError.unavailable }
        #expect(AskFileCrawler.crawl(root.path, scope: scope, reader: reader) { _ in true } == 0)
        reader.respond = { _ in throw AskFileReadError.cancelled }
        #expect(AskFileCrawler.crawl(root.path, scope: scope, reader: reader) { _ in true } == 0)
        reader.respond = { _ in throw CocoaError(.fileReadUnknown) }
        #expect(AskFileCrawler.crawl(root.path, scope: scope, reader: reader) { _ in true } == 0)
    }

    @Test func actualWorkerReusesConnectionAndHandlesLargeResponse() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = AskFileReader(timeout: 30)
        let scope = scope(root)
        #expect(try reader.resolve(root.path, blocked: []) == root.path)
        let link = root.appendingPathComponent("project-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Projects")
        #expect(try reader.resolve(link.path, blocked: []) == root.path + "/Projects")
        for number in 0 ..< 600 {
            try Data().write(to: root.appendingPathComponent("Projects/file-\(number)-long-name.txt"))
        }
        let response = try reader.read(.init(operation: .directory, path: root.path + "/Projects", scope: scope))
        #expect(response.entries.count == 602)
        #expect(response.error == nil)
        #expect(try reader.read(.init(operation: .entry, path: root.path + "/Projects/readme.md", scope: scope)).entries.count == 1)
        reader.stop()
        #expect(try reader.resolve(root.path, blocked: []) == root.path)
        #expect(throws: (any Error).self) {
            try reader.read(.init(operation: .resolve, path: root.path), isCancelled: { true })
        }
    }

    @Test func actualHungChildIsKilledAndReaderCanRestart() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pid")
        // First child hangs, the next child answers. The process exec keeps the recorded PID stable.
        let script = "if [ ! -e '\(marker.path)' ]; then echo $$ > '\(marker.path)'; exec /bin/sleep 20; fi; "
            + "while read line; do printf '{\"entries\":[],\"path\":\"/ok\"}\\n'; done"
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1)
        let start = Date()
        #expect(throws: (any Error).self) { try reader.resolve("/a", blocked: []) }
        #expect(Date().timeIntervalSince(start) < 5)
        let pid = try #require(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(try reader.resolve("/b", blocked: []) == "/ok")
        #expect(kill(pid, 0) == -1, "timed-out child was reaped")

    }

    @Test func actualCrawlerSurvivesABlockedDirectoryAndAnUnreadableSibling() throws {
        let root = try tree()
        let denied = root.appendingPathComponent("Movies")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        // Forward requests to the production worker, except one directory whose read never returns.
        // exec keeps that hung read in the supervised PID; no sleeping grandchild is left behind.
        let script = "while IFS= read -r line; do case \"$line\" in *Music*) exec /bin/sleep 60 ;; "
            + "*) printf '%s\\n' \"$line\" | \"$1\" file-index-worker ;; esac; done"
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script, "file-reader-test", AskFileReader.executableURL.path], timeout: 5, startupTimeout: 30)
        var paths: [String] = []
        var failures: [String: AskFileCrawler.SkipReason] = [:]
        let count = AskFileCrawler.crawl(root.path, scope: scope(root, access: true), reader: reader,
                                        skipped: { failures[$0] = $1 }) { paths.append($0.path); return true }
        #expect(count == paths.count && count > 0)
        #expect(paths.contains(root.path + "/Projects/readme.md"))
        #expect(failures[root.path + "/Music"] == .timeout)
        #expect(failures[denied.path] == .failed)
        #expect(failures.count == 2)
    }

    @Test func brokenWorkersFailWithoutHanging() throws {
        for (path, args) in [("/does-not-exist", []), ("/usr/bin/true", []),
                             ("/bin/sh", ["-c", "read line; printf 'not-json\\n'"])] {
            let reader = AskFileReader(executable: URL(fileURLWithPath: path), arguments: args, timeout: 0.2)
            #expect(throws: (any Error).self) { try reader.resolve("/a", blocked: []) }
        }
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 5)
        var checks = 0
        let started = Date()
        #expect(throws: (any Error).self) {
            try reader.read(.init(operation: .resolve, path: "/a"), isCancelled: { checks += 1; return checks > 3 })
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func indexPublishesPartialStateAndRebuildsPartialSnapshot() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = AskRecordingFileReader()
        reader.respond = { request in
            if request.operation == .directory, request.path.hasSuffix("/Music") { throw AskFileReadError.timeout }
            if request.operation == .directory, request.path.hasSuffix("/Movies") { return .init(error: EACCES) }
            return AskFileWorkerCommand.handle(request)
        }
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]
        settings.excludedPaths = []
        let snapshot = root.appendingPathComponent("snapshot.bin")
        let suite = "reliability-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = AskFileIndex(configuration: { (true, settings) }, fullDiskAccess: {
            #expect(!Thread.isMainThread)
            return true
        }, snapshotURL: snapshot, defaults: defaults, home: root.path, makeReader: { reader }, makeWatcher: { AskTestFileWatcher() })
        index.start()
        index.waitUntilIdle()
        #expect(index.status.phase == .ready)
        #expect(index.status.timedOut == 1 && index.status.failed == 1)
        #expect(index.search(AskSearchQuery("readme"), options: .init()).count == 1)
        let saved = try #require(AskFileSnapshot.decode(Data(contentsOf: snapshot)))
        #expect(saved.fingerprint.hasSuffix("partial"))
        reader.respond = AskFileWorkerCommand.handle
        let fresh = AskFileIndex(configuration: { (true, settings) }, fullDiskAccess: { true }, snapshotURL: snapshot,
                                 defaults: defaults, home: root.path, makeReader: { reader }, makeWatcher: { AskTestFileWatcher() })
        fresh.start()
        fresh.waitUntilIdle()
        #expect(fresh.search(AskSearchQuery("song"), options: .init()).count == 1)
        #expect(!fresh.status.incomplete)
        fresh.saveBeforeQuitting()
        fresh.waitUntilIdle()
    }

    @Test @MainActor func startingAndClearingDoNotWaitForPermissionIO() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let reader = AskRecordingFileReader()
        let index = AskFileIndex(configuration: { (true, AskLauncherSearchSettings()) }, fullDiskAccess: {
            #expect(!Thread.isMainThread)
            entered.signal()
            release.wait()
            return false
        }, snapshotURL: root.appendingPathComponent("index.bin"), home: root.path,
        makeReader: { reader }, makeWatcher: { AskTestFileWatcher() })
        for rebuild in [false, true] {
            if rebuild { index.rebuild() } else { index.start() }
            #expect(entered.wait(timeout: .now() + 2) == .success)
            index.clear()
            release.signal()
            index.waitUntilIdle()
            #expect(index.status.phase == .off)
            #expect(reader.requests.isEmpty)
        }
        // A cancelled permission check must not suppress the next start as "already current".
        release.signal()
        index.start()
        index.waitUntilIdle()
        #expect(index.status.phase == .ready)
    }

    @Test func publishesBeforeFinishingAndPreservesEntriesOnTransientMetadataFailure() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]
        let reader = AskRecordingFileReader()
        let watcher = AskTestFileWatcher()
        let index = AskFileIndex(configuration: { (true, settings) }, fullDiskAccess: { false },
                                 snapshotURL: root.appendingPathComponent("index.bin"), home: root.path,
                                 makeReader: { reader }, makeWatcher: { watcher })
        var sawPartial = false
        reader.respond = { request in
            if request.operation == .directory, request.path == root.path { Thread.sleep(forTimeInterval: 0.3) }
            if request.operation == .directory, request.path.hasSuffix("/Projects") {
                sawPartial = index.status.isBuilding && index.status.count > 0
            }
            return AskFileWorkerCommand.handle(request)
        }
        index.start()
        index.waitUntilIdle()
        #expect(sawPartial)
        let file = root.path + "/Projects/readme.md"
        reader.respond = { request in
            if request.path == file { throw AskFileReadError.timeout }
            return AskFileWorkerCommand.handle(request)
        }
        watcher.send([.init(path: file, rescan: false), .init(path: root.path + "/Music/song.txt", rescan: false)], id: 9)
        index.waitUntilIdle()
        #expect(index.search(AskSearchQuery("readme"), options: .init()).count == 1)
        #expect(index.status.timedOut == 1)
        reader.respond = { _ in AskFileReadResponse(error: EACCES) }
        watcher.send([.init(path: file, rescan: false)], id: 10)
        index.waitUntilIdle()
        #expect(index.status.failed == 1)
        #expect(index.search(AskSearchQuery("readme"), options: .init()).count == 1)
    }
}
