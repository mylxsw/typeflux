import Foundation
import Testing
@testable import Typeflux

@Suite("Ask file index state")
struct AskFileIndexStateTests {
    private let index = AskTestFileIndex.sample

    private func names(_ query: String, limit: Int = 10, type: AskFileType = .all) -> [String] {
        index.search(AskSearchQuery(query), options: AskFileSearchOptions(limit: limit, type: type)).map(\.name)
    }

    @Test func findsByNamePinyinAndInitials() {
        #expect(names("readme").first == "README.md")
        #expect(names("合同").prefix(3).contains("合同台账.xlsx"))
        #expect(names("ht").contains("2026 年度采购合同.pdf"), "pinyin initials from a later character")
        #expect(names("hetong").first == "合同", "the folder's whole pinyin wins")
        #expect(names("zhoubao").count == 3, "the folder and both reports")
        #expect(names("invoice").count == 2)
        #expect(names("zzzz").isEmpty)
        #expect(names("").isEmpty)
        #expect(index.search(AskSearchQuery("readme"), options: AskFileSearchOptions(limit: 0)).isEmpty)
    }

    @Test func wordsCanMatchTheFolder() {
        #expect(Set(names("typeflux md")) == ["README.md", "usage.md", "内容搜索方案.md"],
                "typeflux names a folder anywhere in the path, md the files")
        #expect(names("typeflux readme") == ["README.md"])
        #expect(names("asr readme") == ["README.md"])
        #expect(names("nothing readme").isEmpty, "every word must match somewhere")
    }

    @Test func filtersByExtensionFolderAndType() {
        #expect(names("invoice .pdf").count == 2)
        #expect(names(".pdf").count == 3, "a filter alone lists everything of that kind")
        #expect(names("readme in:asr") == ["README.md"])
        #expect(names("readme in:typeflux") == ["README.md"])
        #expect(names("invoice", type: .pdf).count == 2)
        #expect(names("invoice", type: .image).isEmpty)
        #expect(names("合同", type: .folder) == ["合同"])
        #expect(names("img", type: .image) == ["IMG_2041.HEIC"])
        #expect(names("rounded", type: .sheet) == ["Rounded Report.key"], "a Keynote package counts as a file")
    }

    @Test func recentChangesAndOpensRankHigher() throws {
        // The two invoices differ only in age: the newer one leads.
        let hits = index.search(AskSearchQuery("invoice"), options: AskFileSearchOptions(limit: 2))
        #expect(hits.first?.name == "invoice-2026-09.pdf")
        let older = try #require(hits.last)
        #expect(older.match == AskFuzzyMatcher.prefix)
        let usage = AskTestFileIndex.sample
        usage.usage = [older.path: 10]
        #expect(usage.search(AskSearchQuery("invoice"), options: AskFileSearchOptions(limit: 2)).first?.path == older.path)
        let newest = index.search(AskSearchQuery("invoice"), options: AskFileSearchOptions(limit: 2, order: .recent))
        #expect(newest.first?.name == "invoice-2026-09.pdf")
        #expect(AskFileIndexState.depthPenalty(100) == 0.04, "depth costs at most 0.04")
        #expect(AskFileIndexState.usageBoost(50) == 0.05)
    }

    @Test func hitsCarryHighlightsAndDetails() throws {
        let hit = try #require(index.search(AskSearchQuery("ht"), options: AskFileSearchOptions(limit: 10))
            .first { $0.name == "2026 年度采购合同.pdf" })
        #expect(hit.highlights == [9 ..< 11])
        #expect(hit.kind == .file && !hit.isFolder)
        #expect(hit.folder == "/Users/test/Documents/合同")
        #expect(hit.url.path == hit.path)
        let words = try #require(index.search(AskSearchQuery("typeflux readme"), options: AskFileSearchOptions()).first)
        #expect(words.highlights == [0 ..< 6])
        #expect(words.match == (AskFuzzyMatcher.exact + AskFileIndexState.pathScore) / 2)
    }

    @Test func recentListsFilesNewestFirst() {
        let recent = index.recent(options: AskFileSearchOptions(limit: 3))
        #expect(recent.first?.name == "内容搜索方案.md")
        #expect(recent.count == 3)
        #expect(!recent.contains { $0.isFolder })
        #expect(index.recent(options: AskFileSearchOptions(limit: 5, type: .pdf)).count == 3)
    }

    @Test func removingAndCompacting() throws {
        var state = AskTestFileIndex.state([("/a/b/one.txt", .file, 1), ("/a/b/two.txt", .file, 1),
                                            ("/a/c", .folder, 1), ("/a/c/three.txt", .file, 1)])
        #expect(state.count == 6, "a, b, c and the three files")
        #expect(state.record(at: "/a/b/one.txt") != nil)
        let removedFile = state.remove("/a/b/one.txt")
        #expect(removedFile)
        #expect(state.record(at: "/a/b/one.txt") == nil)
        let again = state.remove("/a/b/one.txt")
        #expect(!again, "already gone")
        let removedFolder = state.remove("/a/c")
        #expect(removedFolder, "a folder goes with what is in it")
        #expect(state.record(at: "/a/c/three.txt") == nil)
        #expect(state.count == 3)
        let compact = state.compacted()
        #expect(compact.removed == 0)
        #expect(compact.records.count == 3)
        #expect(compact.record(at: "/a/b/two.txt").map { compact.path(of: $0) } == "/a/b/two.txt")
        #expect(compact.search(AskSearchQuery("two"), options: AskFileSearchOptions()).map(\.name) == ["two.txt"])
        let folder = try #require(compact.directoryIndex["/a/b"])
        #expect(compact.directories[Int(folder)].record != AskFileDirectory.none, "the folder keeps its own entry")
        #expect(!state.needsCompaction)
    }

    @Test func theParallelScanFindsWhatAPlainLoopFinds() {
        // Enough entries for several chunks, with names that share letters.
        var entries: [(path: String, kind: AskFileRecord.Kind, days: Double)] = []
        let words = ["alpha", "beta", "gamma", "delta", "合同", "报告", "notes", "draft"]
        for number in 0 ..< 40000 {
            let word = words[number % words.count]
            entries.append(("/data/\(number % 50)/\(word)-\(number).txt", .file, Double(number % 30)))
        }
        let state = AskTestFileIndex.state(entries)
        for query in ["alpha", "ht", "dr 7", "notes 49", "gma", "baogao"] {
            let parsed = AskSearchQuery(query)
            let found = Set(state.search(parsed, options: AskFileSearchOptions(limit: 100_000)).map(\.path))
            var expected = Set<String>()
            for (index, record) in state.records.enumerated() {
                let name = state.name(of: record)
                let key = AskSearchKey(name, hasExtension: record.recordKind != .folder)
                let folder = state.directories[Int(record.directory)].key
                let whole = AskFuzzyMatcher.match(parsed.compact, key)
                let byWords = parsed.words.count > 1 && parsed.words.allSatisfy { word in
                    AskFuzzyMatcher.match(word, key) != nil || AskFileIndexState.contains(folder, word)
                }
                if whole != nil || byWords { expected.insert(state.path(of: UInt32(index))) }
            }
            #expect(found == expected, "\(query)")
        }
    }

    @Test func containsFindsBytes() {
        #expect(AskFileIndexState.contains(Array("abcdef".utf8), Array("cde".utf8)))
        #expect(!AskFileIndexState.contains(Array("abc".utf8), Array("abcd".utf8)))
        #expect(AskFileIndexState.contains(Array("abc".utf8), []))
        #expect(!AskFileIndexState.contains(Array("abc".utf8), Array("x".utf8)))
    }
}

