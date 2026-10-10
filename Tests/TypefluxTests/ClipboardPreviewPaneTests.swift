import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// The preview pane, the panel widening for it, and the list's cost with a large history.
final class ClipboardPreviewPaneTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardPreviewPaneTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testDetailRowsDescribeTheEntry() {
        let text = ClipboardTestSupport.entry(.text, text: "hello", sourceAppName: "Notes")
        let textRows = ClipboardPreviewPane.detailRows(for: text, info: nil)
        XCTAssertEqual(textRows.map(\.label), [
            L("clipboard.preview.type"), L("clipboard.preview.source"),
            L("clipboard.preview.copiedAt"), L("clipboard.preview.size")
        ])
        XCTAssertEqual(textRows.first?.value, [L("clipboard.kind.text"), L("clipboard.entry.characters", 5)].joined(separator: " · "))
        XCTAssertEqual(textRows.last?.value, L("clipboard.entry.characters", 5))

        let voice = ClipboardTestSupport.entry(.voice, text: "spoken")
        XCTAssertEqual(ClipboardPreviewPane.detailRows(for: voice, info: nil)[1].value, "Typeflux")

        let image = ClipboardTestSupport.entry(
            .image, imagePath: "/tmp/a.png", imagePixelSize: CGSize(width: 1400, height: 1116), byteSize: 254_000,
            sourceAppName: "ChatGPT"
        )
        let imageRows = ClipboardPreviewPane.detailRows(for: image, info: nil)
        XCTAssertEqual(imageRows.first?.value, "PNG · 1400×1116")
        XCTAssertEqual(imageRows.last?.label, L("clipboard.preview.size"))

