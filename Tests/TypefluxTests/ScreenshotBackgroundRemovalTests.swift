import AppKit
import ImageIO
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotBackgroundRemovalTests: XCTestCase {
    private let region = CGRect(x: 10, y: 20, width: 40, height: 30)

    func testToggleRestoresOriginalAndSameRegionKeepsResult() async {
        let image = ScreenCaptureTestSupport.image(width: 40, height: 30)
        let state = ScreenshotBackgroundRemovalState(process: { _ in image })
        state.updateRegion(region)
        let done = expectation(description: "Processed")
        state.onChange = { if state.image != nil { done.fulfill() } }
        state.toggle(source: image)
        XCTAssertTrue(state.isProcessing)
        await fulfillment(of: [done], timeout: 2)
        state.updateRegion(region)
        XCTAssertTrue(state.image === image)
        state.toggle(source: image)
        XCTAssertNil(state.image)
        XCTAssertFalse(state.isProcessing)
        XCTAssertNil(state.noticeKey)
    }

    func testRegionChangeAndResetRejectLateResults() async {
        for clear in [false, true] {
            var continuation: CheckedContinuation<CGImage, Error>?
            let began = expectation(description: "Began")
            let returned = expectation(description: "Returned")
            let image = ScreenCaptureTestSupport.image(width: 40, height: 30)
            let state = ScreenshotBackgroundRemovalState(process: { _ in
                let result = try await withCheckedThrowingContinuation { continuation = $0; began.fulfill() }
                returned.fulfill()
                return result
            })
            state.updateRegion(region)
            state.toggle(source: image)
            await fulfillment(of: [began], timeout: 2)
            if clear { state.reset() } else { state.updateRegion(nil) }
            continuation?.resume(returning: image)
            await fulfillment(of: [returned], timeout: 2)
            await Task.yield()
            XCTAssertNil(state.image)
            XCTAssertFalse(state.isProcessing)
        }
    }

    func testToggleWhileProcessingCancelsAndAllowsRetry() async {
        var continuation: CheckedContinuation<CGImage, Error>?
        let began = expectation(description: "Began")
        let image = ScreenCaptureTestSupport.image(width: 40, height: 30)
        let state = ScreenshotBackgroundRemovalState(process: { _ in
            try await withCheckedThrowingContinuation { continuation = $0; began.fulfill() }
        })
        state.updateRegion(region)
        state.toggle(source: image)
        await fulfillment(of: [began], timeout: 2)
        state.toggle(source: image)
        XCTAssertFalse(state.isProcessing)
        continuation?.resume(throwing: ScreenshotBackgroundRemoval.Failure.rendering)
        await Task.yield()
        XCTAssertNil(state.noticeKey)
        XCTAssertNil(state.image)
    }

    func testErrorsKeepOriginalAndExposeActionableMessage() async {
        for (error, key) in [(ScreenshotBackgroundRemoval.Failure.noSubject, "screenshot.background.noSubject"),
                             (.rendering, "screenshot.background.failed")] {
            let state = ScreenshotBackgroundRemovalState(process: { _ in throw error })
            state.updateRegion(region)
            let failed = expectation(description: "Failed")
            state.onChange = { if state.noticeKey != nil { failed.fulfill() } }
            state.toggle(source: ScreenCaptureTestSupport.image(width: 40, height: 30))
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(state.noticeKey, key)
            XCTAssertFalse(state.isProcessing)
            XCTAssertNil(state.image)
            state.reset()
            XCTAssertNil(state.noticeKey)
        }
    }

    func testTransparentCropKeepsAlphaThroughAnnotationsAndPNG() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 30, y: 20, width: 20, height: 20))
        let transparent = try XCTUnwrap(context.makeImage())
        let rect = CGRect(x: 110, y: 20, width: 40, height: 30)
        let display = ScreenSnapshot.Display(id: 1, frame: rect, scale: 2, image: transparent)
        let mark = ScreenshotAnnotation(kind: .rect(CGRect(x: 125, y: 30, width: 10, height: 10)))
        for annotations in [[], [mark]] {
            let rendered = try ScreenshotRenderer.render(display, crop: rect, annotations: annotations)
            let png = try ScreenshotImageExporter.png(rendered, scale: 2)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 80)
            XCTAssertEqual(decoded.height, 60)
            let pixels = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            pixels.draw(decoded, in: CGRect(x: 0, y: 0, width: 80, height: 60))
            let data = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(data[3], 0, "Background must stay transparent, without the preview checkerboard")
            XCTAssertGreaterThan(data[(30 * 80 + 40) * 4 + 3], 0, "Foreground must stay visible")
        }
    }

    func testPreviewCoversOriginalWithGridAndMosaicsReadForeground() throws {
        let original = ScreenCaptureTestSupport.image(width: 160, height: 120, gray: 0)
        let foreground = ScreenCaptureTestSupport.image(width: 80, height: 60, gray: 1)
        let canvas = ScreenshotAnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 80, height: 60), source: original)
        let crop = CGRect(x: 10, y: 10, width: 40, height: 30)
        canvas.backgroundRemovedImage = foreground
        canvas.model = .init(crop: crop, annotations: [ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
            shape: .rect(crop), effect: .pixelate)))])
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.drawContents(in: context)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(data[(20 * 80 + 20) * 4], 255, "Mosaic must use the white foreground, not the black original")
        let transparent = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        canvas.backgroundRemovedImage = transparent
        canvas.model = .init(crop: crop)
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 60))
        canvas.drawContents(in: context)
        XCTAssertGreaterThan(data[(20 * 80 + 20) * 4], 150, "Transparent pixels show the grid, not the original screenshot")
        XCTAssertEqual(data[(20 * 80 + 20) * 4 + 3], 255)
        XCTAssertEqual(data[3], 0, "Preview stays clipped to the selection")
        canvas.releaseImage()
        XCTAssertNil(canvas.backgroundRemovedImage)
    }

    func testMissingRegionDoesNotStartProcessing() {
        let state = ScreenshotBackgroundRemovalState(process: { _ in XCTFail("No region"); throw CancellationError() })
        state.toggle(source: ScreenCaptureTestSupport.image(width: 40, height: 30))
        XCTAssertFalse(state.isProcessing)
    }
}
