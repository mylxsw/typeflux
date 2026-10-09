import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// Renders the panel with every entry kind and drives the AppKit controller.
final class ClipboardPanelRenderingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardPanelRenderingTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func allKindsEntries() -> [ClipboardEntry] {
        let png = directory.appendingPathComponent("shot.png")
        let pngData = ClipboardTestSupport.imageData(width: 40, height: 30)
        FileManager.default.createFile(atPath: png.path, contents: pngData)
        let pdf = ClipboardTestSupport.makeFile(named: "report.pdf", in: directory)
        let movie = ClipboardTestSupport.makeFile(named: "demo.mov", in: directory)
        let audio = ClipboardTestSupport.makeFile(named: "talk.m4a", in: directory)
        let doc = ClipboardTestSupport.makeFile(named: "plan.docx", in: directory)
        return [
            ClipboardTestSupport.entry(.voice, text: "spoken words", isPinned: true),
            ClipboardTestSupport.entry(.text, text: "plain text", sourceAppName: "Notes"),
            ClipboardTestSupport.entry(.link, text: "https://example.com"),
            ClipboardTestSupport.entry(.code, text: "func a() {\n}\n"),
            ClipboardTestSupport.entry(.image, imagePath: png.path, imagePixelSize: CGSize(width: 40, height: 30)),
            ClipboardTestSupport.entry(.images, filePaths: [png.path, png.path]),
            ClipboardTestSupport.entry(.pdf, filePaths: [pdf.path], byteSize: 16),
            ClipboardTestSupport.entry(.video, filePaths: [movie.path]),
            ClipboardTestSupport.entry(.audio, filePaths: [audio.path]),
            ClipboardTestSupport.entry(.document, filePaths: [doc.path]),
            ClipboardTestSupport.entry(.files, filePaths: [pdf.path, doc.path, "/missing/archive.zip"])
        ]
    }

    func testPanelRendersEveryKindSelected() {
        let model = ClipboardPanelModel()
        model.reset(entries: allKindsEntries())
        for index in model.visibleEntries.indices {
            model.select(index: index)
            let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: index))
            host.frame = NSRect(x: 0, y: 0, width: ClipboardPanelView.width, height: ClipboardPanelView.height)
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        model.query = "nothing matches"
        model.showNotice("notice")
        let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: 0))
        host.frame = NSRect(x: 0, y: 0, width: ClipboardPanelView.width, height: ClipboardPanelView.height)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.visibleEntries.isEmpty)
    }

    /// Writes PNG snapshots for review when `TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR` is set.
    @MainActor
    func testWritesReviewSnapshotsWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR to write snapshots")
        }
        let model = ClipboardPanelModel()
        var entries = allKindsEntries()
        entries[1] = ClipboardTestSupport.entry(
            .text, date: Date().addingTimeInterval(-120),
            text: "可以开始开发了。需要注意的是，官方模型只是作为一种方便用户接入和配置的方式。", sourceAppName: "Linear"
        )
        model.reset(entries: entries)
        for (name, appearance, selection) in [
            ("dark-text", NSAppearance.Name.darkAqua, 1), ("light-image", .aqua, 4), ("dark-pdf", .darkAqua, 6),
            ("dark-files", .darkAqua, 10)
        ] {
            model.select(index: selection)
            let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: 0))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: ClipboardPanelView.width, height: ClipboardPanelView.height)
            host.layoutSubtreeIfNeeded()
            // Let thumbnails load.
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let canvas = NSImage(size: host.bounds.size)
            canvas.lockFocus()
            (appearance == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
            NSBezierPath(roundedRect: host.bounds, xRadius: 16, yRadius: 16).fill()
            rep.draw(in: host.bounds)
            canvas.unlockFocus()
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.tiffRepresentation))?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("clipboard-\(name).png"))
        }
    }

    func testThumbnailsAreGeneratedAndCached() async {
        let png = directory.appendingPathComponent("thumb.png")
        let pngData = ClipboardTestSupport.imageData(width: 300, height: 200)
        FileManager.default.createFile(atPath: png.path, contents: pngData)
        let provider = ClipboardThumbnailProvider()

        XCTAssertNil(provider.cachedThumbnail(for: png, maxPixelSize: 64))
        let image = await provider.thumbnail(for: png, maxPixelSize: 64)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(image?.size.width ?? 999, 64)
        XCTAssertNotNil(provider.cachedThumbnail(for: png, maxPixelSize: 64))
        let missing = await provider.thumbnail(for: directory.appendingPathComponent("none.png"), maxPixelSize: 64)
        XCTAssertNil(missing)
    }

    func testControllerPresentsHandlesKeysAndDismisses() throws {
        let suite = "ClipboardPanelRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let controller = ClipboardPanelController(settingsStore: settings)
        let model = ClipboardPanelModel()
        var actions: [ClipboardEntryAction] = []
        var dismissed = 0
        model.onAction = { action, _ in actions.append(action) }
        model.onDismiss = { dismissed += 1 }
        model.reset(entries: Array(allKindsEntries().prefix(4)))

        XCTAssertFalse(controller.isPresented)
        controller.present(model)
        XCTAssertTrue(controller.isPresented)

        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.isVisible && $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.clipboard"
        })
        let screen = try XCTUnwrap(window.screen)
        XCTAssertEqual(window.frame.maxY,
                       AskLauncherPlacement.top(on: screen.visibleFrame) - AskMetrics.launcherGutter)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(window.frame.size, NSSize(width: 640, height: 560))

        // Reopening follows the launcher's saved vertical position on this display.
        settings.askLauncherPosition = .lastPosition
        settings.askLauncherAnchors = [
            AskLauncherPlacement.key(for: screen): .init(left: 100, fromTop: 90)
        ]
        controller.dismiss()
        controller.present(model)
        XCTAssertEqual(window.frame.maxY, screen.visibleFrame.maxY - 90 - AskMetrics.launcherGutter)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 0.5)

        settings.askLauncherPosition = .center
        controller.dismiss()
        controller.present(model)
        XCTAssertEqual(window.frame.maxY,
                       AskLauncherPlacement.top(on: screen.visibleFrame) - AskMetrics.launcherGutter)
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
            return controller.handleKeyDown(event)
        }

        XCTAssertTrue(key(125, ""))
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertTrue(key(126, ""))
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(key(48, "\t"))
        XCTAssertEqual(model.category, .text)
        XCTAssertTrue(key(48, "\t", .shift))
        XCTAssertEqual(model.category, .all)
        XCTAssertTrue(key(35, "p", .command))
        XCTAssertTrue(key(19, "2", .command))
        XCTAssertTrue(key(36, "\r"))
        XCTAssertFalse(key(0, "a"))
        XCTAssertEqual(actions, [.togglePin, .paste, .paste])
        XCTAssertTrue(key(53, "\u{1b}"))
        XCTAssertEqual(dismissed, 1)

        controller.toggleQuickLook(urls: [])
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(key(125, ""))
    }
}
