import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// Pinned screenshots, the More menu and the movable toolbar.
@MainActor
final class ScreenshotPinTests: XCTestCase {
    private typealias Key = ScreenshotOverlayView.Key

    // MARK: Fakes

    private final class Pins: ScreenshotPinPresenting {
        private(set) var pinned: [(image: CGImage, scale: CGFloat, rect: CGRect)] = []
        var onEvent: ((ScreenshotPinEvent) -> Void)?
        var clickThroughCount = 0
        private(set) var restores = 0
        private(set) var closes = 0

        func pin(_ image: CGImage, scale: CGFloat, at rect: CGRect,
                 onEvent: @escaping (ScreenshotPinEvent) -> Void) {
            pinned.append((image, scale, rect))
            self.onEvent = onEvent
        }

        var pinCount: Int { pinned.count }
        func restoreMouse() { restores += 1 }
        func closeAll() { closes += 1 }
    }

    private final class Overlay: ScreenshotOverlayPresenting {
        var onEvent: ((ScreenshotOverlayEvent) -> Void)?
        private(set) var dismissals = 0
        func present(_ snapshot: ScreenSnapshot, onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
            self.onEvent = onEvent
        }
        func selectFullScreen() {}
        func startScrollCapture() {}
        func finish(_ action: ScreenshotOutputAction) {
            onEvent?(.finish(action, displayID: 1, rect: CGRect(x: 10, y: 20, width: 50, height: 30)))
        }
        func dismiss() { dismissals += 1 }
    }

    private final class Guide: ScreenshotPermissionGuidePresenting {
        func show(actions: ScreenshotPermissionGuideActions) {}
        func dismiss() {}
    }

    private final class Toasts: ScreenshotToastPresenting {
        private(set) var shown: [ScreenshotToast] = []
        func show(_ toast: ScreenshotToast) { shown.append(toast) }
    }

    private final class Output: ScreenshotOutputting {
        private(set) var copied: [Data] = []
        private(set) var saved: [Data] = []
        var saveFails = false
        func copy(_ png: Data) -> Bool {
            copied.append(png)
            return true
        }
        func copy(text: String) {}
        func save(_ png: Data, in directory: URL, date: Date) throws -> URL {
            struct Full: LocalizedError { var errorDescription: String? { "full" } }
            if saveFails { throw Full() }
            saved.append(png)
            return directory.appendingPathComponent("shot.png")
        }
    }

    private final class LongEditor: ScreenshotLongImagePresenting {
        private(set) var presented: [(display: ScreenSnapshot.Display, screen: CGRect)] = []
        var onEvent: ((ScreenshotOverlayEvent) -> Void)?
        func present(_ image: ScreenSnapshot.Display, on screen: CGRect,
                     onEvent: @escaping (ScreenshotOverlayEvent) -> Void) {
            presented.append((image, screen))
            self.onEvent = onEvent
        }
        func dismiss() { onEvent = nil }
    }

    private let pins = Pins()
    private let overlay = Overlay()
    private let toasts = Toasts()
    private let output = Output()
    private let longEditor = LongEditor()

