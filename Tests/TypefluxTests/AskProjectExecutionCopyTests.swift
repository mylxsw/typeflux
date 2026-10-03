import Darwin
@testable import Typeflux
import XCTest

@MainActor
final class AskProjectExecutionCopyTests: XCTestCase {
    typealias Fixture = AskProjectRuntimeTests.Fixture

    func testCopiedFilesAndDirectoryChangesAreRevalidated() throws {
        for mutation in ["file", "new", "directory", "revoke"] {
            let fixture = try Fixture(); defer { fixture.close() }
            let data = fixture.source.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
            try Data("before".utf8).write(to: data.appendingPathComponent("input.txt"))
            XCTAssertThrowsError(try fixture.launch(mutation: {
                switch mutation {
                case "file": try Data("after".utf8).write(to: data.appendingPathComponent("input.txt"))
                case "new": try Data("new".utf8).write(to: fixture.source.appendingPathComponent("new.txt"))
                case "directory":
                    try FileManager.default.moveItem(at: data, to: fixture.source.appendingPathComponent("old"))
                    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
                default: fixture.roots = []
                }
            }))
            XCTAssertEqual(
                try FileManager.default
                    .contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
                []
            )
        }
    }

    func testSymlinkHardlinkAndFIFOAreRejectedWithoutProcess() throws {
        for kind in ["symlink", "hardlink", "fifo"] {
            let fixture = try Fixture(); defer { fixture.close() }
            let target = fixture.source.appendingPathComponent("bad")
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.base)
            } else if kind == "hardlink" {
                try FileManager.default.linkItem(at: fixture.source.appendingPathComponent("main.py"), to: target)
            } else {
                XCTAssertEqual(mkfifo(target.path, 0o600), 0)
            }
            XCTAssertThrowsError(try fixture.launch())
            XCTAssertEqual(
                try FileManager.default
                    .contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
                []
            )
        }
    }

    func testListingAndFileSizeLimitsRejectInsteadOfOmittingFiles() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        for index in 0 ..< 500 {
            try Data().write(to: fixture.source.appendingPathComponent("f\(index)"))
        }
        XCTAssertThrowsError(try fixture.launch()) { XCTAssertEqual($0 as? AskProjectError, .tooLarge) }
        for index in 0 ..<
            500 {
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("f\(index)"))
        }
        let fileDescriptor = open(fixture.source.appendingPathComponent("oversize").path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        XCTAssertEqual(ftruncate(fileDescriptor, off_t(AskProjectFileAccess.maximumReadBytes + 1)),
                       0); close(fileDescriptor)
        XCTAssertThrowsError(try fixture.launch()) { XCTAssertEqual($0 as? AskProjectError, .tooLarge) }
    }

    func testStagedNewDirectoriesBinaryAssetsAndExplicitGitExclusion() async throws {
        let fixture = try Fixture("""
        import os
        print(os.listdir('.'))
        print(open('new/data.txt').read())
        print(open('asset.bin','rb').read().hex())
        """)
        defer { fixture.close() }
        try Data([0, 255, 10]).write(to: fixture.source.appendingPathComponent("asset.bin"))
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent(".git"),
            withIntermediateDirectories: false
        )
        try Data("credential".utf8).write(to: fixture.source.appendingPathComponent(".git/config"))
        fixture.workspace = try fixture.projects.write(
            fixture.workspace.id,
            path: "new/data.txt",
            expectedVersion: "missing",
            content: "staged",
            scope: fixture.scope,
            authorizedRoots: fixture.roots
        )
        let lease = try fixture.launch()
        let status = try await fixture.wait(lease)
        XCTAssertEqual(status.exitCode, 0, (try? fixture.text(lease)) ?? "Output unavailable")
        let output = try fixture.text(lease)
        XCTAssertTrue(output.contains("staged\n00ff0a\n")); XCTAssertFalse(output.contains(".git"))
    }

    func testMissingScriptAndMissingCwdDiscardPreparedCopy() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        XCTAssertThrowsError(try fixture.launch(.init(script: "missing.py")))
        var request = AskProjectLaunchRequest(script: "main.py"); request.cwd = "missing"
        XCTAssertThrowsError(try fixture.launch(request))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("runtime").path),
            []
        )
    }

    func testStagedPathsCannotBypassCopyDepthBudget() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let path = String(repeating: "deep/", count: 17) + "new.txt"
        fixture.workspace = try fixture.projects.write(fixture.workspace.id, path: path, expectedVersion: "missing",
                                                       content: "staged", scope: fixture.scope,
                                                       authorizedRoots: fixture.roots)
        XCTAssertThrowsError(try fixture.launch()) { XCTAssertEqual($0 as? AskProjectError, .tooLarge) }
    }
}