@Suite("Ask file scope")
struct AskFileScopeTests {
    private func scope(_ change: (inout AskLauncherSearchSettings) -> Void = { _ in }, access: Bool = true) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        change(&settings)
        return AskFileScope(settings: settings, fullDiskAccess: access, home: "/Users/a")
    }

    @Test func keepsWhatIsInsideAndNotExcluded() {
        let scope = scope()
        #expect(scope.includes("/Users/a/Projects/x.swift", isDirectory: false))
        #expect(!scope.includes("/tmp/x", isDirectory: false), "outside every search folder")
        #expect(!scope.includes("/Users/a/Library/Caches/x", isDirectory: false), "an excluded path")
        #expect(!scope.includes("/Users/a/Projects/node_modules", isDirectory: true), "an excluded folder name")
        #expect(!scope.includes("/Users/a/Projects/node_modules/x.js", isDirectory: false))
        #expect(scope.includes("/Users/a/Projects/node_modules", isDirectory: false), "a file of that name is fine")
        #expect(!scope.includes("/Users/a/.ssh/config", isDirectory: false), "hidden")
        #expect(!scope.includes("/Users/a/Projects/.env", isDirectory: false))
        #expect(scope.root(of: "/Users/a/x") == "/Users/a")
    }

    @Test func aFolderAddedInsideAnExclusionWins() {
        let scope = scope { $0.fileRoots = ["~", "~/Library/Mobile Documents"] }
        #expect(scope.includes("/Users/a/Library/Mobile Documents/x.pages", isDirectory: false))
        #expect(!scope.includes("/Users/a/Library/Caches/x", isDirectory: false))
        #expect(scope.roots.first == "/Users/a/Library/Mobile Documents", "deepest first")
    }

    @Test func foldersAddedThroughALinkUseTheirRealPath() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("ask-real-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("ask-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: real) }
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [link.path]
        let scope = AskFileScope(settings: settings, fullDiskAccess: true)
        let resolved = AskFileScope.canonical(real.path)
        #expect(scope.roots == [resolved], "FSEvents reports real paths, so the index keeps them")
        #expect(resolved.hasPrefix("/private/"), "the temporary folder is itself behind a link")
        #expect(scope.includes(resolved + "/a.txt", isDirectory: false))
    }

    @Test func typesAndHiddenFollowTheSettings() {
        let scope = scope {
            $0.excludedExtensions = [".LOG"]
            $0.includeHidden = true
        }
        #expect(!scope.includes("/Users/a/x.log", isDirectory: false))
        #expect(scope.includes("/Users/a/x.log", isDirectory: true), "a folder is not a file type")
        #expect(scope.includes("/Users/a/.env", isDirectory: false))
        #expect(scope.excludedExtensions == ["log"])
    }

    @Test func guardedFoldersWaitForFullDiskAccess() {
        let guarded = scope(access: false)
        #expect(!guarded.includes("/Users/a/Documents/x.pdf", isDirectory: false))
        #expect(guarded.includes("/Users/a/Projects/x.pdf", isDirectory: false))
        #expect(guarded.blockedInScope.contains("/Users/a/Documents"))
        #expect(!guarded.blockedInScope.contains("/Volumes"), "not searched, so nothing to unlock")
        let open = scope(access: true)
        #expect(open.includes("/Users/a/Documents/x.pdf", isDirectory: false))
        #expect(open.blockedInScope.isEmpty)
        #expect(AskFileScope.isInside("/a/b", "/a"))
        #expect(AskFileScope.canonical("/nowhere/at/all") == "/nowhere/at/all")
        #expect(AskFileScope.canonical("relative") == "relative")
        #expect(!AskFileScope.isInside("/ab", "/a"))
        #expect(AskFileScope.isInside("/x", "/"))
    }
}