    private func makeCoordinator() -> ScreenshotCoordinator {
        let snapshot = ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2,
                  image: ScreenCaptureTestSupport.image(width: 400, height: 200))
        ], windows: [])
        return ScreenshotCoordinator(
            capture: FakeScreenCapturer(.success(snapshot)), permission: FakeScreenCapturePermission(granted: true),
            overlay: overlay, permissionGuide: Guide(), toast: toasts, output: output,
            saveDirectory: { URL(fileURLWithPath: "/tmp/shots") },
            encode: { image, scale in Data("\(image.width)x\(image.height)@\(Int(scale))".utf8) },
            longImageEditor: longEditor, pins: pins
        )
    }

    private func started(_ coordinator: ScreenshotCoordinator) async {
        coordinator.start()
        await coordinator.pendingTask?.value
        overlay.onEvent?(.committed)
    }

    // MARK: Pin state

    func testZoomOpacityAndTheFrameKeepItsTopLeftCorner() {
        var state = ScreenshotPinState()
        XCTAssertEqual(state.zoomLabel, "100%")
        state.zoom(by: -3)
        XCTAssertEqual(state.zoom, 0.7, accuracy: 0.0001)
        state.zoom(by: -20)
        XCTAssertEqual(state.zoom, 0.1, "Not smaller than 10 %")
        state.zoom(by: 100)
        XCTAssertEqual(state.zoom, 4)
        state.zoom = 1

        state.scroll(by: 24, precise: true, adjustsOpacity: false)
        XCTAssertEqual(state.zoom, 1.2, accuracy: 0.0001, "Two steps of trackpad scrolling")
        state.scroll(by: -0.5, precise: false, adjustsOpacity: false)
        XCTAssertEqual(state.zoom, 1.1, accuracy: 0.0001, "A notch is a step")
        state.scroll(by: 0, precise: false, adjustsOpacity: false)
        XCTAssertEqual(state.zoom, 1.1, accuracy: 0.0001)
        state.scroll(by: -3, precise: false, adjustsOpacity: true)
        XCTAssertEqual(state.opacity, 0.9, accuracy: 0.0001, "⌥ changes the opacity")
        state.changeOpacity(by: -20)
        XCTAssertEqual(state.opacity, 0.2)

        state.zoom = 0.5
        let frame = state.frame(keepingTopLeftOf: CGRect(x: 100, y: 500, width: 400, height: 200),
                                imageSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(frame, CGRect(x: 100, y: 600, width: 200, height: 100))
        XCTAssertEqual(state.zoomLabel, "50%")
    }

    // MARK: Pin controller and view

    func testPinningOpensAFloatingPanelWhereTheRegionWas() throws {
        let controller = ScreenshotPinController(primaryDisplayHeight: { 900 })
        var events: [String] = []
        controller.pin(ScreenCaptureTestSupport.image(width: 400, height: 200), scale: 2,
                       at: CGRect(x: 100, y: 50, width: 200, height: 100)) { event in
            switch event {
            case .copy: events.append("copy")
            case .save: events.append("save")
            case let .edit(_, scale, _): events.append("edit@\(Int(scale))")
            }
        }
        defer { controller.closeAll() }
        let panel = try XCTUnwrap(controller.panels.first)
        XCTAssertEqual(panel.frame, CGRect(x: 100, y: 750, width: 200, height: 100), "Flipped to AppKit")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(controller.pinCount, 1)
        let view = try XCTUnwrap(controller.views.first)
        XCTAssertEqual(view.imageSize, CGSize(width: 200, height: 100))

        view.state.zoom = 0.5
        XCTAssertEqual(panel.frame, CGRect(x: 100, y: 800, width: 100, height: 50), "Zoomed from its top-left")
        view.state.opacity = 0.4
        XCTAssertEqual(panel.alphaValue, 0.4, accuracy: 0.01)
        view.state.clickThrough = true
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(controller.clickThroughCount, 1)
        controller.restoreMouse()
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(controller.clickThroughCount, 0)

        XCTAssertTrue(view.handleKey(Key.keyC, modifiers: [.command]))
        XCTAssertTrue(view.handleKey(Key.keyS, modifiers: [.command]))
        XCTAssertTrue(view.handleKey(ScreenshotPinView.zeroKeyCode, modifiers: [.command]))
        XCTAssertEqual(view.state.zoom, 1)
        XCTAssertFalse(view.handleKey(Key.keyC, modifiers: []))
        XCTAssertEqual(events, ["copy", "save"])

        view.perform(.edit)
        XCTAssertEqual(events, ["copy", "save", "edit@2"])
        XCTAssertEqual(controller.pinCount, 0, "Marking up again takes the pin down")
    }

    func testThePinsBarMenuAndKeys() throws {
        let controller = ScreenshotPinController(primaryDisplayHeight: { 900 })
        var copies = 0
        controller.pin(ScreenCaptureTestSupport.image(width: 600, height: 300), scale: 1,
                       at: CGRect(x: 0, y: 0, width: 600, height: 300)) { if case .copy = $0 { copies += 1 } }
        controller.pin(ScreenCaptureTestSupport.image(width: 100, height: 50), scale: 1,
                       at: CGRect(x: 0, y: 0, width: 100, height: 50)) { _ in }
        let wide = try XCTUnwrap(controller.views.first)
        let narrow = try XCTUnwrap(controller.views.last)

        wide.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        )))
        XCTAssertTrue(wide.isHovered)
        XCTAssertEqual(wide.bar?.isHidden, false, "The bar shows on hover")
        narrow.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        )))
        XCTAssertNil(narrow.bar, "Too narrow for the bar; the menu has everything")

        wide.perform(.zoomIn)
        XCTAssertEqual(wide.state.zoom, 1.1, accuracy: 0.0001)
        wide.perform(.zoomOut)
        wide.perform(.opacity)
        XCTAssertEqual(wide.state.opacity, 0.5)
        wide.perform(.opacity)
        XCTAssertEqual(wide.state.opacity, 1)
        wide.perform(.copy)
        XCTAssertEqual(copies, 1)
        wide.perform(.clickThrough)
        XCTAssertTrue(wide.state.clickThrough)
        XCTAssertEqual(wide.bar?.isHidden, true, "No bar on a pin that lets clicks through")

        let menu = narrow.contextMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 6)
        let close = try XCTUnwrap(menu.items.last)
        menu.performActionForItem(at: menu.index(of: close))
        XCTAssertEqual(controller.pinCount, 1, "Closed from its menu")
        XCTAssertTrue(wide.handleKey(Key.escape, modifiers: []))
        XCTAssertEqual(controller.pinCount, 0)
        XCTAssertEqual(ScreenshotPinBar.Action.allCases.count, 8)
        _ = NSHostingView(rootView: ScreenshotPinBar(state: ScreenshotPinState()) { _ in }).fittingSize
    }

    // MARK: Coordinator

    func testPinningHandsTheRenderedImageToThePinsAndEndsTheSession() async throws {
        let sut = makeCoordinator()
        await started(sut)
        overlay.finish(.pin)
        XCTAssertEqual(sut.state, .idle)
        let pinned = try XCTUnwrap(pins.pinned.first)
        XCTAssertEqual(pinned.rect, CGRect(x: 10, y: 20, width: 50, height: 30))
        XCTAssertEqual(pinned.scale, 2)
        XCTAssertEqual(pinned.image.width, 100, "The region at the display's pixels")

        // The pin's copy and save work after the session ended.
        pins.onEvent?(.copy(pinned.image, scale: 2))
        await sut.pinTask?.value
        pins.onEvent?(.save(pinned.image, scale: 2))
        await sut.pinTask?.value
        XCTAssertEqual(output.copied.count, 1)
        XCTAssertEqual(output.saved.count, 1)
        XCTAssertEqual(toasts.shown, [.copied, .saved(URL(fileURLWithPath: "/tmp/shots/shot.png"))])

        // Marking up again opens the long image editor on the pin's screen.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        pins.onEvent?(.edit(pinned.image, scale: 2, screen: screen))
        XCTAssertEqual(sut.state, .editingLongImage)
        XCTAssertEqual(longEditor.presented.first?.screen, screen)
        XCTAssertEqual(longEditor.presented.first?.display.frame, CGRect(x: 0, y: 0, width: 50, height: 30))
        pins.onEvent?(.edit(pinned.image, scale: 2, screen: screen))
        XCTAssertEqual(toasts.shown.last, .busy, "Not while another screenshot is open")
        XCTAssertEqual(longEditor.presented.count, 1)

        // A long image is not pinned.
        longEditor.onEvent?(.finish(.pin, displayID: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 30)))
        XCTAssertEqual(pins.pinned.count, 1)
        XCTAssertEqual(sut.state, .editingLongImage)
        longEditor.onEvent?(.finish(.copyAndSave, displayID: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 30)))
        await sut.pendingTask?.value
        XCTAssertEqual(output.copied.count, 2)
        XCTAssertEqual(output.saved.count, 2, "Copied and saved")
        XCTAssertEqual(sut.state, .idle)
    }

    func testCopyAndSaveStillCopiesWhenSavingFails() async {
        let sut = makeCoordinator()
        await started(sut)
        output.saveFails = true
        overlay.finish(.copyAndSave)
        await sut.pendingTask?.value
        XCTAssertEqual(output.copied.count, 1, "Copied once, not again as the fallback")
        XCTAssertEqual(toasts.shown, [.savedAsCopy(reason: "full")])

        let failing = ScreenshotCoordinator(
            capture: FakeScreenCapturer(.failure(ScreenCaptureError.permissionDenied)),
            permission: FakeScreenCapturePermission(granted: true), overlay: overlay, permissionGuide: Guide(),
            toast: toasts, output: output, saveDirectory: { URL(fileURLWithPath: "/tmp") },
            encode: { _, _ in throw ScreenshotExportError.encodingFailed }, pins: pins
        )
        failing.handlePin(.copy(ScreenCaptureTestSupport.image(width: 4, height: 4), scale: 1))
        await failing.pinTask?.value
        XCTAssertEqual(toasts.shown.last, .failed)
    }

    // MARK: Overlay

    private func makeView(scanner: (any ScreenshotSensitiveInfoScanning)? = nil)
        -> (ScreenshotOverlayView, () -> [ScreenshotOverlayView.LocalEvent]) {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 900), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 1600, height: 900))
        let view = ScreenshotOverlayView(display: display, windows: [], sensitiveScanner: scanner)
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        view.mouseDown(at: CGPoint(x: 600, y: 100), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 1400, y: 300))
        view.mouseUp(at: CGPoint(x: 1400, y: 300))
        return (view, { events })
    }

    func testPinKeysAndButtonsFinishWithThePin() {
        let (view, events) = makeView()
        let region = CGRect(x: 600, y: 100, width: 800, height: 200)
        XCTAssertTrue(view.handleKeyDown(Key.keyF, modifiers: []))
        XCTAssertTrue(view.handleKeyDown(Key.returnKey, modifiers: [.option]))
        view.toolbarModel.perform(.pin)
        view.toolbarModel.perform(.copyAndSave)
        XCTAssertEqual(events().filter { $0 != .committed },
                       [.finish(.pin, region, []), .finish(.copyAndSave, region, []), .finish(.pin, region, []),
                        .finish(.copyAndSave, region, [])])
        XCTAssertTrue(view.toolbarModel.state.showsPin)
    }

    func testTheMoreMenuMovesTheToolbarAndResetsStyles() throws {
        let (view, _) = makeView()
        let toolbar = try XCTUnwrap(view.toolbar)
        XCTAssertGreaterThan(toolbar.frame.minY, 300 - ScreenshotOverlayView.toolbarShadowInset, "Below")

        view.toolbarModel.perform(.toggleMoreMenu)
        XCTAssertTrue(view.toolbarModel.state.showsMoreMenu)
        let height = toolbar.frame.height
        view.toolbarModel.perform(.toggleToolbarPlacement)
        XCTAssertFalse(view.showsMoreMenu, "A choice closes the menu")
        XCTAssertLessThan(toolbar.frame.height, height)
        XCTAssertLessThan(toolbar.frame.maxY, 100 + ScreenshotOverlayView.toolbarShadowInset, "Above the region")
        XCTAssertTrue(view.editor.toolStyles.prefersToolbarAbove)

        view.toolbarModel.perform(.tool(.pen))
        view.toolbarModel.perform(.color(.teal))
        view.toolbarModel.perform(.toggleMoreMenu)
        view.toolbarModel.perform(.resetStyles)
        XCTAssertEqual(view.editor.toolStyles[.pen].color, .red)
        XCTAssertEqual(view.editor.toolStyles.recentColors, [.teal], "Recent colors stay")
        XCTAssertTrue(view.editor.toolStyles.prefersToolbarAbove, "So does the toolbar's place")
        XCTAssertFalse(view.showsMoreMenu)

        view.toolbarModel.perform(.toggleMoreMenu)
        view.toolbarModel.perform(.toggleColorPanel)
        view.toolbarModel.perform(.toggleMoreMenu)
        XCTAssertFalse(view.showsColorPanel, "One panel at a time")
    }

    func testTheGripDragsTheToolbarAndKeepsItOnTheDisplay() throws {
        let (view, _) = makeView()
        let toolbar = try XCTUnwrap(view.toolbar)
        let start = toolbar.frame
        view.toolbarModel.perform(.dragToolbar(CGSize(width: -40, height: 20), ended: false))
        view.toolbarModel.perform(.dragToolbar(CGSize(width: -80, height: 30), ended: true))
        XCTAssertEqual(toolbar.frame.minX, start.minX - 80, accuracy: 0.5)
        XCTAssertEqual(toolbar.frame.minY, start.minY + 30, accuracy: 0.5)
        view.toolbarModel.perform(.dragToolbar(CGSize(width: 10, height: 0), ended: true))
        XCTAssertEqual(toolbar.frame.minX, start.minX - 70, accuracy: 0.5, "A new drag starts from where it is")
        view.toolbarModel.perform(.dragToolbar(CGSize(width: 0, height: 5000), ended: true))
        XCTAssertLessThanOrEqual(toolbar.frame.maxY - ScreenshotOverlayView.toolbarShadowInset, 900 + 0.5)

        let placed = CGRect(x: 10, y: 10, width: 100, height: 40)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(ScreenshotOverlayView.toolbarFrame(placed: placed, offset: CGSize(width: -50, height: 0),
                                                          in: bounds).minX, 0)
        XCTAssertEqual(ScreenshotOverlayView.toolbarFrame(placed: placed, offset: CGSize(width: 500, height: 500),
                                                          in: bounds), CGRect(x: 200, y: 160, width: 100, height: 40))
        XCTAssertEqual(ScreenshotOverlayChromeView.toolbarFrame(for: CGRect(x: 50, y: 100, width: 200, height: 50),
                                                                size: CGSize(width: 100, height: 40), in: bounds,
                                                                prefersAbove: true).minY, 52)
        XCTAssertEqual(ScreenshotOverlayChromeView.toolbarFrame(for: CGRect(x: 50, y: 20, width: 200, height: 50),
                                                                size: CGSize(width: 100, height: 40), in: bounds,
                                                                prefersAbove: true).minY, 78, "No room above")
    }

    private final class Scanner: ScreenshotSensitiveInfoScanning {
        func scan(_ image: CGImage) async -> [ScreenshotSensitiveFinding] {
            [ScreenshotSensitiveFinding(kind: .phone, text: "13800138000",
                                        boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.05, height: 0.02))]
        }
    }

    func testTheMoreMenuShowsAndHidesTheSensitiveInfoPanel() async {
        let (view, _) = makeView(scanner: Scanner())
        await view.sensitiveInfo.waitForScan()
        view.refresh()
        XCTAssertTrue(view.toolbarModel.state.canShowSensitivePanel)
        XCTAssertTrue(view.toolbarModel.state.showsSensitivePanel)
        view.toolbarModel.perform(.toggleSensitivePanel)
        XCTAssertFalse(view.sensitiveInfo.isPanelShown)
        XCTAssertFalse(view.toolbarModel.state.showsSensitivePanel)
        view.toolbarModel.perform(.toggleSensitivePanel)
        XCTAssertTrue(view.sensitiveInfo.isPanelShown, "Shown again after it was put away")

        let (plain, _) = makeView()
        XCTAssertFalse(plain.toolbarModel.state.canShowSensitivePanel)
    }

    func testTheLongImageEditorHasNoPinButKeepsTheMenu() {
        let canvas = ScreenshotLongImageCanvas(image: ScreenCaptureTestSupport.image(width: 300, height: 600), scale: 1)
        var events: [ScreenshotLongImageCanvas.Event] = []
        canvas.onEvent = { events.append($0) }
        XCTAssertFalse(canvas.toolbarState.showsPin)
        canvas.perform(.pin)
        canvas.perform(.dragToolbar(CGSize(width: 10, height: 10), ended: true))
        canvas.perform(.toggleToolbarPlacement)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(canvas.editor.toolStyles.prefersToolbarAbove)
        canvas.perform(.toggleMoreMenu)
        XCTAssertTrue(canvas.toolbarState.showsMoreMenu)
        canvas.perform(.resetStyles)
        XCTAssertFalse(canvas.showsMoreMenu)
        canvas.perform(.toggleSensitivePanel)
        canvas.perform(.copyAndSave)
        XCTAssertTrue(canvas.handleKeyDown(Key.returnKey, modifiers: [.option]))
        XCTAssertEqual(events, [.finish(.copyAndSave, []), .finish(.copyAndSave, [])])
        canvas.releaseImage()
    }

    func testTheToolbarShowsThePinGripAndMenu() {
        func size(_ change: (inout ScreenshotEditorToolbarModel.State) -> Void) -> CGSize {
            var state = ScreenshotEditorToolbarModel.State()
            change(&state)
            return NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in }).fittingSize
        }
        let full = size { _ in }
        XCTAssertLessThan(size { $0.showsPin = false }.width, full.width, "No pin and no grip")
        let menu = size {
            $0.showsMoreMenu = true
            $0.canShowSensitivePanel = true
        }
        XCTAssertGreaterThan(menu.height, full.height + 80)
        XCTAssertGreaterThan(menu.height, size { $0.showsMoreMenu = true }.height, "The sensitive info row")
    }

    func testToolbarPlacementAndResetAreStored() throws {
        var styles = ScreenshotToolStyles()
        styles.prefersToolbarAbove = true
        styles[.rect].color = .pink
        styles.noteRecent(.pink)
        XCTAssertEqual(try JSONDecoder().decode(ScreenshotToolStyles.self, from: JSONEncoder().encode(styles)), styles)
        styles.resetStyles()
        XCTAssertEqual(styles[.rect].color, .red)
        XCTAssertTrue(styles.prefersToolbarAbove)
        XCTAssertEqual(styles.recentColors, [.pink])
        var editor = ScreenshotAnnotationEditor(toolStyles: styles)
        XCTAssertTrue(editor.apply(.toggleToolbarPlacement))
        XCTAssertFalse(editor.toolStyles.prefersToolbarAbove)
        XCTAssertTrue(editor.apply(.resetStyles))
        for action: ScreenshotEditorToolbarModel.Action in [.pin, .copyAndSave, .toggleMoreMenu, .toggleSensitivePanel,
                                                             .dragToolbar(.zero, ended: true)] {
            XCTAssertFalse(editor.apply(action), "\(action)")
        }
    }
}
