import Darwin
@testable import Typeflux
import XCTest

final class AskProjectWorkspaceTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: AskProjectWorkspace!
    private let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
    private var roots: [String] {
        [root.path]
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        store = AskProjectWorkspace(storageURL: base.appendingPathComponent("private"))
        try put("docs/file.txt", "already dirty\nlast line")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: base)
    }

    private func put(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path), options: .atomic)
    }

    private func open() throws -> AskWorkspaceRef {
        try store
            .open(root: root.path, scope: scope, authorizedRoots: roots)
    }

    private func read(_ ref: AskWorkspaceRef, _ path: String = "docs/file.txt") throws -> AskProjectRead {
        try store.read(ref.id, path: path, scope: scope, authorizedRoots: roots)
    }

    @discardableResult private func write(_ ref: AskWorkspaceRef, _ text: String,
                                          path: String = "docs/file.txt") throws -> AskWorkspaceRef {
        try store.write(ref.id, path: path, expectedVersion: read(ref, path).version,
                        content: text, scope: scope, authorizedRoots: roots)
    }

    func testChangesAreIsolatedPersistedReviewedAndReverted() throws {
        let original = try Data(contentsOf: root.appendingPathComponent("docs/file.txt"))
        var ref = try open()
        let first = try read(ref)
        XCTAssertTrue(first.exists)
        XCTAssertTrue(first.text.contains("already dirty"))
        ref = try store.write(ref.id, path: "docs/file.txt", expectedVersion: first.version,
                              content: nil, old: "already dirty", new: "task edit", scope: scope,
                              authorizedRoots: roots)
        XCTAssertNotEqual(try read(ref).version, first.version)
        XCTAssertTrue(try read(ref).text.contains("task edit"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("docs/file.txt")), original)
        let review = try store.review(ref.id, scope: scope, authorizedRoots: roots)
        XCTAssertEqual(review.workspace, ref)
        XCTAssertEqual(review.files, ["docs/file.txt"])
        XCTAssertTrue(review.patch.contains("-already dirty\n"))
        XCTAssertTrue(review.patch.contains("+task edit\n"))
        XCTAssertFalse(review.truncated)
        let patch = try store.export(ref, scope: scope, authorizedRoots: roots)
        XCTAssertEqual(AskToolPolicy.digest(patch), review.patchHash)
        store = AskProjectWorkspace(storageURL: store.storageURL)
        XCTAssertEqual(try open(), ref)
        XCTAssertEqual(try store.export(ref, scope: scope, authorizedRoots: roots), patch)
        let reverted = try store.revert(ref.id, expectedVersion: ref.version, scope: scope, authorizedRoots: roots)
        XCTAssertNotEqual(reverted.version, ref.version)
        XCTAssertEqual(try store.export(reverted, scope: scope, authorizedRoots: roots), Data())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("docs/file.txt")), original)
        XCTAssertThrowsError(try store.export(ref, scope: scope, authorizedRoots: roots))
    }

    func testUnicodeByteBudgetAliasesAndStagedDirectoryListing() throws {
        var ref = try open()
        ref = try write(ref, "new", path: "new/sub/file.txt")
        XCTAssertEqual(try store.list(ref.id, path: "new", scope: scope, authorizedRoots: roots), ["sub"])
        XCTAssertEqual(try store.list(ref.id, path: "new/sub", scope: scope, authorizedRoots: roots), ["file.txt"])
        XCTAssertThrowsError(try write(ref, "other", path: "NEW/sub/file.txt"))
        XCTAssertThrowsError(try read(ref, String(repeating: "x", count: 256)))
        XCTAssertThrowsError(try read(ref, String(repeating: "part/", count: 220) + "file"))
        let combining = "a" + String(repeating: "\u{0301}", count: 50000)
        XCTAssertEqual(combining.count, 1)
        try put("combining.txt", combining)
        let page = try read(ref, "combining.txt")
        XCTAssertTrue(page.truncatedLine)
        XCTAssertLessThan(page.text.utf8.count, 24010)
        XCTAssertFalse(page.text.contains("\u{fffd}"))
        XCTAssertEqual(AskProjectFileAccess.preview("😀", maximumBytes: 3), "")
        XCTAssertEqual(AskProjectFileAccess.preview("中a", maximumBytes: 3), "中")
        XCTAssertEqual(AskProjectFileAccess.preview("text", maximumBytes: -1), "")
        ref = try write(ref, combining, path: "new/combining.txt")
        let review = try store.review(ref.id, scope: scope, authorizedRoots: roots)
        XCTAssertTrue(review.truncated)
        XCTAssertLessThanOrEqual(review.patch.utf8.count, 24000)
        XCTAssertFalse(review.patch.contains("\u{fffd}"))
    }

    func testSnapshotConsumerGetsStagedBytesAndDetectsConcurrentMutation() throws {
        let ref = try write(open(), "staged content")
        let captured = try store.withValidatedSnapshot(ref, scope: scope, authorizedRoots: roots) { state, access in
            let secondStore = AskProjectWorkspace(storageURL: self.store.storageURL)
            XCTAssertThrowsError(try secondStore.revert(ref.id, expectedVersion: ref.version,
                                                        scope: self.scope, authorizedRoots: self.roots))
            XCTAssertEqual(state.workspace, ref)
            XCTAssertEqual(state.entries.first?.updated, Data("staged content".utf8))
            return try access.snapshot("docs/file.txt").data
        }
        XCTAssertEqual(captured, Data("already dirty\nlast line".utf8))
        XCTAssertThrowsError(try store.withValidatedSnapshot(ref, scope: scope, authorizedRoots: roots) { _, _ in
            try self.put("docs/file.txt", "updated during snapshot")
        })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/file.txt")), "updated during snapshot")
    }

    func testManifestCorruptionOrSymlinkCannotAuthorizeAWrite() throws {
        let ref = try write(open(), "task content")
        let manifest = store.storageURL.appendingPathComponent(ref.id).appendingPathComponent("changes.json")
        let saved = try Data(contentsOf: manifest)
        var damaged = try JSONDecoder().decode(AskProjectChangeSet.self, from: saved)
        damaged.entries[0].updated = Data([0xFF])
        try JSONEncoder().encode(damaged).write(to: manifest)
        XCTAssertThrowsError(try store.export(ref, scope: scope, authorizedRoots: roots))
        try saved.write(to: manifest)
        let external = base.appendingPathComponent("external.json")
        try saved.write(to: external)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: external)
        XCTAssertThrowsError(try read(ref))
        XCTAssertThrowsError(try write(ref, "bad"))
        XCTAssertEqual(try Data(contentsOf: external), saved)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/file.txt")), "already dirty\nlast line")
    }

    func testConcurrentUserChangesCauseConflictsWithoutOverwrite() throws {
        let ref = try open(), version = try read(open()).version
        try put("docs/file.txt", "user changed\n")
        XCTAssertThrowsError(try store.write(ref.id, path: "docs/file.txt", expectedVersion: version, content: "lost",
                                             scope: scope, authorizedRoots: roots))
        let edited = try write(ref, "staged")
        try put("docs/file.txt", "user changed again")
        XCTAssertThrowsError(try read(edited))
        XCTAssertThrowsError(try store.review(edited.id, scope: scope, authorizedRoots: roots))
        XCTAssertThrowsError(try store.export(edited, scope: scope, authorizedRoots: roots))
        XCTAssertThrowsError(try store.revert(edited.id, expectedVersion: "old", scope: scope, authorizedRoots: roots))
        let reverted = try store.revert(
            edited.id,
            expectedVersion: edited.version,
            scope: scope,
            authorizedRoots: roots
        )
        XCTAssertTrue(try read(reverted).text.contains("user changed again"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/file.txt")), "user changed again")
    }

    func testNewFilesAndRepeatedEditsKeepMissingBaseline() throws {
        var ref = try open()
        let path = "new/sub/file.txt"
        XCTAssertFalse(try read(ref, path).exists)
        XCTAssertEqual(try read(ref, path).version, "missing")
        ref = try write(ref, "first", path: path)
        let stale = try read(ref, path).version
        ref = try write(ref, "second\n", path: path)
        XCTAssertThrowsError(try store.write(ref.id, path: path, expectedVersion: stale, content: "stale",
                                             scope: scope, authorizedRoots: roots))
        let patch = try String(decoding: store.export(ref, scope: scope, authorizedRoots: roots), as: UTF8.self)
        XCTAssertTrue(patch.contains("new file mode 100644\n--- /dev/null"))
        XCTAssertTrue(patch.contains("+second\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        XCTAssertTrue(try store.list(ref.id, path: ".", scope: scope, authorizedRoots: roots).contains("new"))
        XCTAssertTrue(try store.list(ref.id, path: "docs", scope: scope, authorizedRoots: roots).contains("file.txt"))
    }

    func testOwnershipRevocationAndRootReplacement() throws {
        let ref = try open()
        for other in [AskProjectScope(ownerId: "other", conversationId: "conversation", runId: "run"),
                      AskProjectScope(ownerId: "owner", conversationId: "other", runId: "run"),
                      AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "other")] {
            XCTAssertThrowsError(try store.read(ref.id, path: "docs/file.txt", scope: other, authorizedRoots: roots))
            XCTAssertNotEqual(try store.open(root: root.path, scope: other, authorizedRoots: roots).id, ref.id)
        }
        XCTAssertThrowsError(try store.open(root: root.path, scope: scope, authorizedRoots: []))
        XCTAssertThrowsError(try store.read(ref.id, path: "docs/file.txt", scope: scope, authorizedRoots: []))
        XCTAssertThrowsError(try store.export(ref, scope: scope, authorizedRoots: []))
        XCTAssertThrowsError(try store.open(
            root: root.path,
            scope: .init(ownerId: "", conversationId: "c", runId: "r"),
            authorizedRoots: roots
        ))
        XCTAssertThrowsError(try store.open(root: base.path, scope: scope, authorizedRoots: [base.path]))
        XCTAssertThrowsError(try store.read("../escape", path: "x", scope: scope, authorizedRoots: roots))
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try read(ref))
        XCTAssertNotEqual(try open().id, ref.id)
    }

    func testRejectsSymlinksHardlinksSpecialFilesAndTraversal() throws {
        let ref = try open()
        let outside = base.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"), withDestinationURL: base)
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("hard"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        for path in ["../outside", "/etc/hosts", "docs/../file.txt", "docs//file.txt", ".git/config", ".GIT/config",
                     "docs/", "", "bad\0name", "bad\nname", "link", "dir/outside", "hard", "pipe"] {
            XCTAssertThrowsError(try read(ref, path), path)
            XCTAssertThrowsError(try write(ref, "overwrite", path: path), path)
        }
        XCTAssertEqual(try String(contentsOf: outside), "secret")
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try store.open(root: alias.path, scope: scope, authorizedRoots: [alias.path]))
    }

    func testDescriptorRevalidationDetectsReplacementDuringRead() throws {
        let directory = try AskSecureDirectory.openRoot(root, create: false, privateRoot: false)
        let original = root.appendingPathComponent("docs/file.txt")
        var access = AskProjectFileAccess(directory: directory)
        access.afterOpen = { try self.put("docs/file.txt", "replacement") }
        XCTAssertThrowsError(try access.snapshot("docs/file.txt"))
        access.afterOpen = {
            try FileManager.default.moveItem(
                at: self.root.appendingPathComponent("docs"),
                to: self.base.appendingPathComponent("moved")
            )
            try FileManager.default.createSymbolicLink(
                at: self.root.appendingPathComponent("docs"),
                withDestinationURL: self.base
            )
        }
        XCTAssertThrowsError(try access.snapshot("docs/file.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("moved/file.txt")), "replacement")
    }

    func testPagingEncodingAndBounds() throws {
        let ref = try open()
        try put("large.txt", (0 ..< 300_000).map { "line \($0)" }.joined(separator: "\n"))
        let page = try store.read(
            ref.id,
            path: "large.txt",
            offset: 290_000,
            limit: 2,
            scope: scope,
            authorizedRoots: roots
        )
        XCTAssertEqual(page.text, "290001\tline 290000\n290002\tline 290001\n")
        XCTAssertEqual(page.nextOffset, 290_002)
        let huge = try store.read(
            ref.id,
            path: "large.txt",
            offset: 299_999,
            limit: Int.max,
            scope: scope,
            authorizedRoots: roots
        )
        XCTAssertNil(huge.nextOffset)
        let beyond = try store.read(
            ref.id,
            path: "large.txt",
            offset: Int.max,
            limit: Int.max,
            scope: scope,
            authorizedRoots: roots
        )
        XCTAssertEqual(beyond.text, "")
        XCTAssertNil(beyond.nextOffset)
        XCTAssertTrue(try store.read(
            ref.id,
            path: "large.txt",
            offset: Int.min,
            limit: Int.min,
            scope: scope,
            authorizedRoots: roots
        ).text.hasPrefix("1\t"))
        let bounded = try store.read(ref.id, path: "large.txt", limit: Int.max, scope: scope, authorizedRoots: roots)
        XCTAssertNotNil(bounded.nextOffset)
        try put("long.txt", String(repeating: "中", count: 25000))
        XCTAssertTrue(try read(ref, "long.txt").truncatedLine)
        for (name, data) in [
            ("binary", Data(repeating: 65, count: 9000) + Data([0])),
            ("encoding", Data([0xFF, 0xFE, 0x31]))
        ] {
            try data.write(to: root.appendingPathComponent(name))
            XCTAssertThrowsError(try read(ref, name))
        }
        try Data(repeating: 65, count: AskProjectFileAccess.maximumReadBytes + 1)
            .write(to: root.appendingPathComponent("oversize"))
        XCTAssertThrowsError(try read(ref, "oversize"))
        XCTAssertThrowsError(try write(ref, String(repeating: "x", count: AskFileTools.maximumWriteBytes + 1)))
        XCTAssertThrowsError(try write(ref, "binary\0"))
    }

    func testNoOpEditValidationChangeBudgetAndReviewTruncation() throws {
        var ref = try open()
        XCTAssertThrowsError(try store.write(ref.id, path: "docs/file.txt", expectedVersion: read(ref).version,
                                             content: nil, old: "missing", new: "x", scope: scope,
                                             authorizedRoots: roots))
        ref = try write(ref, "staged")
        ref = try write(ref, "already dirty\nlast line")
        XCTAssertTrue(try store.review(ref.id, scope: scope, authorizedRoots: roots).files.isEmpty)
        for index in 0 ..< 4 {
            ref = try write(ref, String(repeating: "x", count: 1_000_000), path: "large\(index)")
        }
        XCTAssertThrowsError(try write(ref, String(repeating: "x", count: 1_000_000), path: "overbudget"))
        let review = try store.review(ref.id, scope: scope, authorizedRoots: roots)
        XCTAssertTrue(review.truncated)
        XCTAssertEqual(review.patch.count, 24000)
        XCTAssertGreaterThan(try store.export(ref, scope: scope, authorizedRoots: roots).count, 4_000_000)
        let json = try String(decoding: JSONEncoder().encode(review), as: UTF8.self)
        XCTAssertEqual(AskProjectReview.decode(json), review)
        XCTAssertNil(AskProjectReview.decode("{}"))
        XCTAssertNil(AskProjectReview.decode(json.replacingOccurrences(of: "project_review_v1", with: "unknown")))
    }

    func testPatchAppliesExactlyToDirtyGitWorkingTreeAndQuotedPaths() throws {
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
        }
        try git(["init", "-q"])
        try put("docs/file.txt", "committed\n")
        try git(["add", "."])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"])
        try put("docs/file.txt", "already dirty\nlast line")
        try put("untouched.txt", "untracked user data")
        var ref = try open()
        ref = try write(ref, "task version\n")
        ref = try write(ref, "new content", path: "space 中文 \"quote\".txt")
        ref = try write(ref, "", path: "empty.txt")
        let patch = base.appendingPathComponent("changes.patch")
        try store.export(ref, scope: scope, authorizedRoots: roots).write(to: patch)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/file.txt")), "already dirty\nlast line")
        try git(["apply", "--check", patch.path])
        try git(["apply", patch.path])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/file.txt")), "task version\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("space 中文 \"quote\".txt")), "new content")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("untouched.txt")), "untracked user data")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("empty.txt")), Data())
    }
}
