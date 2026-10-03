import Darwin
import Foundation
@testable import Typeflux
import XCTest

final class AskSecureDirectoryTests: XCTestCase {
    private var root: URL!
    private var storage: AskSecureDirectory!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secure-directory-\(UUID().uuidString)")
        storage = try AskSecureDirectory.openRoot(root)
    }

    override func tearDownWithError() throws {
        storage = nil
        try FileManager.default.removeItem(at: root)
    }

    func testExclusiveNoFollowWritesNeverChangeMarker() throws {
        let outside = try storage.child("outside", create: true)
        try outside.createFile("marker", data: Data("unchanged".utf8))
        let scripts = try storage.child("scripts", create: true)
        let marker = try outside.url.appendingPathComponent("marker")
        XCTAssertEqual(symlinkat(marker.path, scripts.descriptor, "main.py"), 0)
        XCTAssertThrowsError(try scripts.createFile("main.py", data: Data("attack".utf8)))
        XCTAssertEqual(try outside.readFile("marker", limit: 100), Data("unchanged".utf8))
        XCTAssertThrowsError(try scripts.createFile("../marker", data: Data()))
        XCTAssertThrowsError(try scripts.child(".."))
        XCTAssertThrowsError(try scripts.readFile("../outside/marker", limit: 100))
        XCTAssertThrowsError(try scripts.remove(".."))
    }

    func testDirectoryReplacementUsesPinnedDescriptor() throws {
        let original = try storage.child("scripts", create: true)
        let outside = try storage.child("outside", create: true)
        XCTAssertEqual(renameat(storage.descriptor, "scripts", storage.descriptor, "retired"), 0)
        XCTAssertEqual(try symlinkat(outside.url.path, storage.descriptor, "scripts"), 0)
        // Deterministic substitution between directory-open and file-create.
        try original.createFile("main.py", data: Data("safe".utf8))
        XCTAssertThrowsError(try storage.child("scripts"))
        XCTAssertEqual(try storage.child("retired").readFile("main.py", limit: 10), Data("safe".utf8))
        XCTAssertTrue(outside.entries().isEmpty)
    }

    func testConcurrentSymlinkSubstitutionCannotRedirectWrites() throws {
        let scripts = try storage.child("scripts", create: true)
        let outside = try storage.child("outside", create: true)
        try outside.createFile("marker", data: Data("sentinel".utf8))
        let marker = try outside.url.appendingPathComponent("marker").path
        let fd = scripts.descriptor
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index % 2 == 0 {
                unlinkat(fd, "main", 0)
                symlinkat(marker, fd, "main")
            } else {
                try? scripts.createFile("main", data: Data("program".utf8))
            }
        }
        XCTAssertEqual(try outside.readFile("marker", limit: 100), Data("sentinel".utf8))
    }

    func testRootSymlinksAndUnsafePermissionsAreRejected() throws {
        let outside = try storage.child("outside", create: true)
        let link = root.appendingPathComponent("link")
        XCTAssertEqual(try symlink(outside.url.path, link.path), 0)
        XCTAssertThrowsError(try AskSecureDirectory.openRoot(link.appendingPathComponent("nested")))
        XCTAssertTrue(outside.entries().isEmpty)
        XCTAssertEqual(fchmod(outside.descriptor, 0o755), 0)
        XCTAssertThrowsError(try storage.child("outside", privateDirectory: true))
        XCTAssertThrowsError(try AskSecureDirectory.openRoot(URL(fileURLWithPath: "/")))
    }

    func testArtifactReadsRejectLinksFIFOsOversizeAndTraversal() throws {
        try storage.createFile("file", data: Data(repeating: 1, count: 9000))
        XCTAssertEqual(try storage.readFile("file", limit: 9000).count, 9000)
        XCTAssertThrowsError(try storage.readFile("file", limit: 100))
        XCTAssertEqual(symlinkat("file", storage.descriptor, "link"), 0)
        XCTAssertThrowsError(try storage.readFile("link", limit: 10000))
        XCTAssertEqual(mkfifoat(storage.descriptor, "fifo", 0o600), 0)
        XCTAssertThrowsError(try storage.readFile("fifo", limit: 100))
        XCTAssertEqual(linkat(storage.descriptor, "file", storage.descriptor, "hardlink", 0), 0)
        XCTAssertThrowsError(try storage.readFile("hardlink", limit: 10000))
        XCTAssertThrowsError(try storage.readFile("/file", limit: 100))
        XCTAssertThrowsError(try storage.readFile("missing", limit: 100))
    }

    func testSnapshotAndCleanupDoNotFollowLinks() throws {
        let nested = try storage.child("nested", create: true)
        try nested.createFile("file", data: Data("hello".utf8))
        try nested.createFile(".hidden", data: Data())
        XCTAssertEqual(symlinkat("nested", storage.descriptor, "link"), 0)
        XCTAssertEqual(storage.snapshot().keys.sorted(), ["nested/file"])
        XCTAssertEqual(storage.snapshot()["nested/file"]?.1, 5)
        try storage.remove("link")
        XCTAssertEqual(try nested.readFile("file", limit: 5), Data("hello".utf8))
        try storage.remove("nested")
        try storage.remove("missing")
        XCTAssertTrue(storage.entries().isEmpty)
    }

    func testSessionNamesDoNotAliasAndLocksExcludeConcurrentAccess() throws {
        XCTAssertNotEqual(AskSecureDirectory.sessionName("a/b"), AskSecureDirectory.sessionName("ab"))
        XCTAssertNotEqual(AskSecureDirectory.sessionName(""), AskSecureDirectory.sessionName("default"))
        XCTAssertEqual(AskSecureDirectory.sessionName("id").count, 64)
        try storage.lock()
        let second = try AskSecureDirectory.openRoot(root)
        XCTAssertThrowsError(try second.lock())
    }
}
