@testable import Typeflux
import XCTest

final class AskArtifactCaptureTests: XCTestCase {
    var base: URL!
    var root: URL!
    var projects: AskProjectWorkspace!
    var store: AskArtifactStore!
    let scope = AskProjectScope(ownerId: "o", conversationId: "c", runId: "r")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projects = AskProjectWorkspace(storageURL: base.appendingPathComponent("projects"))
        store = AskArtifactStore(storageURL: base.appendingPathComponent("artifacts"))
        try Data("original".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: root.appendingPathComponent("app.js"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: base)
    }

    func open() throws -> AskWorkspaceRef {
        try projects.open(
            root: root.path,
            scope: scope,
            authorizedRoots: [root.path]
        )
    }

    func testUsesStagedBytesAndDoesNotPublishUnlistedSourceFiles() throws {
        var workspace = try open()
        let current = try projects.read(workspace.id, path: "index.html", scope: scope, authorizedRoots: [root.path])
        workspace = try projects.write(workspace.id, path: "index.html", expectedVersion: current.version,
                                       content: "staged", scope: scope, authorizedRoots: [root.path])
        workspace = try projects.write(workspace.id, path: "new/log.txt", expectedVersion: "missing",
                                       content: "new log", scope: scope, authorizedRoots: [root.path])
        let ref = try AskArtifactCapture(projects: projects, store: store).capture(
            workspace: workspace, entry: "index.html", paths: ["index.html", "new/log.txt"], scope: scope,
            authorizedRoots: { [self.root.path] }
        )
        let bundle = try store.load(ref, scope: scope) { _ in }
        XCTAssertEqual(bundle.files["index.html"], Data("staged".utf8))
        XCTAssertEqual(bundle.files["new/log.txt"], Data("new log".utf8))
        XCTAssertNil(bundle.files["app.js"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("index.html")), "original")
        try Data("later editor change".utf8).write(to: root.appendingPathComponent("index.html"))
        XCTAssertEqual(try store.load(ref, scope: scope) { _ in }.files, bundle.files)
    }

    func testUnstagedSourceChangesAndGrantRevocationAbortBeforePublication() throws {
        let workspace = try open()
        var capture = AskArtifactCapture(projects: projects, store: store)
        capture.beforeRevalidation = { try Data("changed".utf8).write(to: self.root.appendingPathComponent("app.js")) }
        XCTAssertThrowsError(try capture.capture(
            workspace: workspace,
            entry: "index.html",
            paths: ["index.html", "app.js"],
            scope: scope,
            authorizedRoots: { [self.root.path] }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        var roots = [root.path]
        capture.beforeRevalidation = { roots = [] }
        XCTAssertThrowsError(try capture.capture(workspace: workspace, entry: "index.html", paths: ["index.html"],
                                                 scope: scope, authorizedRoots: { roots }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testCaptureRejectsInvalidManifestMissingResourcesAndSourceReplacement() throws {
        let workspace = try open()
        var capture = AskArtifactCapture(projects: projects, store: store)
        for paths in [
            [],
            ["index.html", "index.html"],
            ["missing"],
            ["index.html", "missing"],
            ["index.html", "../secret"],
            (0 ... 128).map { String($0) } + ["index.html"]
        ] {
            XCTAssertThrowsError(try capture.capture(workspace: workspace, entry: "index.html", paths: paths,
                                                     scope: scope, authorizedRoots: { [self.root.path] }))
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("app.js")
        )
        XCTAssertThrowsError(try capture.capture(workspace: workspace, entry: "link", paths: ["link"], scope: scope,
                                                 authorizedRoots: { [self.root.path] }))
        capture.beforeRevalidation = {
            try FileManager.default.moveItem(at: self.root, to: self.base.appendingPathComponent("old"))
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try capture.capture(workspace: workspace, entry: "index.html", paths: ["index.html"],
                                                 scope: scope, authorizedRoots: { [self.root.path] }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }
}
