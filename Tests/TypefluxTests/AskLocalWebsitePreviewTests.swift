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
        let presentation = workspace.presentationRequest
        let failure = try await tool.execute(
            ["action": "open_file", "path": root.appendingPathComponent("site/home.html").path], conversationId: "test")
        XCTAssertTrue(failure.isError)
        XCTAssertEqual(failure.outcome?.safeStatus, .failed)
        XCTAssertTrue(failure.content.contains("assets/missing.js"), failure.content)
        XCTAssertTrue(failure.content.contains("Check the listed resource paths."), failure.content)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertEqual(workspace.presentationRequest, presentation)
    }
    func testSiblingImageFailureIsHiddenAndRepairMustBeReopened() async throws {
        try write("work/preview.html", "<img src='../outputs/cat.svg'>")
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><rect width='12' height='12'/></svg>"
        try write("outputs/cat.svg", svg)
        try write("work/cat.svg", svg)
        let workspace = AskBrowserWorkspace(dataStore: .nonPersistent())
        defer { workspace.tabs.forEach { workspace.close($0) } }
        let tool = AskEmbeddedBrowserTool(workspace: workspace)
        let args: [String: Any] = ["action": "open_file", "path": root.appendingPathComponent("work/preview.html").path]
        let failure = try await tool.execute(args, conversationId: "test")
        XCTAssertTrue(failure.isError, "Sibling directories are outside the preview root")
        XCTAssertTrue(failure.content.contains("outputs/cat.svg"), failure.content)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertEqual(workspace.presentationRequest, 0)
        try write("work/preview.html", "<img src='./cat.svg'>")
        let opened = try await tool.execute(args, conversationId: "test")
        XCTAssertFalse(opened.isError)
        let tab = try XCTUnwrap(workspace.selectedTab)
        let width = try await tab.webView.evaluateJavaScript("document.images[0].naturalWidth") as? Int
        XCTAssertEqual(width, 12)
        try write("work/cat.svg", svg.replacingOccurrences(of: "12", with: "24"))
        for action in ["read", "snapshot", "screenshot"] {
            let stale = try await tool.execute(["action": action], conversationId: "test")
            XCTAssertTrue(stale.isError, "Changed assets require reopening before inspection")
            XCTAssertEqual(stale.outcome?.safeStatus, .failed)
            XCTAssertTrue(stale.content.contains("stale"), stale.content)
        }
        _ = try await tool.execute(args, conversationId: "test")
        XCTAssertEqual(workspace.selectedTab?.id, tab.id)
        let newWidth = try await tab.webView.evaluateJavaScript("document.images[0].naturalWidth") as? Int
        XCTAssertEqual(newWidth, 24)
        _ = try await tool.execute(["action": "read"], conversationId: "test")
    }

    func testInvalidImageAndScriptFailureCannotReplaceWorkingPreview() async throws {
        try write("site/home.html", "<h1>Working</h1>")
        let tab = AskBrowserTab(number: 1, configuration: WKWebViewConfiguration(), isPrivate: false, owner: .user)
        defer { tab.close() }
        let file = root.appendingPathComponent("site/home.html")
        try await tab.loadLocalHTML(file)
        let workingView = tab.webView
        for html in ["<img src='broken.svg'>", "<script>throw new Error('fixture failure')</script>"] {
            try write("site/home.html", html)
            try write("site/broken.svg", "not an SVG")
            do {
                try await tab.loadLocalHTML(file)
                XCTFail("Broken pages must not replace the working page")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("validation failed"), error.localizedDescription)
            }
            XCTAssertTrue(tab.webView === workingView)
        }
    }

    func testGeneratedWebsiteWithStorageRunsOnFirstOpenFromBothEntrances() async throws {
        try write("site/index.html", #"<button id="score">Start</button><script src="game.js"></script>"#)
        try write("site/game.js", """
        const button = document.querySelector('#score');
        let count = Number(localStorage.getItem('score') || 0);
        button.textContent = String(count);
        button.onclick = () => {
          count += 1;
          localStorage.setItem('score', count);
          button.textContent = localStorage.getItem('score');
        };
        """)

        func checkStartupAndInteraction(_ view: WKWebView) async throws {
            let initialScore = try await view.evaluateJavaScript("document.querySelector('#score').textContent") as? String
            XCTAssertEqual(initialScore, "0")
            let nextScore = try await view.evaluateJavaScript("""
            document.querySelector('#score').click(); document.querySelector('#score').textContent;
            """) as? String
            XCTAssertEqual(nextScore, "1")
        }

        guard case let .html(bundle, _) = AskSidePanelFileLoader.load(
            try target("site/index.html"), kind: .html, roots: [root.path]
        ) else { return XCTFail("The file panel could not load the generated website") }
        let filePanel = AskPreviewHost()
        defer { filePanel.close() }
        let filePanelView = try await filePanel.open(.artifact(bundle.manifest.ref), enabled: true) { _ in bundle }
        try await filePanel.validateLoadedPage()
        try await checkStartupAndInteraction(filePanelView)

        let browser = AskBrowserWorkspace(dataStore: .nonPersistent())
        defer { browser.tabs.forEach { browser.close($0) } }
        let tool = AskEmbeddedBrowserTool(workspace: browser)
        let arguments = ["action": "open_file", "path": root.appendingPathComponent("site/index.html").path]
        let opened = try await tool.execute(arguments, conversationId: "test")
        XCTAssertFalse(opened.isError, opened.content)
        let tab = try XCTUnwrap(browser.selectedTab)
        try await checkStartupAndInteraction(tab.webView)

        let reopened = try await tool.execute(arguments, conversationId: "test")
        XCTAssertFalse(reopened.isError, reopened.content)
        try await checkStartupAndInteraction(tab.webView)
    }
}
