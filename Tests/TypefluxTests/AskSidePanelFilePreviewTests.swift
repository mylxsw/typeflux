import AppKit
import SwiftUI
@testable import Typeflux
import WebKit
import XCTest

@MainActor
final class AskSidePanelFilePreviewTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("side-panel-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ name: String, _ data: Data) throws -> AskSidePanelFileAccess.Target {
        try data.write(to: base.appendingPathComponent(name))
        return try AskSidePanelFileAccess.resolve(name, workspaceRoot: base)
    }

    private func load(_ name: String, _ data: Data) throws -> AskSidePanelFileContent {
        let target = try write(name, data)
        let kind = AskSidePanelFileKind.kind(forExtension: (name as NSString).pathExtension, sample: data)
        return AskSidePanelFileLoader.load(target, kind: kind, roots: [base.path])
    }

    // MARK: - Kinds

    func testKindsFollowTheExtensionThenTheBytes() {
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "HTM"), .html)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "markdown"), .markdown)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "tsv"), .csv)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "pdf"), .pdf)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "JPEG"), .image)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "swift"), .text)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "", sample: Data("plain words".utf8)), .text)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "bin", sample: Data([0, 1, 2])), .unsupported)
        XCTAssertEqual(AskSidePanelFileKind.kind(forExtension: "docx"), .unsupported)
        // A sample cut inside a multi-byte character is still text.
        XCTAssertTrue(AskSidePanelFileKind.looksLikeText(Data("文件".utf8).dropLast()))
        XCTAssertFalse(AskSidePanelFileKind.looksLikeText(Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])))
        XCTAssertTrue(AskSidePanelFileKind.html.hasSource)
        XCTAssertTrue(AskSidePanelFileKind.csv.hasSource)
        XCTAssertFalse(AskSidePanelFileKind.text.hasSource)
        XCTAssertEqual(AskFileIcon.symbol(forExtension: "csv"), "tablecells")
        for kind in [AskSidePanelFileKind.html, .markdown, .csv, .image, .pdf, .text, .unsupported] {
            XCTAssertFalse(AskFileIcon.symbol(for: kind).isEmpty)
        }
    }

    // MARK: - CSV

    func testCSVHandlesQuotesLineBreaksAndRowLimit() {
        let text = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\"\nplain,\n\nlast,row"
        let table = AskCSVTable.parse(text, maxRows: 10)
        XCTAssertEqual(table.rows, [["name", "note"], ["Smith, J", "said \"hi\"\nthen left"], ["plain", ""], ["last", "row"]])
        XCTAssertFalse(table.truncated)
        XCTAssertEqual(table.columnCount, 2)
        let limited = AskCSVTable.parse("a\nb\nc\n", maxRows: 2)
        XCTAssertEqual(limited.rows, [["a"], ["b"]])
        XCTAssertTrue(limited.truncated)
        XCTAssertFalse(AskCSVTable.parse("a\nb\n", maxRows: 2).truncated)
        XCTAssertEqual(AskCSVTable.parse("x\ty\n1\t2", delimiter: "\t", maxRows: 5).rows, [["x", "y"], ["1", "2"]])
        let wide = AskCSVTable.parse(Array(repeating: "v", count: 100).joined(separator: ","), maxRows: 1)
        XCTAssertEqual(wide.columnCount, AskCSVTable.columnLimit)
        XCTAssertEqual(AskCSVTable.parse("", maxRows: 5).rows, [])
    }

    // MARK: - Loading

    func testLoadsEachSupportedFormat() throws {
        guard case let .text(code, false) = try load("main.py", Data("print(1)\nprint(2)".utf8)) else {
            return XCTFail("Code loads as text")
        }
        XCTAssertEqual(AskLineNumberedText.lines(code), ["print(1)", "print(2)"])
        guard case let .markdown(markdown, false) = try load("notes.md", Data("# Title".utf8)) else {
            return XCTFail("Markdown")
        }
        XCTAssertEqual(markdown, "# Title")
        guard case let .csv(table, source) = try load("data.tsv", Data("a\tb\n1\t2".utf8)) else { return XCTFail("CSV") }
        XCTAssertEqual(table.rows, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(source, "a\tb\n1\t2")
        guard case let .html(bundle, html) = try load("page.html", Data("<h1>Hi</h1>".utf8)) else { return XCTFail("HTML") }
        XCTAssertEqual(html, "<h1>Hi</h1>")
        XCTAssertEqual(Set(bundle.files.keys), ["page.html"])

        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        guard case let .image(loaded) = try load("dot.png", png) else { return XCTFail("Image") }
        XCTAssertEqual(loaded.size.width, 1, accuracy: 0.5)
        guard case .unsupported = try load("broken.png", Data("not an image".utf8)) else {
            return XCTFail("Undecodable image")
        }

        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        guard case let .pdf(data) = try load("doc.pdf", pdf as Data) else { return XCTFail("PDF") }
        XCTAssertEqual(data, pdf as Data)

        guard case .unsupported = try load("archive.bin", Data([0, 1, 2, 3])) else { return XCTFail("Binary") }
        XCTAssertEqual(AskLineNumberedText.lines("a\n\nb\n"), ["a", "", "b"])
        XCTAssertEqual(AskLineNumberedText.lines(""), [])
    }

    func testLargeTextIsClippedAndDeniedFilesFail() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: AskSidePanelFileLoader.textLimit + 10)
        guard case let .text(text, truncated) = try load("big.log", big) else { return XCTFail("Clipped text") }
        XCTAssertTrue(truncated)
        XCTAssertEqual(text.utf8.count, AskSidePanelFileLoader.textLimit)
        let target = try write("notes.txt", Data("x".utf8))
        guard case let .failure(message) = AskSidePanelFileLoader.load(target, kind: .text, roots: ["/elsewhere"]) else {
            return XCTFail("A root no longer allowed is refused")
        }
        XCTAssertFalse(message.isEmpty)
        try FileManager.default.removeItem(at: base.appendingPathComponent("notes.txt"))
        guard case .failure = AskSidePanelFileLoader.load(target, kind: .unsupported, roots: [base.path]) else {
            return XCTFail("A deleted file fails")
        }
        XCTAssertEqual(AskSidePanelFileLoader.text(Data([0x61, 0xE6])), "a\u{FFFD}")
    }

    // MARK: - HTML sandbox

    func testHTMLPreviewServesOnlyTheFileWithNetworkingBlocked() throws {
        let bundle = try AskFileHTMLPreview.bundle(Data("<link rel=stylesheet href=style.css>".utf8))
        XCTAssertEqual(bundle.manifest.entry, AskFileHTMLPreview.entry)
        XCTAssertEqual(bundle.manifest.ref.mediaType, "text/html")
        XCTAssertEqual(bundle.manifest.ref.sha256, AskToolPolicy.digest(bundle.files[AskFileHTMLPreview.entry]!))
        let policy = AskPreviewPolicy(token: "file-tab", paths: Set(bundle.files.keys))
        XCTAssertEqual(try policy.path(policy.url(AskFileHTMLPreview.entry)), AskFileHTMLPreview.entry)
        // Files beside the page, and anything above it, are not served.
        for path in ["style.css", "../secret.txt", "outputs/other.html"] {
            XCTAssertThrowsError(try policy.path(policy.url(path)), path)
        }
        let csp = policy.contentSecurityPolicy
        for directive in ["default-src 'none'", "connect-src 'none'", "frame-src 'none'", "form-action 'none'",
                          "img-src typeflux-artifact://file-tab"] {
            XCTAssertTrue(csp.contains(directive), directive)
        }
        XCTAssertFalse(csp.contains("allow-same-origin"))
        let rules = try policy.contentRules
        XCTAssertTrue(rules.contains("\"block\""))
        XCTAssertTrue(rules.contains("typeflux-artifact:\\/\\/file-tab\\/") || rules.contains("typeflux-artifact://file-tab/"))
        XCTAssertThrowsError(try AskFileHTMLPreview.bundle(Data(count: AskArtifactStore.maximumFileBytes + 1)))
    }

    func testHTMLPreviewClosesWhenTheFileIsNoLongerAllowed() async throws {
        let bundle = try AskFileHTMLPreview.bundle(Data("<p>ok</p>".utf8))
        let host = AskPreviewHost()
        var allowed = true
        let view: WKWebView
        do {
            view = try await host.open(.artifact(bundle.manifest.ref), enabled: true,
                                       validateAccess: { _ in if !allowed { throw AskSidePanelFileAccess.AccessError.denied } },
                                       load: { _ in bundle })
        } catch AskArtifactError.previewDisabled {
            throw XCTSkip("This WebKit build lacks the engine switches the preview requires")
        }
        XCTAssertEqual(host.policy?.paths, [AskFileHTMLPreview.entry])
        XCTAssertTrue(host.webView === view)
        allowed = false
        host.check()
        XCTAssertNil(host.webView)
        host.close()
    }

    // MARK: - External actions

    func testExportCopiesAndReplaces() throws {
        let source = base.appendingPathComponent("report.html")
        try Data("new".utf8).write(to: source)
        let destination = base.appendingPathComponent("saved.html")
        try AskFileExternalActions.export(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        try Data("newer".utf8).write(to: source)
        try AskFileExternalActions.export(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("newer".utf8))
        try AskFileExternalActions.export(source, to: source)
        XCTAssertEqual(try Data(contentsOf: source), Data("newer".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".typeflux-") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertTrue(AskFileExternalActions.isHTML(source))
        XCTAssertFalse(AskFileExternalActions.isHTML(base.appendingPathComponent("a.md")))
    }

    func testCopiesTheFileOrItsPath() throws {
        let pasteboard = NSPasteboard(name: .init("AskSidePanelFilePreviewTests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let actions = AskFileExternalActions(pasteboard: pasteboard)
        let file = base.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        actions.copyPath(file)
        XCTAssertEqual(pasteboard.string(forType: .string), file.path)
        actions.copyFile(file)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [file.standardizedFileURL])
        // TextEdit or another editor handles plain text on every Mac.
        XCTAssertFalse(actions.applications(for: file).isEmpty)
        XCTAssertNotNil(actions.defaultApplication(for: file))
        XCTAssertEqual(Set(actions.applications(for: file).map(\.url)).count, actions.applications(for: file).count)
    }
}

extension AskSidePanelFilePreviewTests {
    /// Records what would be handed to Launch Services and Finder.
    private final class SystemRecorder {
        var opened: [URL] = []
        var openedWith: [(URL, URL)] = []
        var revealed: [URL] = []
        var browser: URL? = URL(fileURLWithPath: "/Applications/Safari.app")

        func system() -> AskFileExternalActions.System {
            .init(defaultApplication: { [unowned self] url in
                url.scheme == "https" ? browser : URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            }, applications: { _ in
                [URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                 URL(fileURLWithPath: "/System/Applications/TextEdit.app/"),
                 URL(fileURLWithPath: "/Applications/Xcode.app")]
            }, open: { [unowned self] in opened.append($0) },
            openWith: { [unowned self] in openedWith.append(($0, $1)) },
            reveal: { [unowned self] in revealed.append($0) })
        }
    }

    func testExternalActionsGoThroughTheSystem() {
        let recorder = SystemRecorder()
        let actions = AskFileExternalActions(system: recorder.system())
        let page = base.appendingPathComponent("page.html")
        XCTAssertEqual(actions.defaultApplication(for: page)?.name, "TextEdit")
        XCTAssertEqual(actions.applications(for: page).map(\.name), ["TextEdit", "Xcode"])
        XCTAssertEqual(actions.applications(for: page, limit: 1).count, 1)
        actions.openWithDefaultApplication(page)
        actions.revealInFinder(page)
        actions.openInBrowser(page)
        XCTAssertEqual(recorder.opened, [page])
        XCTAssertEqual(recorder.revealed, [page])
        XCTAssertEqual(recorder.openedWith.map(\.1.lastPathComponent), ["Safari.app"])
        // Without a default browser, the file opens with its own default app.
        recorder.browser = nil
        actions.openInBrowser(page)
        XCTAssertEqual(recorder.opened, [page, page])
        XCTAssertEqual(AskFileExternalActions.application(URL(fileURLWithPath: "/Applications/Tool")).name, "Tool")
    }

    func testMenuItemsRenderForHTMLAndOtherFiles() throws {
        let recorder = SystemRecorder()
        for name in ["page.html", "notes.txt"] {
            for shortcuts in [true, false] {
                let view = VStack {
                    AskFileOpenMenuItems(file: base.appendingPathComponent(name),
                                         actions: AskFileExternalActions(system: recorder.system()),
                                         showsShortcuts: shortcuts)
                }
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(hosting.fittingSize.height, 0)
            }
        }
    }
}
