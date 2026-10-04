import Foundation
@testable import Typeflux
import XCTest

extension AskSkillInstallerTests {
    func testAllRequestsAfterResolutionUseTheImmutableCommit() async throws {
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("locked")),
                                      .init(path: "a #?.txt", content: "Version one")]
        _ = try await installer().install(from: "github.com/owner/repo/tree/moving-branch")
        let requests = GitHubStubProtocol.requests
        XCTAssertEqual(requests.filter { $0.path.contains("/commits/") }.count, 1)
        XCTAssertTrue(requests.contains { $0.path.hasSuffix("/commits/moving-branch") })
        for request in requests
            where request.path.contains("/git/trees/") || request.host == "raw.githubusercontent.com" {
            XCTAssertTrue(request.path.contains(GitHubStubProtocol.commit), request.absoluteString)
            XCTAssertFalse(request.path.contains("moving-branch"))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("locked/a #?.txt")), "Version one")
    }

    func testTruncatedTreeAndMutableOrInvalidCommitFailBeforeDownloading() async {
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe"))]
        GitHubStubProtocol.truncated = true
        await assertError("ask.skills.install.truncated") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.truncated = false
        GitHubStubProtocol.commitResponse = "main"
        await assertError("ask.skills.install.invalidSource") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        XCTAssertFalse(GitHubStubProtocol.requests.contains { $0.host == "raw.githubusercontent.com" })
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testRejectsLinksSubmodulesUnsafePathsAndCaseCollisions() async {
        for entry in [GitHubStubProtocol.Entry(path: "link", content: "../outside", mode: "120000"),
                      .init(path: "module", content: "", mode: "160000", type: "commit"),
                      .init(path: "../outside", content: "bad"), .init(path: "/absolute", content: "bad"),
                      .init(path: "path//double", content: "bad"), .init(path: "path/./dot", content: "bad"),
                      .init(path: "path\\file", content: "bad"), .init(path: "skill.md", content: "duplicate")] {
            GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe")), entry]
            await assertError("ask.skills.install.unsafeResource") {
                _ = try await self.installer().install(from: "github.com/owner/repo")
            }
        }
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testRejectsAdvertisedAndActualDownloadSizeOrHashMismatch() async {
        for entry in [GitHubStubProtocol.Entry(path: "data", content: "short", size: -1),
                      .init(path: "data", content: "short", size: 10),
                      .init(path: "data", content: "short", download: "wrong")] {
            GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe")), entry]
            await assertError("ask.skills.install.invalidSource") {
                _ = try await self.installer().install(from: "github.com/owner/repo")
            }
        }
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe")),
                                      .init(
                                          path: "data",
                                          content: "short",
                                          download: String(
                                              repeating: "x",
                                              count: AskSkillInstaller.maximumFileBytes + 1
                                          )
                                      )]
        await assertError("ask.skills.install.tooLarge") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testCountAndTotalSizeBoundsAndDuplicateSkillNames() async {
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe"))]
            + (0 ..< 50).map { .init(path: "file-\($0)", content: "x") }
        await assertError("ask.skills.install.tooLarge") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("safe"))]
            + (0 ..< 5).map { .init(path: "file-\($0)", content: "x", size: AskSkillInstaller.maximumFileBytes) }
        await assertError("ask.skills.install.tooLarge") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.entries = [.init(path: "a/SKILL.md", content: skill("same")),
                                      .init(path: "b/SKILL.md", content: skill("Same"))]
        await assertError("ask.skills.install.invalidSkill") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testSecondDirectoryMoveFailureLeavesEveryOldFileAndPreviousVersionUntouched() async throws {
        GitHubStubProtocol.entries = [.init(path: "a/SKILL.md", content: skill("a", "Original A")),
                                      .init(path: "a/resource.txt", content: "Original resource"),
                                      .init(path: "b/SKILL.md", content: skill("b", "Original B"))]
        _ = try await installer().install(from: "github.com/owner/repo")
        let previousSource = try Data(contentsOf: root.appendingPathComponent("a/.source.json"))
        _ = try await installer().install(from: "github.com/owner/repo")
        let originalSource = try Data(contentsOf: root.appendingPathComponent("a/.source.json"))
        GitHubStubProtocol.entries[0].content = skill("a", "New A")
        GitHubStubProtocol.entries[1].content = "New resource"
        GitHubStubProtocol.entries[2].content = skill("b", "New B")
        var failing = installer()
        failing.move = { from, destination in
            if destination.lastPathComponent == "b",
               !destination.path.contains("/.previous/") {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: from, to: destination)
        }
        do { _ = try await failing.install(from: "github.com/owner/repo"); XCTFail("Expected move failure") } catch {}
        XCTAssertTrue(try library.load("a").contains("Original A"))
        XCTAssertTrue(try library.load("b").contains("Original B"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a/resource.txt")), "Original resource")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a/.source.json")), originalSource)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".previous/a/.source.json")), previousSource)
    }

    func testSecondNewDirectoryFailurePublishesNothing() async throws {
        GitHubStubProtocol.entries = [.init(path: "a/SKILL.md", content: skill("a")),
                                      .init(path: "b/SKILL.md", content: skill("b"))]
        var failing = installer()
        failing.move = { from, destination in
            if destination.lastPathComponent == "b" {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: from, to: destination)
        }
        do { _ = try await failing.install(from: "github.com/owner/repo"); XCTFail("Expected move failure") } catch {}
        XCTAssertTrue(library.userSkillNames().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUpdateRetainsOneCompleteVersionAndRollbackRestoresSourceAndResources() async throws {
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("versioned", "Version one")),
                                      .init(path: "old.txt", content: "Old resource")]
        _ = try await installer().install(from: "github.com/owner/repo")
        let oldSource = try Data(contentsOf: root.appendingPathComponent("versioned/.source.json"))
        let installed = try XCTUnwrap(library.skills().first { $0.name == "versioned" })
        XCTAssertFalse(library.hasPreviousVersion(of: installed))
        XCTAssertThrowsError(try library.rollback(installed))
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("versioned", "Version two")),
                                      .init(path: "new.txt", content: "New resource")]
        _ = try await installer().install(from: "github.com/owner/repo")
        XCTAssertTrue(library.hasPreviousVersion(of: installed))
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent("versioned/.source.json")), oldSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versioned/old.txt").path))
        try library.rollback(installed)
        XCTAssertTrue(try library.load("versioned").contains("Version one"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("versioned/.source.json")), oldSource)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("versioned/old.txt")), "Old resource")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("versioned/new.txt").path))
        try library.rollback(installed)
        XCTAssertTrue(try library.load("versioned").contains("Version two"))
        try library.remove(installed)
        XCTAssertFalse(library.hasPreviousVersion(of: installed))
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testLegacyMetadataMigratesOnUpdateAndCanBeRestored() async throws {
        let folder = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try skill("legacy", "Legacy body").write(
            to: folder.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let old = #"{"url":"https://github.com/owner/repo","repository":"owner/repo","ref":"main","path":"","installedAt":"2026-01-01T00:00:00Z"}"#
        try old.write(to: folder.appendingPathComponent(".source.json"), atomically: true, encoding: .utf8)
        let installed = try XCTUnwrap(library.skills().first { $0.name == "legacy" })
        let legacySource = try XCTUnwrap(library.source(of: installed))
        XCTAssertNil(legacySource.commit)
        XCTAssertNil(legacySource.installationID)
        XCTAssertNil(legacySource.schemaVersion)
        GitHubStubProtocol.entries = [.init(
            path: "SKILL.md",
            content: "---\nname: legacy\nversion: 2\npermissions: [files.write]\n---\nUpdated"
        )]
        _ = try await installer().install(from: "github.com/owner/repo")
        let updated = try XCTUnwrap(library.source(of: installed))
        XCTAssertEqual(updated.schemaVersion, 2)
        XCTAssertEqual(updated.version, "2")
        XCTAssertEqual(updated.declaredPermissions, ["files.write"])
        XCTAssertNotNil(updated.installationID)
        try library.rollback(installed)
        XCTAssertEqual(library.source(of: installed), legacySource)
        XCTAssertTrue(try library.load("legacy").contains("Legacy body"))
    }

    func testSymlinkedLocalSkillsAndDestinationsAreNeverFollowed() async throws {
        let external = root.deletingLastPathComponent().appendingPathComponent("external-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try skill("linked").write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: external
        )
        XCTAssertTrue(library.userSkillNames().isEmpty)
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("linked", "New"))]
        await assertError("ask.skills.install.unsafeResource") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("SKILL.md")), skill("linked"))
    }

    func testMalformedAPIMetadataAndTransportFailuresAreExplicit() async {
        for (path, body, key) in [
            ("/repos/owner/repo", "{}", "notFound"),
            ("/repos/owner/repo/git/trees/" + GitHubStubProtocol.commit, "{}", "invalidSource"),
            ("/repos/owner/repo/git/trees/" + GitHubStubProtocol.commit,
             #"{"truncated":false,"tree":[{"path":"SKILL.md"}]}"#, "invalidSource")
        ] {
            GitHubStubProtocol.responses = [path: Data(body.utf8)]
            await assertError("ask.skills.install." + key) {
                _ = try await self.installer().install(from: "github.com/owner/repo")
            }
        }
        GitHubStubProtocol.responses = [:]
        GitHubStubProtocol.networkError = URLError(.timedOut)
        await assertError("ask.skills.install.network") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.networkError = URLError(.cancelled)
        do {
            _ = try await installer().install(from: "github.com/owner/repo")
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(library.userSkillNames().isEmpty)
    }

    func testFullLibraryRejectsAdditionalSkillButAllowsReplacement() async throws {
        for index in 0 ..< AskSkillLibrary.maximumSkills {
            let folder = root.appendingPathComponent("s\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try skill("s\(index)").write(
                to: folder.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("overflow"))]
        await assertError("ask.skills.install.tooMany") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("s0", "Updated"))]
        let result = try await installer().install(from: "github.com/owner/repo")
        XCTAssertEqual(result.replaced, ["s0"])
        XCTAssertTrue(try library.load("s0").contains("Updated"))
    }

    func testSameNameLocalFolderIsReplacedWithoutLeavingAnAliasToShadowIt() async throws {
        let alias = root.appendingPathComponent("z-custom-folder")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try skill("same", "Local version").write(
            to: alias.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        GitHubStubProtocol.entries = [.init(path: "SKILL.md", content: skill("same", "Remote version"))]
        let result = try await installer().install(from: "github.com/owner/repo")
        XCTAssertEqual(result.replaced, ["same"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertTrue(try library.load("same").contains("Remote version"))
        let installed = try XCTUnwrap(library.skills().first { $0.name == "same" })
        try library.rollback(installed)
        XCTAssertTrue(try library.load("same").contains("Local version"))
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try skill("same", "Ambiguous version").write(
            to: alias.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        await assertError("ask.skills.install.nameConflict") {
            _ = try await self.installer().install(from: "github.com/owner/repo")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }
}