@Suite("Ask file snapshot")
struct AskFileSnapshotTests {
    @Test func roundTripsAndRejectsDamage() throws {
        var state = AskTestFileIndex.sample.state
        _ = state.remove("/Users/test/Downloads/invoice-2026-08.pdf")
        let data = AskFileSnapshot.encode(state, fingerprint: "fp", eventID: 42)
        let contents = try #require(AskFileSnapshot.decode(data))
        #expect(contents.fingerprint == "fp")
        #expect(contents.eventID == 42)
        #expect(contents.state.count == state.count)
        #expect(contents.state.removed == 0, "saved compacted")
        let query = AskSearchQuery("ht")
        #expect(contents.state.search(query, options: AskFileSearchOptions()).map(\.path)
            == state.compacted().search(query, options: AskFileSearchOptions()).map(\.path), "pinyin is rebuilt")
        #expect(AskFileSnapshot.decode(Data()) == nil)
        #expect(AskFileSnapshot.decode(data.prefix(data.count - 1)) == nil, "cut short")
        #expect(AskFileSnapshot.decode(data + Data([0])) == nil, "trailing bytes")
        var wrongVersion = data
        wrongVersion[4] = 9
        #expect(AskFileSnapshot.decode(wrongVersion) == nil)
    }
}

@Suite("Ask file crawler and index", .serialized)
struct AskFileIndexServiceTests {
    /// A folder of files to index, its real path (FSEvents and fts report `/private/var/…`).
    private func makeTree() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ask-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(base.path))
        let files = ["Docs/Report 2026.pdf", "Docs/合同.docx", "Code/app/main.swift", "Code/node_modules/lib/index.js",
                     "Code/.git/HEAD", ".hidden.txt", "Notes.md", "Tools/Thing.app/Contents/Info.plist"]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    private func settings(_ root: URL) -> AskLauncherSearchSettings {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]
        settings.excludedPaths = []
        return settings
    }

    @Test func crawlsWhatTheScopeKeeps() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AskFileScope(settings: settings(root), fullDiskAccess: true)
        var found: [String: AskFileRecord.Kind] = [:]
        let count = AskFileCrawler.crawl(root.path, scope: scope) { entry in
            found[String(entry.path.dropFirst(root.path.count + 1))] = entry.kind
            return true
        }
        #expect(count == found.count)
        #expect(found["Docs/Report 2026.pdf"] == .file)
        #expect(found["Docs"] == .folder)
        #expect(found["Tools/Thing.app"] == .package)
        #expect(found["Tools/Thing.app/Contents"] == nil, "bundles are one entry")
        #expect(found["Code/node_modules"] == nil && found["Code/node_modules/lib/index.js"] == nil)
        #expect(found["Code/.git"] == nil && found[".hidden.txt"] == nil)
        var stopped = 0
        AskFileCrawler.crawl(root.path, scope: scope) { _ in stopped += 1; return false }
        #expect(stopped == 1, "visit can stop the walk")
        #expect(AskFileCrawler.crawl(root.path, scope: scope, limit: 2) { _ in true } == 2)
        #expect(AskFileCrawler.crawl("/nowhere", scope: scope) { _ in true } == 0)
        #expect(AskFileCrawler.entry(at: root.appendingPathComponent("Notes.md").path, scope: scope)?.kind == .file)
        #expect(AskFileCrawler.entry(at: root.appendingPathComponent("missing").path, scope: scope) == nil)
        #expect(AskFileCrawler.isPackage("/x/Thing.app"))
        #expect(!AskFileCrawler.isPackage("/x/folder"))
    }

    private func makeIndex(_ root: URL, snapshot: URL, enabled: Bool = true, watcher: AskTestFileWatcher,
                           settings: AskLauncherSearchSettings? = nil, defaults: UserDefaults = .standard) -> AskFileIndex {
        let current = settings ?? self.settings(root)
        return AskFileIndex(configuration: { (enabled, current) }, fullDiskAccess: { true }, snapshotURL: snapshot,
                            defaults: defaults, home: root.path, makeWatcher: { watcher })
    }

    @Test func buildsWatchesAndFollowsChanges() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("index.bin")
        let watcher = AskTestFileWatcher()
        let index = makeIndex(root, snapshot: snapshot, watcher: watcher)
        #expect(index.status.phase == .off)
        index.start()
        index.waitUntilIdle()
        #expect(index.status.phase == .ready)
        #expect(index.status.count > 5)
        #expect(index.status.bytes > 0)
        #expect(watcher.paths == [root.path])
        #expect(FileManager.default.fileExists(atPath: snapshot.path), "saved after building")
        #expect(index.search(AskSearchQuery("report"), options: AskFileSearchOptions()).first?.name == "Report 2026.pdf")
        #expect(index.search(AskSearchQuery("ht"), options: AskFileSearchOptions()).first?.name == "合同.docx")
        #expect(index.recent(options: AskFileSearchOptions(limit: 50)).count >= 4)

        // A new file, a renamed one and a deleted one.
        let added = root.appendingPathComponent("Docs/Budget.numbers")
        try Data().write(to: added)
        let old = root.appendingPathComponent("Notes.md"), renamed = root.appendingPathComponent("Ideas.md")
        try FileManager.default.moveItem(at: old, to: renamed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Docs/合同.docx"))
        let moved = root.appendingPathComponent("Moved/Deep")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try Data().write(to: moved.appendingPathComponent("inside.txt"))
        watcher.send([AskFileChange(path: added.path, rescan: false), AskFileChange(path: old.path, rescan: false),
                      AskFileChange(path: renamed.path, rescan: false),
                      AskFileChange(path: root.appendingPathComponent("Docs/合同.docx").path, rescan: false),
                      AskFileChange(path: moved.path, rescan: false),
                      AskFileChange(path: "/elsewhere/x", rescan: false)], id: 7)
        index.waitUntilIdle()
        let search = { (text: String) in index.search(AskSearchQuery(text), options: AskFileSearchOptions()).map(\.name) }
        #expect(search("budget") == ["Budget.numbers"])
        #expect(search("ideas") == ["Ideas.md"])
        #expect(search("notes").isEmpty)
        #expect(search("合同").isEmpty)
        #expect(search("inside") == ["inside.txt"], "a folder moved in brings what is in it")
        #expect(search("deep") == ["Deep"])

        // Dropped events: the folder is read again.
        try Data().write(to: root.appendingPathComponent("Docs/Late.txt"))
        watcher.send([AskFileChange(path: root.appendingPathComponent("Docs").path, rescan: true)], id: 9)
        index.waitUntilIdle()
        #expect(search("late") == ["Late.txt"])
        #expect(search("report") == ["Report 2026.pdf"], "still there after the rescan")

        index.forget(root.appendingPathComponent("Ideas.md").path)
        index.waitUntilIdle()
        #expect(search("ideas").isEmpty)

        // Events dropped for the search folder itself: everything is read again, nothing is lost.
        try Data().write(to: root.appendingPathComponent("AfterDrop.txt"))
        watcher.send([AskFileChange(path: root.path, rescan: true)], id: 11)
        index.waitUntilIdle()
        #expect(search("afterdrop") == ["AfterDrop.txt"])
        #expect(search("report") == ["Report 2026.pdf"])
        #expect(search("inside") == ["inside.txt"])
        // A plain change on the folder itself (its date) changes nothing.
        watcher.send([AskFileChange(path: root.path, rescan: false)], id: 12)
        index.waitUntilIdle()
        #expect(search("report") == ["Report 2026.pdf"])
    }

    @Test func reloadsTheSnapshotAndRebuildsWhenSettingsChange() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("index.bin")
        let first = makeIndex(root, snapshot: snapshot, watcher: AskTestFileWatcher())
        first.start()
        first.waitUntilIdle()
        let count = first.status.count

        // A file added while "Typeflux was not running" is not in the snapshot; the loaded index
        // starts watching from the saved event id instead of scanning.
        try Data().write(to: root.appendingPathComponent("Offline.txt"))
        let watcher = AskTestFileWatcher()
        let second = makeIndex(root, snapshot: snapshot, watcher: watcher)
        second.start()
        second.waitUntilIdle()
        #expect(second.status.phase == .ready)
        #expect(second.status.count == count, "loaded, not scanned")
        #expect(watcher.since != nil)
        #expect(second.search(AskSearchQuery("offline"), options: AskFileSearchOptions()).isEmpty)
        second.start()
        second.waitUntilIdle()
        #expect(watcher.stopped == 0, "starting again with the same settings does nothing")

        // Other settings: built again.
        var hidden = settings(root)
        hidden.includeHidden = true
        let third = makeIndex(root, snapshot: snapshot, watcher: AskTestFileWatcher(), settings: hidden)
        third.start()
        third.waitUntilIdle()
        #expect(third.search(AskSearchQuery("hidden"), options: AskFileSearchOptions()).first?.name == ".hidden.txt")
        #expect(third.search(AskSearchQuery("offline"), options: AskFileSearchOptions()).first?.name == "Offline.txt")

        third.rebuild()
        third.waitUntilIdle()
        #expect(third.status.phase == .ready)
        third.clear()
        third.waitUntilIdle()
        #expect(third.status.phase == .off)
        #expect(third.status.count == 0)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path), "clearing deletes the saved index")
        #expect(third.search(AskSearchQuery("report"), options: AskFileSearchOptions()).isEmpty)
    }

    @Test func turnedOffItKeepsNothing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("index.bin")
        let index = makeIndex(root, snapshot: snapshot, enabled: false, watcher: AskTestFileWatcher())
        index.start()
        index.waitUntilIdle()
        #expect(index.status.phase == .off)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        index.rebuild()
        index.waitUntilIdle()
        #expect(index.status.phase == .off, "rebuild does nothing while off")
    }

    @Test func remembersWhatWasOpened() throws {
        let suite = "ask-files-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
        let index = makeIndex(root, snapshot: root.appendingPathComponent("unused.bin"), enabled: false,
                              watcher: AskTestFileWatcher(), defaults: defaults)
        index.recordOpen("/a")
        index.recordOpen("/a")
        #expect(index.usage["/a"] == 2)
        #expect((defaults.dictionary(forKey: "ask.quickResults.fileOpens") as? [String: Int])?["/a"] == 2)
        for number in 0 ... AskFileIndex.maximumUsage { index.recordOpen("/f\(number)") }
        #expect(index.usage.count == AskFileIndex.maximumUsage, "the least opened make room")
        #expect(index.usage["/a"] == 2)
    }

    @Test func statusReportsProgress() {
        var status = AskFileIndexStatus(phase: .building(found: 50, estimate: 100))
        #expect(status.progress == 0.5)
        #expect(status.isBuilding)
        status.phase = .building(found: 500, estimate: 100)
        #expect(status.progress == 0.99, "never claims to be done while building")
        status.phase = .building(found: 5, estimate: nil)
        #expect(status.progress == nil)
        status.phase = .ready
        #expect(!status.isBuilding && status.progress == nil)
        #expect(AskFullDiskAccess.isGranted(home: "/nonexistent") == false)
    }
}
