import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

/// The follow-up buttons and the sensitive information panel, in the region overlay and the
/// long image editor.
@MainActor
final class ScreenshotFollowUpEditorTests: XCTestCase {
    private struct Scanner: ScreenshotSensitiveInfoScanning {
        var findings: [ScreenshotSensitiveFinding]
        func scan(_ image: CGImage) async -> [ScreenshotSensitiveFinding] { findings }
    }

    /// A phone number at x 40–120, y 60–70 pt on a 400 × 300 pt display.
    private let phone = ScreenshotSensitiveFinding(kind: .phone, text: "13800138000",
                                                   boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 1.0 / 30))

    private func makeView(findings: [ScreenshotSensitiveFinding] = [])
        -> (ScreenshotOverlayView, () -> [ScreenshotOverlayView.LocalEvent]) {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2,
                                             image: ScreenCaptureTestSupport.image(width: 800, height: 600))
        let view = ScreenshotOverlayView(display: display, windows: [], sensitiveScanner: Scanner(findings: findings))
        var events: [ScreenshotOverlayView.LocalEvent] = []
        view.onEvent = { _, event in events.append(event) }
        return (view, { events })
    }

    private func frame(_ view: ScreenshotOverlayView, from start: CGPoint, to end: CGPoint) {
        view.mouseDown(at: start, clickCount: 1)
        view.mouseDragged(to: end)
        view.mouseUp(at: end)
    }

    // MARK: Toolbar

    func testTheToolbarsFollowUpButtonsFinishTheRegion() {
        let (view, events) = makeView()
        frame(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 150))
        let region = CGRect(x: 50, y: 50, width: 200, height: 100)

        for followUp in ScreenshotFollowUp.allCases {
            view.toolbarModel.perform(.followUp(followUp))
        }

        XCTAssertEqual(events(), [.committed] + ScreenshotFollowUp.allCases.map { .finish(.followUp($0), region, []) })
    }

    func testTheToolbarKeepsLocalizedNamesForFollowUps() {
        let state = ScreenshotEditorToolbarModel.State()
        let host = NSHostingView(rootView: ScreenshotEditorToolbar(state: state) { _ in })
        XCTAssertGreaterThan(host.fittingSize.width, 500)
        for followUp in ScreenshotFollowUp.allCases {
            XCTAssertFalse(followUp.symbol.isEmpty)
            XCTAssertNotEqual(followUp.title, "screenshot.followUp.\(followUp.rawValue)")
        }
    }

    func testTheOverlayControllerFinishesTheChosenRegion() {
        let snapshot = ScreenSnapshot(displays: [
            .init(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 200, height: 100)),
            .init(id: 2, frame: CGRect(x: 200, y: 0, width: 300, height: 150), scale: 1,
                  image: ScreenCaptureTestSupport.image(width: 300, height: 150))
        ], windows: [])
        let controller = ScreenshotOverlayController(primaryDisplayHeight: { 150 }, pointerLocation: { .zero })
        var events: [ScreenshotOverlayEvent] = []
        controller.present(snapshot) { events.append($0) }
        defer { controller.dismiss() }

        controller.finish(.followUp(.askAI))
        XCTAssertTrue(events.isEmpty, "Nothing chosen yet")

        frame(controller.views[1], from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        controller.finish(.followUp(.askAI))
        XCTAssertEqual(events.last, .finish(.followUp(.askAI), displayID: 2,
                                            rect: CGRect(x: 210, y: 10, width: 100, height: 50)))
    }

    // MARK: Sensitive information

    func testTheRegionsSensitiveTextIsSuggestedAndCoveredOnRequest() async throws {
        let (view, _) = makeView(findings: [phone])
        XCTAssertEqual(view.sensitiveInfo.suggestions.status, .idle, "Nothing is read before a region is chosen")

        frame(view, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 120))
        await view.sensitiveInfo.waitForScan()
        let panel = try XCTUnwrap(view.sensitiveInfo.host)
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(view.editor.document.isEmpty, "Only a suggestion")
        XCTAssertEqual(panel.frame.minX, 120 + ScreenshotSensitiveInfoController.gap, "Right of the region")

        view.sensitiveInfo.perform(.applyAll, crop: view.selection.rect)
        let mosaic = try XCTUnwrap(view.editor.document.annotations.first?.mosaic)
        XCTAssertEqual(mosaic.frame, CGRect(x: 38, y: 58, width: 84, height: 14))
        XCTAssertTrue(view.toolbarModel.state.canUndo)

        view.handleKeyDown(ScreenshotOverlayView.Key.keyZ, modifiers: .command)
        XCTAssertTrue(view.editor.document.isEmpty, "Undone like any mark")

        // Resizing the region hides the panel until it is let go.
        view.mouseDown(at: CGPoint(x: 120, y: 120), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 150, y: 150))
        XCTAssertTrue(panel.isHidden)
        view.mouseUp(at: CGPoint(x: 150, y: 150))
        XCTAssertFalse(panel.isHidden)
        view.releaseImage()
    }

    func testTheSensitivePanelHidesWithoutFindingsInTheRegion() async {
        let (view, _) = makeView(findings: [phone])
        view.selectAll()
        await view.sensitiveInfo.waitForScan()
        XCTAssertEqual(view.sensitiveInfo.host?.isHidden, false)

        let (empty, _) = makeView(findings: [])
        empty.selectAll()
        await empty.sensitiveInfo.waitForScan()
        XCTAssertNil(empty.sensitiveInfo.host, "No panel without findings")
    }

    // MARK: Long image

    func testTheLongImageEditorsFollowUpsAndSensitivePanel() async throws {
        let controller = ScreenshotLongImageEditorController(primaryDisplayHeight: { 700 },
                                                             sensitiveScanner: Scanner(findings: [phone]))
        var events: [ScreenshotOverlayEvent] = []
        let display = ScreenSnapshot.Display(id: 4, frame: CGRect(x: 0, y: 0, width: 400, height: 3000), scale: 2,
                                             image: ScreenCaptureTestSupport.image(width: 800, height: 6000))
        controller.present(display, on: CGRect(x: 0, y: 0, width: 1200, height: 700)) { events.append($0) }
        defer { controller.dismiss() }
        let view = try XCTUnwrap(controller.editorView)
        let before = view.scrollView.frame

        await view.canvas.sensitiveInfo.waitForScan()
        let panel = try XCTUnwrap(view.canvas.sensitiveInfo.host)
        XCTAssertFalse(panel.isHidden)
        XCTAssertLessThan(view.scrollView.frame.width, before.width, "The image makes room for the panel")
        XCTAssertEqual(view.scrollView.frame, ScreenshotLongImageEditorView.scrollFrame(
            in: view.bounds, sidePanel: ScreenshotSensitiveInfoPanel.width
        ))
        XCTAssertGreaterThanOrEqual(panel.frame.minX, view.minimap.frame.maxX)

        view.canvas.sensitiveInfo.perform(.toggle(phone.id), crop: nil)
        let mosaic = try XCTUnwrap(view.canvas.editor.document.annotations.first?.mosaic)
        // 0.1 × 800 px at 2× is 40 pt; 0.2 × 6000 px is 600 pt.
        XCTAssertEqual(mosaic.frame, CGRect(x: 38, y: 598, width: 84, height: 104))

        view.canvas.sensitiveInfo.perform(.close, crop: nil)
        XCTAssertTrue(panel.isHidden)
        XCTAssertEqual(view.scrollView.frame, before, "The image gets its room back")

        view.canvas.perform(.followUp(.recognizeText))
        XCTAssertEqual(events.last, .finish(.followUp(.recognizeText), displayID: 4, rect: display.frame,
                                            annotations: view.canvas.editor.document.annotations))
    }
}
