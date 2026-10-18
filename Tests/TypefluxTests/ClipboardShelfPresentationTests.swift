import AppKit
@testable import Typeflux
import SwiftUI
import XCTest

/// Renders the shelf with every entry kind and state, and drives the controller in shelf style.
/// Snapshots are written when `TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR` is set.
final class ClipboardShelfPresentationTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var controller: ClipboardPanelController!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardShelfPresentationTests")
        suite = "ClipboardShelfPresentationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        settings.clipboardPanelStyle = .shelf
        controller = ClipboardPanelController(settingsStore: settings)
        controller.reduceMotion = { true }
    }

    override func tearDown() {
        controller.dismiss()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entries() -> [ClipboardEntry] {
        var snippet = ClipboardTestSupport.entry(.text, text: "Best regards,\nTypeflux")
        snippet.snippet = ClipboardSnippet(name: "Signature", alias: "sign")
        return [snippet] + ClipboardTestSupport.allKindsEntries(in: directory)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = true) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_SNAPSHOT_DIR"] else { return }
        let canvas = NSImage(size: host.bounds.size)
        canvas.lockFocus()
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
        host.bounds.fill()
        rep.draw(in: host.bounds)
        canvas.unlockFocus()
        let data = try XCTUnwrap(canvas.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("shelf-\(name).png"))
    }

    // MARK: - Rendering

    @MainActor
    func testEveryCardKindDrawsSelectedMissingAndInBothAppearances() throws {
        for (missing, dark) in [(false, true), (false, false), (true, true)] {
            let model = ClipboardPanelModel()
            if missing { model.fileExists = { _ in false } }
            model.reset(entries: entries())
            for category in ClipboardCategory.allCases {
                model.category = category
                model.select(index: min(1, max(0, model.visibleEntries.count - 1)))
                let name = "\(category.rawValue)-\(dark ? "dark" : "light")\(missing ? "-missing" : "")"
                try render(ClipboardShelfView(model: model, focusRequest: 0),
                           size: NSSize(width: 1440, height: ClipboardShelfView.height), name: name, dark: dark)
            }
        }
    }

    @MainActor
    func testShelfStatesDraw() throws {
        let base = [
            ClipboardTestSupport.entry(.text, text: "Pinned note", sourceBundleID: "com.apple.Notes",
                                       sourceAppName: "Notes", isPinned: true),
            ClipboardTestSupport.entry(.text, text: "https://example.com/very/long/path",
                                       sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, text: "Meeting at 10", sourceBundleID: "com.apple.Safari",
                                       sourceAppName: "Safari")
        ]
        let states: [(String, [ClipboardEntry], (ClipboardPanelModel) -> Void)] = [
            ("paused", base, { $0.isRecordingPaused = true }),
            ("filtered", base, { $0.setAppFilter(ClipboardAppFilter(bundleID: "com.apple.Safari", name: "Safari")) }),
            ("editing", base, { $0.perform(.editBeforePaste, at: 2) }),
            ("snippet", base, { $0.perform(.saveSnippet, at: 2) }),
            ("confirm", base, { $0.requestClearUnpinned() }),
            ("notice", base, { $0.showNotice("Copied") }),
            ("search-empty", base, { $0.query = "nothing matches" }),
            ("empty", [], { _ in })
        ]
        for (name, entries, configure) in states {
            let model = ClipboardPanelModel()
            model.reset(entries: entries)
            configure(model)
            let editing = model.editingText != nil || model.snippetDraft != nil
            try render(ClipboardShelfView(model: model, focusRequest: 0),
                       size: NSSize(width: 1280, height: editing ? ClipboardShelfView.editingHeight : ClipboardShelfView.height),
                       name: name)
        }
    }

    @MainActor
    func testPreviewDrawsEveryKind() throws {
        let model = ClipboardPanelModel()
        model.reset(entries: entries())
        model.showsPreview = true
        for index in model.visibleEntries.indices {
            model.select(index: index)
            try render(ClipboardShelfPreview(model: model, thumbnails: ClipboardThumbnailSession()),
                       size: ClipboardShelfPreview.size, name: "preview-\(index)")
        }
    }

    func testCardEqualityIgnoresCallbacks() {
        let entry = ClipboardTestSupport.entry(.text, text: "a")
        let card = ClipboardShelfCard(entry: entry, index: 0, isSelected: false, isHovered: false, isMissing: false)
        var other = card
        other.onClick = { _ in XCTFail("not called") }
        XCTAssertEqual(card, other)
        XCTAssertNotEqual(card, ClipboardShelfCard(entry: entry, index: 0, isSelected: true, isHovered: false,
                                                   isMissing: false))
        XCTAssertNotEqual(card, ClipboardShelfCard(entry: entry, index: 0, isSelected: false, isHovered: false,
                                                   isMissing: false, number: 1))
    }

    func testLayoutPublishesOnlyChanges() {
        let layout = ClipboardShelfLayout()
        var values: [CGFloat?] = []
        let token = layout.$selectedCardMidX.dropFirst().sink { values.append($0) }
        layout.setSelectedCardMidX(100.2)
        layout.setSelectedCardMidX(99.9)
        layout.setSelectedCardMidX(nil)
        layout.setSelectedCardMidX(nil)
        token.cancel()
        XCTAssertEqual(values, [100, nil])
    }

    // MARK: - Controller

    @MainActor
    private func press(
        _ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false
    ) throws -> Bool {
        let panel = try XCTUnwrap(controller.presentedWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode
        ))
        return controller.handleKeyDown(event)
    }

    private func textModel(count: Int = 4) -> ClipboardPanelModel {
        let model = ClipboardPanelModel()
        model.reset(entries: (0 ..< count).map {
            ClipboardTestSupport.entry(.text, text: "item \($0)", sourceBundleID: "com.apple.Notes", sourceAppName: "Notes")
        })
        return model
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
    }

    @MainActor
    func testShelfOpensAlongTheBottomOfTheScreenAndArrowsMoveTheSelection() throws {
        let model = textModel()
        controller.present(model)
        XCTAssertEqual(controller.style, .shelf)
        let panel = try XCTUnwrap(controller.presentedWindow)
        let screen = try XCTUnwrap((panel.screen ?? NSScreen.main)?.visibleFrame)
        XCTAssertEqual(panel.frame, ClipboardPanelPlacement.shelfFrame(height: ClipboardShelfView.height, screen: screen))
        XCTAssertEqual(panel.alphaValue, 1, "Reduced motion shows the shelf at once")

        XCTAssertTrue(try press(124))
        XCTAssertTrue(try press(124))
        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertTrue(try press(123))
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertTrue(try press(124, flags: .command))
        XCTAssertEqual(model.selectedIndex, 3)
        XCTAssertTrue(try press(123, flags: .command))
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertFalse(try press(0, "a"), "Typing goes to the search field")
    }

    @MainActor
    func testSpaceAndVerticalArrowsShowThePreviewWindowAboveTheShelf() throws {
        let model = textModel()
        model.showsPreview = false
        controller.present(model)
        XCTAssertTrue(try press(49, " "))
        XCTAssertTrue(model.showsPreview)
        drainMainQueue()
        let preview = try XCTUnwrap(controller.presentedPreviewWindow)
        let panel = try XCTUnwrap(controller.presentedWindow)
        XCTAssertEqual(preview.frame.minY, panel.frame.maxY + ClipboardPanelPlacement.shelfMargin)
        XCTAssertEqual(preview.frame.size, ClipboardShelfPreview.size)
        XCTAssertTrue(panel.childWindows?.contains(preview) == true)
        XCTAssertFalse(preview.canBecomeKey)

        let shelfHeight = panel.frame.height
        model.perform(.editBeforePaste, at: 0)
        drainMainQueue()
        XCTAssertNil(controller.presentedPreviewWindow, "Editing covers the shelf; the preview steps aside")
        XCTAssertEqual(panel.frame.height, ClipboardShelfView.editingHeight, "The shelf grows to fit the editor")
        XCTAssertEqual(panel.frame.minY, ClipboardPanelPlacement.shelfFrame(height: 1, screen: try XCTUnwrap(
            (panel.screen ?? NSScreen.main)?.visibleFrame)).minY, "It grows upward from the same bottom edge")
        model.cancelEdit()
        drainMainQueue()
        XCTAssertEqual(panel.frame.height, shelfHeight)
        XCTAssertNotNil(controller.presentedPreviewWindow)
        model.perform(.saveSnippet, at: 0)
        drainMainQueue()
        XCTAssertEqual(panel.frame.height, ClipboardShelfView.editingHeight)
        model.cancelSnippetEdit()
        drainMainQueue()
        XCTAssertEqual(panel.frame.height, shelfHeight)

        XCTAssertTrue(try press(125))
        drainMainQueue()
        XCTAssertNil(controller.presentedPreviewWindow)
        XCTAssertTrue(try press(126))
        drainMainQueue()
        XCTAssertNotNil(controller.presentedPreviewWindow)

        controller.dismiss()
        XCTAssertNil(controller.presentedPreviewWindow, "Dismissing closes the preview too")
    }

    @MainActor
    func testConfirmationHoldsTheShelfArrows() throws {
        let model = textModel()
        controller.present(model)
        model.requestClearUnpinned()
        XCTAssertTrue(try press(124))
        XCTAssertTrue(try press(123))
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(try press(53))
        controller.dismiss()
        settings.clipboardPanelStyle = .list
        controller.present(model)
        model.requestClearUnpinned()
        XCTAssertFalse(try press(123), "The list leaves horizontal arrows to the search field")
        XCTAssertNotNil(model.pendingConfirmation)
    }

    @MainActor
    func testMouseWheelMovesTheSelectionOnlyOverTheShelf() throws {
        let model = textModel()
        controller.present(model)
        XCTAssertTrue(controller.handleShelfScroll(deltaX: 0, deltaY: -1, isPrecise: false))
        XCTAssertTrue(controller.handleShelfScroll(deltaX: 0, deltaY: -1, isPrecise: false))
        XCTAssertTrue(controller.handleShelfScroll(deltaX: 0, deltaY: 1, isPrecise: false))
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertFalse(controller.handleShelfScroll(deltaX: 0, deltaY: -1, isPrecise: true), "Trackpads scroll the rail")
        model.requestClearUnpinned()
        XCTAssertFalse(controller.handleShelfScroll(deltaX: 0, deltaY: -1, isPrecise: false))
        XCTAssertEqual(model.selectedIndex, 1)
        model.cancelPending()

        // Synthesized wheel events have no window, so they are never the shelf's.
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                            wheel1: -1, wheel2: 0, wheel3: 0))
        XCTAssertFalse(controller.handleScrollWheel(try XCTUnwrap(NSEvent(cgEvent: cgEvent))))

        controller.dismiss()
        XCTAssertFalse(controller.handleShelfScroll(deltaX: 0, deltaY: -1, isPrecise: false))
    }

    @MainActor
    func testSwitchingBackToTheListRestoresItsFrameAndKeys() throws {
        let model = textModel()
        controller.present(model)
        controller.dismiss()
        settings.clipboardPanelStyle = .list
        model.showsPreview = false
        controller.present(model)
        XCTAssertEqual(controller.style, .list)
        let panel = try XCTUnwrap(controller.presentedWindow)
        XCTAssertEqual(panel.frame.size, ClipboardPanelView.size(showsPreview: false))
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(try press(125))
        XCTAssertEqual(model.selectedIndex, 1, "The list moves with the vertical arrows")
        XCTAssertFalse(try press(49, " "), "Space is typed into the list's search")
    }

    @MainActor
    func testSlideInEndsInPlaceAndOpaque() throws {
        controller.reduceMotion = { false }
        let model = textModel()
        controller.present(model)
        let panel = try XCTUnwrap(controller.presentedWindow)
        let screen = try XCTUnwrap((panel.screen ?? NSScreen.main)?.visibleFrame)
        let target = ClipboardPanelPlacement.shelfFrame(height: ClipboardShelfView.height, screen: screen)
        XCTAssertLessThan(panel.frame.minY, target.minY + 0.5, "The slide starts at or below its final frame")
        let settled = expectation(description: "slide settles")
        func poll(_ remaining: Int) {
            if panel.alphaValue == 1, panel.frame == target || remaining == 0 { settled.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(remaining - 1) }
        }
        poll(60)
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(panel.frame, target)
        XCTAssertEqual(panel.alphaValue, 1)
    }
}
