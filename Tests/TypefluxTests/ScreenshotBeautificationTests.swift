import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotBeautificationTests: XCTestCase {
    private var settings: ScreenshotBeautification {
        ScreenshotBeautification(isEnabled: true, background: .white, padding: 10, cornerRadius: 8, shadow: 0)
    }

    private func source(width: Int = 80, height: Int = 40) -> CGImage {
        ScreenCaptureTestSupport.image(width: width, height: height, gray: 0.25)
    }

    private func pixel(_ image: CGImage, _ column: Int, _ row: Int) throws -> [UInt8] {
        let pixels = try XCTUnwrap(ScreenshotMosaicEffects.Pixels(image, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        let offset = (row * pixels.width + column) * 4
        return Array(pixels.bytes[offset ..< offset + 4])
    }

    func testDisabledPreservesTheExactImage() throws {
        let image = source()
        let result = try ScreenshotBeautificationRenderer.render(image, scale: 2, settings: .init())
        XCTAssertTrue(result === image)
    }

    func testRetinaPaddingAndRoundedCornersKeepTheCenterPixels() throws {
        let image = source()
        let result = try ScreenshotBeautificationRenderer.render(image, scale: 2, settings: settings)
        XCTAssertEqual(result.width, 120)
        XCTAssertEqual(result.height, 80)
        XCTAssertEqual(try pixel(result, 2, 2), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(result, 20, 20), [255, 255, 255, 255], "The clipped corner shows the background")
        XCTAssertEqual(try pixel(result, 60, 40), try pixel(image, 40, 20))
    }

    func testTransparentBackgroundAndPngRetainAlpha() throws {
        var style = settings
        style.background = .transparent
        let image = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
        XCTAssertEqual(try pixel(image, 0, 0)[3], 0)
        XCTAssertEqual(try pixel(image, 10, 10)[3], 0)
        XCTAssertEqual(try pixel(image, 50, 30)[3], 255)
        let png = try ScreenshotImageExporter.png(image, scale: 1)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        XCTAssertEqual(try pixel(decoded, 10, 10)[3], 0)
    }

    func testBackgroundPresetsAndGradientDirection() throws {
        for background in ScreenshotBeautification.Background.allCases {
            var style = settings
            style.background = background
            let image = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
            switch background {
            case .transparent:
                XCTAssertEqual(try pixel(image, 1, 1)[3], 0)
            case .white:
                XCTAssertEqual(try pixel(image, 1, 1), [255, 255, 255, 255])
            case .charcoal:
                XCTAssertLessThan(try pixel(image, 1, 1)[0], 80)
            default:
                XCTAssertNotEqual(try pixel(image, 1, 1), try pixel(image, image.width - 2, image.height - 2))
                XCTAssertEqual(try pixel(image, 1, 1)[3], 255)
            }
        }
    }

    func testInstalledMacOSWallpapersCanBeUsedAsBackgrounds() throws {
        for background in ScreenshotBeautification.Background.allCases where background.wallpaperURL != nil {
            let installed = FileManager.default.isReadableFile(atPath: try XCTUnwrap(background.wallpaperURL).path)
            XCTAssertEqual(ScreenshotBeautification.Background.availableCases.contains(background), installed)
            guard installed else { continue }
            let thumbnail = try XCTUnwrap(ScreenshotBeautificationRenderer.wallpaper(background, maxDimension: 128))
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 128)
            var style = settings
            style.background = background
            let image = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
            XCTAssertEqual(try pixel(image, 1, 1)[3], 255)
        }
    }

    func testShadowDrawsOutsideTheScreenshotAndCanBeRemoved() throws {
        var style = settings
        style.padding = 40
        let plain = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
        style.shadow = 1
        let shaded = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
        XCTAssertLessThan(try pixel(shaded, 80, 83)[0], try pixel(plain, 80, 83)[0])
        XCTAssertEqual(try pixel(shaded, 80, 60), try pixel(plain, 80, 60), "The shadow never tints the image")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let transparent = try XCTUnwrap(context.makeImage())
        let composed = try ScreenshotBeautificationRenderer.render(transparent, scale: 1, settings: style)
        XCTAssertEqual(try pixel(composed, 80, 60), [255, 255, 255, 255],
                       "Transparent source pixels show the background, never the shadow silhouette")
    }

    func testZeroPaddingAndExtremeRadiusStayWithinTheCanvas() throws {
        var style = settings
        style.padding = 0
        style.cornerRadius = 80
        style.background = .transparent
        style.shadow = 1
        let image = try ScreenshotBeautificationRenderer.render(source(width: 3, height: 2), scale: 2, settings: style)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        style.cornerRadius = 0
        let square = try ScreenshotBeautificationRenderer.render(source(), scale: 1, settings: style)
        XCTAssertEqual(try pixel(square, 0, 0)[3], 255)
    }

    func testInvalidSettingsAreClampedAndUnsafeAllocationsFail() throws {
        var style = settings
        style.padding = .infinity
        style.cornerRadius = -.infinity
        style.shadow = .nan
        XCTAssertEqual(style.normalized.padding, 0)
        XCTAssertEqual(style.normalized.cornerRadius, 0)
        XCTAssertEqual(style.normalized.shadow, 0)
        style.padding = 999
        style.cornerRadius = -1
        style.shadow = 2
        XCTAssertEqual(style.normalized.padding, 160)
        XCTAssertEqual(style.normalized.cornerRadius, 0)
        XCTAssertEqual(style.normalized.shadow, 1)
        for scale in [CGFloat(0), -1, .nan, .infinity, 100_000] {
            XCTAssertThrowsError(try ScreenshotBeautificationRenderer.render(source(), scale: scale, settings: style))
        }
        XCTAssertThrowsError(try ScreenshotBeautificationRenderer.canvasSize(
            for: CGSize(width: 50_000, height: 50_000), scale: 1, settings: style))
    }

    func testCompositingPreservesOrientationAndRedactions() throws {
        let image = source()
        let frame = CGRect(x: 100, y: 20, width: 80, height: 40)
        let display = ScreenSnapshot.Display(id: 1, frame: frame, scale: 1, image: image)
        let cover = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
            shape: .rect(CGRect(x: 100, y: 20, width: 80, height: 15)), effect: .solid)),
            style: ScreenshotAnnotationStyle(color: .white))
        let flattened = try ScreenshotRenderer.render(display, crop: frame, annotations: [cover])
        let result = try ScreenshotBeautificationRenderer.render(flattened, scale: 1, settings: settings)
        XCTAssertEqual(try pixel(result, 50, 15), [255, 255, 255, 255], "The top remains redacted")
        XCTAssertEqual(try pixel(result, 50, 40), try pixel(image, 40, 30), "The bottom stays upright")
    }

    func testPreviewDownsamplesLongImagesAndUpdatesWithoutChangingOutputPointSizes() throws {
        let preview = ScreenshotBeautificationPreview(source: source(width: 200, height: 4000), scale: 2,
                                                      settings: settings)
        let image = try XCTUnwrap(preview.image)
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 1616)
        preview.settings.padding = 0
        XCTAssertEqual(preview.image?.width, 80)
        preview.settings.isEnabled = false
        XCTAssertEqual(preview.image?.height, 1600)
        XCTAssertFalse(preview.failed)
        let invalid = ScreenshotBeautificationPreview(source: source(), scale: 0, settings: settings)
        XCTAssertTrue(invalid.failed)
        XCTAssertNil(invalid.image)
        invalid.settings.isEnabled = false
        XCTAssertFalse(invalid.failed)
        XCTAssertNotNil(invalid.image)
        let oversized = ScreenshotBeautificationPreview(source: source(width: 2, height: 70_000), scale: 1,
                                                        settings: settings)
        XCTAssertTrue(oversized.failed, "Downsampling must not hide an export allocation failure")
    }

    func testEditorKeepsBeautySeparateFromAnnotationStyles() {
        var editor = ScreenshotAnnotationEditor()
        XCTAssertFalse(editor.apply(.beautify))
        XCTAssertTrue(editor.apply(.beautification(settings)))
        editor.apply(.resetStyles)
        XCTAssertEqual(editor.beautification, settings)
        let state = ScreenshotEditorToolbarModel.State(editor: editor, showsColorPanel: false, isPickingColor: false)
        XCTAssertTrue(state.isBeautified)
        XCTAssertFalse(state.canUndo)
        editor.apply(.beautification(.init()))
        XCTAssertFalse(editor.beautification.isEnabled)
    }

    func testOverlayAndLongImageControllerForwardSettingsAndDismissSheets() throws {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 100, y: 0, width: 1200, height: 800),
                                             scale: 1, image: source(width: 1200, height: 800))
        let overlay = ScreenshotOverlayController(primaryDisplayHeight: { 800 }, pointerLocation: { .zero })
        var events: [ScreenshotOverlayEvent] = []
        overlay.present(ScreenSnapshot(displays: [display], windows: [])) { events.append($0) }
        defer { overlay.dismiss() }
        let view = try XCTUnwrap(overlay.views.first)
        view.selectAll()
        view.perform(.beautification(settings))
        XCTAssertTrue(view.isAnnotating)
        XCTAssertFalse(view.canScrollCapture, "Recapturing would lose the configured composition")
        view.perform(.beautify)
        XCTAssertNotNil(view.beautificationPanel.panel?.sheetParent)
        let preview = try XCTUnwrap(view.beautificationPanel.panel?.contentView
            as? NSHostingView<ScreenshotBeautificationView>)
        preview.rootView.apply()
        XCTAssertNil(view.beautificationPanel.panel)
        XCTAssertTrue(view.toolbarModel.state.isBeautified)
        view.finish(.copy)
        XCTAssertEqual(events.last, .finish(.copy, displayID: 1, rect: display.frame, beautification: settings))
        view.perform(.beautify)
        overlay.dismiss()
        XCTAssertNil(view.beautificationPanel.panel)

        let long = ScreenshotLongImageEditorController(primaryDisplayHeight: { 800 })
        let longDisplay = ScreenSnapshot.Display(id: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 1600),
                                                 scale: 1, image: source(width: 200, height: 1600))
        long.present(longDisplay, on: display.frame) { events.append($0) }
        defer { long.dismiss() }
        let canvas = try XCTUnwrap(long.editorView?.canvas)
        canvas.perform(.beautification(settings))
        canvas.perform(.beautify)
        XCTAssertNotNil(canvas.beautificationPanel.panel)
        let longPreview = try XCTUnwrap(canvas.beautificationPanel.panel?.contentView
            as? NSHostingView<ScreenshotBeautificationView>)
        longPreview.rootView.apply()
        XCTAssertNil(canvas.beautificationPanel.panel)
        canvas.perform(.copy)
        XCTAssertEqual(events.last, .finish(.copy, displayID: 2, rect: longDisplay.frame, beautification: settings))
        canvas.perform(.beautify)
        long.dismiss()
        XCTAssertNil(canvas.beautificationPanel.panel)
    }

}

