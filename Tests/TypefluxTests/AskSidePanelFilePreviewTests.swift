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
        XCTAssertEqual(AskLineNumberedText.visibleSource(code).text, "print(1)\nprint(2)")
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
        XCTAssertEqual(AskLineNumberedText.visibleSource("a\r\n\r\nb\n").text, "a\r\n\r\nb\n")
        XCTAssertEqual(AskLineNumberedText.visibleSource("").text, "")
        let limit = String(repeating: "a\n", count: AskLineNumberedText.lineLimit)
        XCTAssertFalse(AskLineNumberedText.visibleSource(limit).truncated)
        XCTAssertEqual(AskLineNumberedText.visibleSource(limit + "tail").text, limit)
        XCTAssertTrue(AskLineNumberedText.visibleSource(limit + "tail").truncated)
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

extension AskSidePanelFilePreviewTests {
    func testFileSyntaxFollowsExtension() {
        XCTAssertEqual(AskFileSourceStyle(path: "outputs/clone-typeflux.sh").language, .shell)
        XCTAssertEqual(AskFileSourceStyle(path: "notes.txt").language, .plain)
        XCTAssertEqual(AskFileSourceStyle(path: "main.swift").language, .generic)
    }

    func testShellTabInDarkAppearance() async throws {
        let script = """
        #!/usr/bin/env bash
        # 一键克隆 Typeflux 仓库
        set -euo pipefail

        TARGET_DIR="${1:-$HOME/Workspace/codes/typeflux}"
        echo "📁 目标目录: $TARGET_DIR"

        for repo in "$@"; do
            git clone "$repo"
        done
        """
        let store = AskConversationWorkspaceStore(rootURL: base.appendingPathComponent("workspaces"))
        let fixture = try AskTestFixture(workspaces: store)
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "preview", title: "Shell file preview", revision: 1, updatedAt: Date(), messages: [
            .init(id: "message", role: "assistant", text: "outputs/clone-typeflux.sh", createdAt: Date())
        ]))
        await fixture.model.select("preview")
        let owner = try XCTUnwrap(fixture.model.credentials(for: "preview")).account
        let root = try await store.ensure(owner: owner, conversationId: "preview")
        let path = "outputs/clone-typeflux.sh"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outputs"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: root.appendingPathComponent(path))
        let target = try AskSidePanelFileAccess.resolve(path, workspaceRoot: root)
        let panel = AskSidePanel(browser: nil)
        let suite = "shell-file-tab-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ask.sidebarCollapsed")
        let view = AskConversationView(model: fixture.model, sidePanel: panel).defaultAppStorage(defaults)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let toggle = try AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.sidePanel", in: window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouse(type, toggle))
        }
        try await Task.sleep(for: .milliseconds(250))
        try panel.open(target, conversationId: "preview")
        for width in [920, 1120, 1400] {
            window.setContentSize(NSSize(width: width, height: 640))
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let more = try AskWorkspaceTestAccessibility.frame(identifier: "ask.sidePanel.file.more", in: window)
            let reference = try AskWorkspaceTestAccessibility.frame(identifier: "ask.sidePanel.file.reference", in: window)
            XCTAssertLessThanOrEqual(more.width, TFControlSize.regular.height + 1)
            XCTAssertEqual(more.midY, reference.midY, accuracy: 2)
            XCTAssertLessThan(CGFloat(width) - more.maxX, 22)
        }
        window.setContentSize(NSSize(width: 1120, height: 640))
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        func source(in view: NSView) -> AskWorkflowTextView? {
            view as? AskWorkflowTextView ?? view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        let textView = try XCTUnwrap(source(in: host))
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.string, script)
        let raw = script as NSString
        let keyword = raw.range(of: "echo")
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil)
                       as? NSColor, AskWorkflowSyntaxHighlighter.Token.keyword.color)
        let range = raw.range(of: "for repo in \"$@\"; do\n    git clone \"$repo\"")
        XCTAssertNotEqual(range.location, NSNotFound)
        // Route the same AppKit drag events as a pointer moving across two lines.
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        func point(_ index: Int) -> NSPoint {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return textView.convert(NSPoint(x: textView.textContainerOrigin.x + bounds.minX + 0.1,
                                            y: textView.textContainerOrigin.y + bounds.midY), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let start = point(range.location), end = point(NSMaxRange(range))
        let hit = host.hitTest(host.convert(start, from: nil))
        XCTAssertTrue(hit === textView, "Expected the source text at \(start), hit \(String(describing: hit.map { type(of: $0) })), source bounds \(textView.bounds)")
        let down = try mouse(.leftMouseDown, start)
        let drag = try mouse(.leftMouseDragged, end)
        let up = try mouse(.leftMouseUp, end)
        NSApp.postEvent(drag, atStart: false)
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
        // AppKit may begin text tracking during mouseDown or on the subsequent drag.
        // Dispatch any events it did not consume in its nested tracking loop.
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast,
                                         inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === textView, "Responder: \(String(describing: window.firstResponder.map { type(of: $0) }))")
        XCTAssertEqual(textView.selectedRange(), range)
        guard window.firstResponder === textView, textView.selectedRange() == range else { return }
        let board = NSPasteboard.general
        let original: [NSPasteboardItem] = board.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        } ?? []
        defer { board.clearContents(); board.writeObjects(original) }
        board.clearContents()
        func command(_ letter: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        try command("c", code: 8)
        XCTAssertTrue(board.string(forType: .string) == raw.substring(with: range))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 3000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PREVIEW_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("shell-file-tab-dark.png"))
        }
        try command("a", code: 0)
        try command("c", code: 8)
        XCTAssertTrue(board.string(forType: .string) == script)
        func checkToolbar(_ name: String) throws {
            let reload = try AskWorkspaceTestAccessibility.frame(identifier: "ask.sidePanel.file.reload", in: window)
            let more = try AskWorkspaceTestAccessibility.frame(identifier: "ask.sidePanel.file.more", in: window)
            XCTAssertEqual(more.size, reload.size)
            let rect = host.convert(reload.union(more).insetBy(dx: -3, dy: -3), from: nil).integral
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: image)
            // Sample the surface around the two glyphs. A native menu bezel visibly changes these pixels.
            func color(in button: NSRect, dx: CGFloat, dy: CGFloat) throws -> NSColor {
                let p = host.convert(NSPoint(x: button.midX + dx, y: button.midY + dy), from: nil)
                let x = Int((p.x - rect.minX) * CGFloat(image.pixelsWide) / rect.width)
                let y = Int((host.isFlipped ? p.y - rect.minY : rect.maxY - p.y) * CGFloat(image.pixelsHigh) / rect.height)
                return try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            }
            for dx: CGFloat in [-9, 9] {
                for dy: CGFloat in [-5, 5] {
                    let left = try color(in: reload, dx: dx, dy: dy)
                    let right = try color(in: more, dx: dx, dy: dy)
                    XCTAssertEqual(left.redComponent, right.redComponent, accuracy: 0.025, name)
                    XCTAssertEqual(left.greenComponent, right.greenComponent, accuracy: 0.025, name)
                    XCTAssertEqual(left.blueComponent, right.blueComponent, accuracy: 0.025, name)
                }
            }
            if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_PREVIEW_SNAPSHOTS"] {
                let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
        try checkToolbar("toolbar-before-open")
        let menuOpened = expectation(description: "File menu starts tracking")
        let observation = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            XCTAssertNotNil(menu.items.first { $0.submenu != nil })
            XCTAssertTrue(menu.items.contains { $0.keyEquivalent == "r" })
            menuOpened.fulfill()
            RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTracking() }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let center = try AskWorkspaceTestAccessibility.center(identifier: "ask.sidePanel.file.more", in: window)
        NSApp.sendEvent(try mouse(.leftMouseDown, center))
        NSApp.sendEvent(try mouse(.leftMouseUp, center))
        await fulfillment(of: [menuOpened], timeout: 2)
        try await Task.sleep(for: .milliseconds(200))
        try checkToolbar("toolbar-after-dismiss")
    }
}
