import AppKit
@testable import Typeflux
import WebKit
import XCTest

@MainActor final class AskLocalWebsitePreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func target(_ path: String = "site/home.html") throws -> AskSidePanelFileAccess.Target {
        try AskSidePanelFileAccess.resolve(path, workspaceRoot: root)
    }

    private func fixture() throws {
        try write("site/home.html", """
        <!doctype html><html><head><title>Multi file</title>
        <link rel="stylesheet" href="assets/main.css?v=2"></head><body>
        <h1 id="heading">Ready</h1><img id="picture" src="assets/水 滴.svg?v=1">
        <button id="button">Change</button><script src="assets/app.js?v=3"></script>
        </body></html>
        """)
        try write("site/assets/main.css", "@import './nested/colors.css?v=1'; body { margin: 17px; }")
        try write("site/assets/nested/colors.css", "h1 { color: rgb(12, 34, 56); }")
        try write("site/assets/app.js", """
        document.querySelector('#heading').textContent = 'Loaded';
        document.querySelector('#button').onclick = () => document.querySelector('#heading').textContent = 'Clicked';
        """)
        try write("site/assets/水 滴.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10'/></svg>")
    }

    private func ready(_ view: WKWebView) async throws {
        for _ in 0..<100 {
            if !view.isLoading, view.url?.scheme == AskPreviewPolicy.scheme,
               (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AskArtifactError.unavailable
    }

    private func assertRendered(_ view: WKWebView) async throws {
        try await ready(view)
        let result = try await view.evaluateJavaScript("""
        [document.querySelector('h1').textContent, getComputedStyle(document.querySelector('h1')).color,
         getComputedStyle(document.body).margin, String(document.querySelector('img').naturalWidth)]
        """) as? [String]
        XCTAssertEqual(result, ["Loaded", "rgb(12, 34, 56)", "17px", "10"])
        _ = try await view.evaluateJavaScript("document.querySelector('button').click()")
        let clicked = try await view.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(clicked, "Clicked")
    }

    func testAgentAndUserRenderTheSameMultiFileWebsite() async throws {
        try fixture()
        guard case let .html(bundle, _) = AskSidePanelFileLoader.load(try target(), kind: .html, roots: [root.path]) else {
            return XCTFail("The user loader must create a website bundle")
        }
        let host = AskPreviewHost()
        defer { host.close() }
        let view = try await host.open(.artifact(bundle.manifest.ref), enabled: true) { _ in bundle }
        try await assertRendered(view)
        let userDiagnostics = try await host.collectDiagnostics()
        XCTAssertEqual(userDiagnostics.errors, [])

        let workspace = AskBrowserWorkspace(dataStore: .nonPersistent())
        let tool = AskEmbeddedBrowserTool(workspace: workspace)
        let file = root.appendingPathComponent("site/home.html")
        let arguments: [String: Any] = ["action": "open_file", "path": file.path]
        let output = try await tool.execute(arguments, conversationId: "test", authorize: {})
        let tab = try XCTUnwrap(workspace.selectedTab)
        defer { workspace.close(tab) }
        XCTAssertFalse(output.content.contains("Notice:"), output.content)
        XCTAssertEqual(tab.previewHost?.policy?.paths, host.policy?.paths)
        try await assertRendered(tab.webView)
        try write("site/assets/app.js", "document.querySelector('h1').textContent = 'Refreshed';")
        _ = try await tool.execute(arguments, conversationId: "test", authorize: {})
        XCTAssertEqual(workspace.selectedTab?.id, tab.id)
        try await ready(tab.webView)
        let refreshed = try await tab.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(refreshed, "Refreshed")
        tab.load(URL(string: "about:blank")!)
        XCTAssertNil(tab.previewHost)
        XCTAssertNil(tab.localFileURL)
    }

    func testSnapshotPreservesPathsExcludesSecretsAndLinksAndTracksResourceChanges() throws {
        try fixture()
        try write("secret.js", "secret")
        try write("site/.env", "secret")
        try write("site/private.txt", "secret")
        try write("site/.hidden/secret.js", "secret")
        try write("site/node_modules/library/index.js", "not preview output")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("site/leak.js"),
                                                   withDestinationURL: root.appendingPathComponent("secret.js"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("site/escape"), withDestinationURL: root)
        let before = try AskFileHTMLPreview.bundle(target(), roots: [root.path])
        XCTAssertEqual(before.manifest.ref.version,
                       try AskFileHTMLPreview.bundle(target(), roots: [root.path]).manifest.ref.version)
        XCTAssertEqual(before.manifest.entry, "home.html")
        XCTAssertEqual(before.files.count, 5)
        XCTAssertNil(before.files["leak.js"])
        try write("site/assets/main.css", "body { color: red }")
        let after = try AskFileHTMLPreview.bundle(target(), roots: [root.path])
        XCTAssertNotEqual(before.manifest.ref.version, after.manifest.ref.version)
        XCTAssertEqual(before.manifest.ref.sha256, after.manifest.ref.sha256)
        XCTAssertThrowsError(try AskFileHTMLPreview.bundle(target(), roots: []))
    }

    func testClosingDuringPreviewPreparationDoesNotResurrectTheTab() async throws {
        try fixture()
        let tab = AskBrowserTab(number: 1, configuration: WKWebViewConfiguration(), isPrivate: false, owner: .user)
        let loading = Task { try await tab.loadLocalHTML(root.appendingPathComponent("site/home.html")) }
        await Task.yield()
        tab.close()
        loading.cancel()
        do { try await loading.value } catch is CancellationError {} catch { throw error }
        XCTAssertNil(tab.previewHost)
        XCTAssertNil(tab.localFileURL)
    }

    func testTooManyAndOversizedAssetsFailExplicitly() throws {
        try write("site/home.html", "<h1>Bounded</h1>")
        for index in 0..<AskArtifactStore.maximumFiles { try write("site/\(index).css", "") }
        XCTAssertThrowsError(try AskFileHTMLPreview.bundle(target(), roots: [root.path]))
        try FileManager.default.removeItem(at: root.appendingPathComponent("site"))
        try write("site/home.html", "ok")
        try Data(count: AskArtifactStore.maximumFileBytes + 1).write(to: root.appendingPathComponent("site/large.js"))
        XCTAssertThrowsError(try AskFileHTMLPreview.bundle(target(), roots: [root.path]))
    }

    func testMissingResourceIncludesItsPathForBothEntrances() async throws {
        try write("site/home.html", "<h1>Visible</h1><script src='assets/missing.js?v=1'></script>")
        let bundle = try AskFileHTMLPreview.bundle(target(), roots: [root.path])
        let host = AskPreviewHost()
        defer { host.close() }
        let view = try await host.open(.artifact(bundle.manifest.ref), enabled: true) { _ in bundle }
        try await ready(view)
        let diagnostics = try await host.collectDiagnostics()
        XCTAssertTrue(diagnostics.errors.contains { $0.contains("assets/missing.js") }, "\(diagnostics.errors)")
        let workspace = AskBrowserWorkspace(dataStore: .nonPersistent())
        let tool = AskEmbeddedBrowserTool(workspace: workspace)
        let output = try await tool.execute(["action": "open_file", "path": root.appendingPathComponent("site/home.html").path],
                                            conversationId: "test", authorize: {})
        defer { workspace.tabs.forEach { workspace.close($0) } }
        XCTAssertTrue(output.content.contains("assets/missing.js"), output.content)
    }
}
