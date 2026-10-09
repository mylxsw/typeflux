import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite("Streaming file reads", .serialized)
struct AskFileStreamingTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("file-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: AskFileScope.canonical(url.path))
    }

    private func scope(_ root: URL) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root.path]
        settings.excludedPaths = []
        return AskFileScope(settings: settings, fullDiskAccess: true, home: root.path)
    }

    @Test func tenThousandSlowButAdvancingEntriesSurviveTheIdleDeadline() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0 ..< 10050 { FileManager.default.createFile(atPath: root.path + "/item-\(number)", contents: Data()) }
        let frames = root.appendingPathComponent(".frames")
        var encoded = Data()
        var batches = 0
        try AskFileWorkerCommand.stream(.init(operation: .directory, path: root.path, scope: scope(root))) { response in
            #expect(response.entries.count <= 128)
            batches += 1
            encoded += try JSONEncoder().encode(response) + Data([10])
        }
        try encoded.write(to: frames)
        #expect(batches > 75)
        // Replay real production frames slowly over a real pipe. Total time exceeds the idle deadline.
        let script = "read request; while IFS= read -r frame; do printf '%s\\n' \"$frame\"; /bin/sleep 0.04; done < \"$1\""
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script, "slow-reader", frames.path], timeout: 1, startupTimeout: 30)
        var names = Set<String>()
        var skips = 0
        let started = Date()
        AskFileCrawler.crawl(root.path, scope: scope(root), reader: reader, skipped: { _, _ in skips += 1 }) {
            names.insert(($0.path as NSString).lastPathComponent)
            return true
        }
        #expect(Date().timeIntervalSince(started) > 1)
        #expect(skips == 0)
        #expect(names == Set((0 ..< 10050).map { "item-\($0)" }))
    }

    @Test func fourStalledDirectoriesDoNotConsumeTheirHealthySiblingsBudget() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ["healthy", "hang-1", "hang-2", "hang-3", "hang-4"]
        let entries = directories.map {
            AskFileCrawler.Entry(path: root.path + "/" + $0, kind: .folder, modified: Date())
        }
        let first = root.appendingPathComponent("root.json"), last = root.appendingPathComponent("healthy.json")
        try (JSONEncoder().encode(AskFileReadResponse(entries: entries)) + Data([10])).write(to: first)
        let leaf = AskFileCrawler.Entry(path: root.path + "/healthy/readme.md", kind: .file, modified: Date())
        try (JSONEncoder().encode(AskFileReadResponse(entries: [leaf])) + Data([10])).write(to: last)
        // exec confines the deliberate stall to the supervised PID, even after repeated restarts.
        let script = "while IFS= read -r request; do case \"$request\" in *hang-*) exec /bin/sleep 60 ;; "
            + "*healthy*) /bin/cat \"$2\" ;; *) /bin/cat \"$1\" ;; esac; done"
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script, "stalled-reader", first.path, last.path], timeout: 1)
        var skipped: [String: AskFileCrawler.SkipReason] = [:]
        var found = Set<String>()
        AskFileCrawler.crawl(root.path, scope: scope(root), reader: reader, skipped: { skipped[$0] = $1 }) {
            found.insert($0.path)
            return true
        }
        #expect(skipped.count == 4 && skipped.values.allSatisfy { $0 == .timeout })
        #expect(found.contains(leaf.path))
    }

    @Test func partialBatchesSurviveAStallAndEarlyStopResetsTheConnection() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = AskFileReadResponse(entries: [.init(path: root.path + "/readme.md", kind: .file, modified: Date())], more: true)
        let data = root.appendingPathComponent("frame.json")
        try (JSONEncoder().encode(frame) + Data([10])).write(to: data)
        let script = "read request; /bin/cat \"$1\"; exec /bin/sleep 60"
        let reader = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", script, "partial-reader", data.path], timeout: 1)
        var found: [String] = [], skips = 0
        AskFileCrawler.crawl(root.path, scope: scope(root), reader: reader, skipped: { _, _ in skips += 1 }) {
            found.append($0.path); return true
        }
        #expect(found == [root.path + "/readme.md"] && skips == 1)
        for _ in 0 ..< 2 {
            let count = AskFileCrawler.crawl(root.path, scope: scope(root), reader: reader) { _ in false }
            #expect(count == 1, "early stop discards pending frames before the next request")
        }
    }

    @Test func mountPolicyFiltersBeforeOpeningOrStattingTheTarget() throws {
        #expect(AskFileMounts.shouldSkip(type: "nfs", flags: 0))
        #expect(AskFileMounts.shouldSkip(type: "smbfs", flags: 0))
        #expect(AskFileMounts.shouldSkip(type: "macfuse", flags: UInt32(MNT_LOCAL)))
        #expect(AskFileMounts.shouldSkip(type: "virtiofs", flags: UInt32(MNT_LOCAL)))
        #expect(AskFileMounts.shouldSkip(type: "autofs", flags: UInt32(MNT_LOCAL)))
        #expect(!AskFileMounts.shouldSkip(type: "apfs", flags: UInt32(MNT_LOCAL)))
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mount = root.path + "/Remote"
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("local.txt"))
        let mounts = AskFileMounts(excluded: [mount])
        #expect(AskFileMounts(excluded: ["/System/Volumes/Data/Users/test/Remote"])
            .blocking("/Users/test/Remote/child") != nil)
        #expect(AskFileMounts(excluded: ["/Users/test/Remote"])
            .blocking("/System/Volumes/Data/Users/test/Remote/child") != nil)
        var entries: [String] = [], skipped: [String] = []
        try AskFileWorkerCommand.stream(.init(operation: .directory, path: root.path, scope: scope(root)), mounts: mounts) {
            entries += $0.entries.map(\.path)
            skipped += $0.skippedMounts ?? []
        }
        #expect(entries == [root.path + "/local.txt"] && skipped == [mount])
        for operation in [AskFileReadRequest.Operation.directory, .entry] {
            try AskFileWorkerCommand.stream(.init(operation: operation, path: mount + "/does-not-exist", scope: scope(root)), mounts: mounts) {
                if $0.more != true { #expect($0.skippedMounts == [mount] && $0.error == nil) }
            }
        }
        #expect(AskFileWorkerCommand.resolve(mount + "/child", blocked: [], mounts: mounts) == mount + "/child")
        let reader = AskRecordingFileReader()
        reader.respond = { _ in .init(skippedMounts: [mount]) }
        #expect(throws: AskFileReadError.self) { try AskFileCrawler.metadata(at: mount, scope: scope(root), reader: reader) }
    }

    @Test @MainActor func localizedFolderNamesAndSummariesHaveNoZeroOrPermissionNoise() throws {
        let previous = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(previous) }
        let expected = ["Desktop", "桌面", "桌面", "デスクトップ", "데스크탑"]
        for (language, desktop) in zip(AppLanguage.allCases, expected) {
            AppLocalization.shared.setLanguage(language)
            #expect(AskFileLabels.folder("~/Desktop", home: "/Users/test") == desktop)
            #expect(AskFileLabels.folder("~", home: "/Users/test") == L("ask.files.folder.home"))
            #expect(AskFileLabels.folder("/Users/test", home: "/Users/test") == L("ask.files.folder.home"))
            #expect(AskFileLabels.folder("/Users/test/Projects") == "Projects")
            #expect(AskFileLabels.skipped(.init(phase: .ready, blocked: ["/Users/test/Music"])) == nil)
            let summary = try #require(AskFileLabels.skipped(.init(phase: .ready, timedOut: 2, nonLocalMounts: 1)))
            #expect(summary.contains("2") && summary.contains("1") && !summary.contains("0"))
            #expect(!summary.contains("ask.") && !summary.contains(L("ask.files.skip.failed", "0")))
            let url = try #require(Bundle.appResources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue))
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in ["ask.plugin.files.skipped", "ask.files.skip.timeout", "ask.files.skip.failed", "ask.files.skip.mount",
                        "ask.files.folder.home", "ask.files.folder.desktop", "ask.files.folder.music", "ask.files.folder.library"] {
                #expect(table[key] != nil, "each language has its own translation, without English fallback")
            }
        }
    }
}