extension ScreenshotBeautificationTests {
    func testBeautificationPreviewsTheFinishedCutoutAndWaitsForProcessing() async throws {
        try XCTSkipIf(!ScreenshotBackgroundRemoval.isSupported, "Foreground removal requires macOS 14")
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let foreground = try XCTUnwrap(context.makeImage())
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 400, y: 100, width: 1200, height: 800),
                                             scale: 1, image: source(width: 1200, height: 800))
        let view = ScreenshotOverlayView(display: display, windows: [], backgroundProcessor: { _ in foreground })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.releaseImage(); window.close() }
        view.mouseDown(at: CGPoint(x: 100, y: 100), clickCount: 1)
        view.mouseDragged(to: CGPoint(x: 500, y: 300))
        view.mouseUp(at: CGPoint(x: 500, y: 300))
        let done = expectation(description: "Cutout finished")
        view.backgroundRemoval.onChange = { [weak view] in
            view?.refresh()
            if view?.backgroundRemoval.image != nil { done.fulfill() }
        }
        view.perform(.toggleBackgroundRemoval)
        XCTAssertTrue(view.backgroundRemoval.isProcessing)
        view.perform(.beautify)
        XCTAssertNil(view.beautificationPanel.panel, "The source must be stable before opening a draft")
        await fulfillment(of: [done], timeout: 2)
        view.perform(.beautification(ScreenshotBeautification(isEnabled: true, background: .white,
                                                              padding: 0, cornerRadius: 0, shadow: 0)))
        view.perform(.beautify)
        let host = try XCTUnwrap(view.beautificationPanel.panel?.contentView
            as? NSHostingView<ScreenshotBeautificationView>)
        let preview = try XCTUnwrap(host.rootView.model.image)
        XCTAssertEqual(preview.width, 400)
        XCTAssertEqual(preview.height, 200)
        XCTAssertEqual(try pixel(preview, 30, 30), [255, 255, 255, 255],
                       "The transparent cutout shows the selected background instead of the frozen desktop")
    }

    func testPanelCancelApplyAndReopenKeepDraftsIsolated() throws {
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let controller = ScreenshotBeautificationPanel()
        defer { controller.dismiss() }
        var applied: [ScreenshotBeautification] = []
        controller.present(source: source(), scale: 1, settings: .init(), over: parent) { applied.append($0) }
        let panel = try XCTUnwrap(controller.panel)
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<ScreenshotBeautificationView>)
        XCTAssertTrue(host.rootView.model.settings.isEnabled)
        XCTAssertEqual(panel.appearance?.name, .darkAqua)
        XCTAssertEqual(panel.contentLayoutRect.size, ScreenshotBeautificationView.size)
        host.rootView.model.settings.padding = 80
        host.rootView.cancel()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(controller.panel)
        controller.present(source: source(), scale: 1, settings: settings, over: parent) { applied.append($0) }
        let next = try XCTUnwrap(controller.panel?.contentView as? NSHostingView<ScreenshotBeautificationView>)
        XCTAssertEqual(next.rootView.model.settings, settings)
        next.rootView.apply()
        XCTAssertEqual(applied, [settings])
        XCTAssertNil(controller.panel)
        controller.present(source: source(), scale: 1, settings: settings, over: parent) { applied.append($0) }
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.panel)))
        XCTAssertNil(controller.panel)
        XCTAssertEqual(applied.count, 1)
    }

}