        let pdf = ClipboardTestSupport.entry(.pdf, filePaths: ["/tmp/report.pdf"], byteSize: 2048)
        let pdfRows = ClipboardPreviewPane.detailRows(for: pdf, info: ClipboardMediaInfo(pageCount: 3))
        XCTAssertEqual(pdfRows.first?.value, ["PDF", L("clipboard.preview.pages", 3)].joined(separator: " · "))
        XCTAssertEqual(pdfRows.last, .init(label: L("clipboard.preview.location"), value: "/tmp/report.pdf"))
        XCTAssertFalse(pdfRows.map(\.label).contains(L("clipboard.preview.source")))
    }

    func testPreviewTextIsCutForVeryLongClips() {
        XCTAssertEqual(ClipboardPreviewPane.previewText("short"), "short")
        let wide = String(repeating: "字", count: 8000)
        XCTAssertEqual(ClipboardPreviewPane.previewText(wide), wide, "Long in bytes but not in characters")
        let long = String(repeating: "a", count: 25000)
        let cut = ClipboardPreviewPane.previewText(long)
        XCTAssertEqual(cut.count, 20001)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    @MainActor
    func testPaneDrawsEveryKind() async throws {
        var entries = ClipboardTestSupport.allKindsEntries(in: directory)
        entries.append(ClipboardTestSupport.entry(.code, text: "let x = 1\nprint(x)"))
        for missing in [false, true] {
            for entry in entries + [nil] as [ClipboardEntry?] {
                let host = NSHostingView(rootView: ClipboardPreviewPane(entry: entry, isMissing: missing)
                    .frame(height: 480))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(x: 0, y: 0, width: ClipboardPreviewPane.width, height: 480)
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
            }
        }
    }

    @MainActor
    func testPanelRendersWithThePreviewPane() throws {
        let model = ClipboardPanelModel()
        model.previewDelay = 0
        model.reset(entries: ClipboardTestSupport.allKindsEntries(in: directory))
        model.showsPreview = true
        let size = ClipboardPanelView.size(showsPreview: true)
        XCTAssertEqual(size.width, ClipboardPanelView.width + ClipboardPreviewPane.width)
        XCTAssertEqual(ClipboardPanelView.size(showsPreview: false).width, ClipboardPanelView.width)
        for index in model.visibleEntries.indices {
            model.select(index: index)
            let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: index))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
    }

    @MainActor
    func testControllerWidensThePanelForThePreview() async throws {
        let suite = "ClipboardPreviewPane.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ClipboardPanelController(settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismiss() }
        let model = ClipboardPanelModel()
        model.reset(entries: (1 ... 3).map { ClipboardTestSupport.entry(.text, text: "item \($0)") })
        controller.present(model)
        let panel = try XCTUnwrap(ClipboardTestSupport.presentedPanel())
        XCTAssertEqual(panel.frame.width, ClipboardPanelView.width)
        let top = panel.frame.maxY
        let left = panel.frame.minX

        let toggle = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\\",
            charactersIgnoringModifiers: "\\", isARepeat: false, keyCode: 42
        ))
        XCTAssertTrue(controller.handleKeyDown(toggle))
        XCTAssertTrue(model.showsPreview)
        XCTAssertEqual(panel.frame.width, ClipboardPanelView.size(showsPreview: true).width)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
        XCTAssertLessThanOrEqual(abs(panel.frame.minX - left), 1, "The list stays put; the pane opens to the right")

        model.togglePreview()
        XCTAssertEqual(panel.frame.width, ClipboardPanelView.width)

        // Presenting again with the pane on opens wide straight away.
        controller.dismiss()
        model.showsPreview = true
        controller.present(model)
        XCTAssertEqual(try XCTUnwrap(ClipboardTestSupport.presentedPanel()).frame.width,
                       ClipboardPanelView.size(showsPreview: true).width)
    }

    /// Writes PNG snapshots of the panel with its preview pane when `TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR` is set.
    @MainActor
    func testWritesPreviewSnapshotsWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR to write snapshots")
        }
        var entries = ClipboardTestSupport.allKindsEntries(in: directory)
        entries.insert(ClipboardTestSupport.entry(
            .text, date: Date().addingTimeInterval(-120),
            text: "可以开始开发了。需要注意的是，官方模型只是作为一种方便用户接入和配置的方式。\n\n第二段：预览栏显示完整文本，列表行保持单行。",
            sourceAppName: "Linear"
        ), at: 0)
        for name in ["text", "image"] {
            let model = ClipboardPanelModel()
            model.previewDelay = 0
            model.showsPreview = true
            model.reset(entries: entries)
            let kind: ClipboardEntryKind = name == "image" ? .image : .text
            model.select(index: try XCTUnwrap(model.visibleEntries.firstIndex { $0.kind == kind }))
            let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: 0))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: ClipboardPanelView.size(showsPreview: true))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let canvas = NSImage(size: host.bounds.size)
            canvas.lockFocus()
            NSColor(white: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: host.bounds, xRadius: 16, yRadius: 16).fill()
            rep.draw(in: host.bounds)
            canvas.unlockFocus()
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("clipboard-preview-\(name).png"))
        }
    }

    /// 2000 entries: filtering and rebuilding rows on a keystroke stays far below a frame budget's
    /// worth of work per operation on CI hardware; the bound is generous to avoid flakiness.
    func testFilteringALargeHistoryIsFast() {
        let now = Date()
        let entries = (0 ..< 2000).map { index in
            ClipboardTestSupport.entry(
                .text, date: now.addingTimeInterval(-Double(index) * 600),
                text: "Clipboard entry number \(index) " + String(repeating: "lorem ipsum ", count: 20),
                sourceAppName: index.isMultiple(of: 3) ? "Safari" : "Notes"
            )
        }
        let model = ClipboardPanelModel()
        model.reset(entries: entries)
        XCTAssertEqual(model.rows.count, 2000)

        let start = Date()
        for query in ["n", "nu", "num", "numb", "number 1", "safari", ""] {
            model.query = query
        }
        for _ in 0 ..< 200 {
            model.moveSelection(by: 1)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(model.selectedIndex, 200)
        XCTAssertLessThan(elapsed, 1.0, "7 searches and 200 moves over 2000 entries took \(elapsed)s")
    }
}
