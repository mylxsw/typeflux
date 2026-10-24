import Foundation
import Testing
@testable import Typeflux

@Suite("Ask side panel file access")
struct AskSidePanelFileAccessTests {
    private typealias Access = AskSidePanelFileAccess

    /// A workspace with `outputs/page.html`, a granted folder, and a file outside both.
    private struct Fixture {
        let base: URL
        let workspace: URL
        let granted: URL
        let outside: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-access-" + UUID().uuidString)
            workspace = base.appendingPathComponent("workspace", isDirectory: true)
            granted = base.appendingPathComponent("granted", isDirectory: true)
            outside = base.appendingPathComponent("outside.txt")
            let manager = FileManager.default
            try manager.createDirectory(at: workspace.appendingPathComponent("outputs/nested"), withIntermediateDirectories: true)
            try manager.createDirectory(at: granted, withIntermediateDirectories: true)
            try Data("<p>page</p>".utf8).write(to: workspace.appendingPathComponent("outputs/page.html"))
            try Data("granted".utf8).write(to: granted.appendingPathComponent("notes.txt"))
            try Data("secret".utf8).write(to: outside)
        }

        var roots: [String] { [workspace.path, granted.path] }
    }

    @Test func resolvesWorkspaceAndGrantedFiles() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let page = try Access.resolve("outputs/page.html", workspaceRoot: fixture.workspace)
        #expect(page.relativePath == "outputs/page.html")
        #expect(page.root == AskProjectFileAccess.normalizedRoot(fixture.workspace.path))
        #expect(page.name == "page.html")
        #expect(page.url.path == page.path)
        #expect(try Access.read(page, roots: fixture.roots, limit: 1024) == Data("<p>page</p>".utf8))
        let absolute = try Access.resolve(fixture.workspace.appendingPathComponent("outputs/page.html").path,
                                          workspaceRoot: fixture.workspace)
        #expect(absolute == page)
        let notes = try Access.resolve(fixture.granted.appendingPathComponent("notes.txt").path,
                                       workspaceRoot: fixture.workspace, grantedRoots: [fixture.granted.path])
        #expect(notes.root == AskProjectFileAccess.normalizedRoot(fixture.granted.path))
        #expect(try Access.read(notes, roots: fixture.roots, limit: 100) == Data("granted".utf8))
    }

    @Test func refusesTraversalOutsidePathsAndTheRootItself() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        for path in ["../outside.txt", "outputs/../../outside.txt", fixture.outside.path, "/etc/hosts", "", ".",
                     fixture.workspace.path, "outputs/page.html\0"] {
            #expect(throws: Access.AccessError.denied, "\(path)") {
                try Access.resolve(path, workspaceRoot: fixture.workspace)
            }
        }
        // A folder outside the workspace is only readable once granted.
        #expect(throws: Access.AccessError.denied) {
            try Access.resolve(fixture.granted.appendingPathComponent("notes.txt").path, workspaceRoot: fixture.workspace)
        }
    }

    @Test func refusesLinksOutOfTheWorkspace() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let manager = FileManager.default
        try manager.createSymbolicLink(at: fixture.workspace.appendingPathComponent("outputs/link.txt"),
                                       withDestinationURL: fixture.outside)
        try manager.createSymbolicLink(at: fixture.workspace.appendingPathComponent("outputs/escape"),
                                       withDestinationURL: fixture.base)
        #expect(throws: Access.AccessError.denied) {
            try Access.resolve("outputs/link.txt", workspaceRoot: fixture.workspace)
        }
        #expect(throws: Access.AccessError.denied) {
            try Access.resolve("outputs/escape/outside.txt", workspaceRoot: fixture.workspace)
        }
        // A link swapped in after the tab opened is refused when the tab reads again.
        let page = try Access.resolve("outputs/page.html", workspaceRoot: fixture.workspace)
        let pageURL = fixture.workspace.appendingPathComponent("outputs/page.html")
        try manager.removeItem(at: pageURL)
        try manager.createSymbolicLink(at: pageURL, withDestinationURL: fixture.outside)
        #expect(throws: Access.AccessError.denied) { try Access.read(page, roots: fixture.roots, limit: 100) }
    }

    @Test func refusesFoldersMissingFilesAndRevokedRoots() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        #expect(throws: Access.AccessError.notAFile) { try Access.resolve("outputs/nested", workspaceRoot: fixture.workspace) }
        #expect(throws: Access.AccessError.notAFile) { try Access.resolve("outputs/missing.md", workspaceRoot: fixture.workspace) }
        #expect(throws: Access.AccessError.denied) { try Access.resolve("outputs/missing/a.md", workspaceRoot: fixture.workspace) }
        let notes = try Access.resolve(fixture.granted.appendingPathComponent("notes.txt").path,
                                       workspaceRoot: fixture.workspace, grantedRoots: [fixture.granted.path])
        // The grant was revoked: its root is no longer allowed.
        #expect(throws: Access.AccessError.denied) { try Access.check(notes, roots: [fixture.workspace.path]) }
        #expect(throws: Access.AccessError.denied) { try Access.read(notes, roots: [fixture.workspace.path], limit: 100) }
        let forged = Access.Target(root: AskProjectFileAccess.normalizedRoot(fixture.workspace.path),
                                   relativePath: "outputs/../../outside.txt")
        #expect(throws: Access.AccessError.denied) { try Access.check(forged, roots: fixture.roots) }
    }

    @Test func limitsAndClipsReads() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let page = try Access.resolve("outputs/page.html", workspaceRoot: fixture.workspace)
        let size = "<p>page</p>".utf8.count
        #expect(throws: Access.AccessError.tooLarge) { try Access.read(page, roots: fixture.roots, limit: size - 1) }
        #expect(try Access.read(page, roots: fixture.roots, limit: size).count == size)
        let clipped = try Access.read(page, roots: fixture.roots, limit: 3, clip: true)
        #expect(clipped.data == Data("<p>".utf8))
        #expect(clipped.clipped)
        let whole = try Access.read(page, roots: fixture.roots, limit: size, clip: true)
        #expect(whole.data.count == size)
        #expect(!whole.clipped)
    }
}
