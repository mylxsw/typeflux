import AppKit
import CoreGraphics
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotRendererTests: XCTestCase {
    private typealias Pixels = ScreenshotMosaicEffects.Pixels
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An image whose pixels alternate black and white, one pixel at a time, so any
    /// averaging or blurring shows up as gray.
    private static func checkerboard(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width where (row + column) % 2 == 0 {
                let offset = (row * width + column) * 4
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
            }
        }
        return Pixels(width: width, height: height, bytes: bytes).makeImage(space: sRGB)!
    }

    private static func pixels(_ image: CGImage) -> Pixels {
        Pixels(image, space: sRGB)!
    }

    private static func rgba(_ pixels: Pixels, _ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * pixels.width + x) * 4
        return Array(pixels.bytes[offset ..< offset + 4])
    }

    /// A display at x = 100 in global points, so local and global coordinates differ.
    private static func display(scale: CGFloat = 2, image: CGImage? = nil) -> ScreenSnapshot.Display {
        let frame = CGRect(x: 100, y: 0, width: 60, height: 40)
        return ScreenSnapshot.Display(
            id: 1, frame: frame, scale: scale,
            image: image ?? checkerboard(width: Int(frame.width * scale), height: Int(frame.height * scale))
        )
    }

    private static let red: [UInt8] = [0xFF, 0x4D, 0x4F, 0xFF]

    private static func isClose(_ lhs: [UInt8], _ rhs: [UInt8], tolerance: Int = 3) -> Bool {
        zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    // MARK: Render

    func testWithoutAnnotationsTheExportIsTheCroppedScreenshot() throws {
        let display = Self.display()
        let crop = CGRect(x: 110, y: 10, width: 30, height: 20)

        let rendered = try ScreenshotRenderer.render(display, crop: crop, annotations: [])
        let cropped = try ScreenshotImageExporter.crop(display, to: crop)

        XCTAssertEqual(rendered.width, 60)
        XCTAssertEqual(rendered.height, 40)
        XCTAssertEqual(Self.pixels(rendered).bytes, Self.pixels(cropped).bytes)
    }

    func testRegionOffTheDisplayFails() {
        let mark = ScreenshotAnnotation(kind: .counter(center: .zero))
        let offDisplay = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try ScreenshotRenderer.render(Self.display(), crop: offDisplay, annotations: [mark]))
    }

    func testShapesAreDrawnAtNativePixelsInsideTheRegion() throws {
        let display = Self.display(image: ScreenCaptureTestSupport.image(width: 120, height: 80, gray: 0.5))
        let crop = CGRect(x: 110, y: 10, width: 30, height: 20)
        // A 10 × 10 pt box at 5, 5 inside the region, drawn 4 pt wide.
        let box = ScreenshotAnnotation(kind: .rect(CGRect(x: 115, y: 15, width: 10, height: 10)))

        let pixels = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: [box]))

        XCTAssertEqual(pixels.width, 60)
        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 10, 20), Self.red, tolerance: 8), "Left edge at 5 pt = 10 px")
        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 20, 10), Self.red, tolerance: 8), "Top edge")
        let inside = Self.rgba(pixels, 20, 20)
        XCTAssertEqual(inside[0], inside[2], "The inside keeps the screenshot")
        XCTAssertFalse(Self.isClose(Self.rgba(pixels, 2, 2), Self.red), "Far from the box")
    }

    func testMosaicStaysInsideItsShapeAndTheRegion() throws {
        let display = Self.display()
        let crop = CGRect(x: 110, y: 10, width: 40, height: 20)
        // Hangs off the region's right edge; only the part inside is processed.
        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
            shape: .rect(CGRect(x: 130, y: 15, width: 40, height: 10)), effect: .pixelate, strength: .medium
        )))

        let rendered = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: [mosaic]))
        let original = Self.pixels(try ScreenshotImageExporter.crop(display, to: crop))

        XCTAssertEqual(rendered.width, original.width)
        for y in 0 ..< rendered.height {
            for x in 0 ..< rendered.width {
                // In crop pixels the mosaic covers x 40..<80 and y 10..<30.
                let inside = x >= 40 && y >= 10 && y < 30
                let before = Self.rgba(original, x, y), after = Self.rgba(rendered, x, y)
                if inside {
                    XCTAssertTrue(after[0] > 40 && after[0] < 215, "Averaged to gray at \(x), \(y)")
                } else {
                    XCTAssertEqual(before, after, "Untouched at \(x), \(y)")
                }
            }
        }
    }

    func testBrushMosaicOnlyCoversTheStroke() throws {
        let display = Self.display(scale: 1)
        let crop = CGRect(x: 100, y: 0, width: 60, height: 40)
        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
            shape: .brush([CGPoint(x: 110, y: 20), CGPoint(x: 150, y: 20)], width: 10), effect: .solid
        )), style: ScreenshotAnnotationStyle(color: .blue))

        let pixels = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: [mosaic]))

        XCTAssertEqual(Self.rgba(pixels, 30, 20), [0x2F, 0x8C, 0xFF, 0xFF], "On the stroke")
        let above = Self.rgba(pixels, 30, 5)
        XCTAssertTrue(above == [0, 0, 0, 255] || above == [255, 255, 255, 255], "Above the stroke stays original")
        let beyondTheEnd = Self.rgba(pixels, 58, 20)
        XCTAssertTrue(beyondTheEnd == [0, 0, 0, 255] || beyondTheEnd == [255, 255, 255, 255])
    }

    func testOtherAnnotationsAreDrawnOverMosaics() throws {
        let display = Self.display(scale: 1)
        let crop = CGRect(x: 100, y: 0, width: 60, height: 40)
        // The box comes first but is still drawn above the mosaic.
        let box = ScreenshotAnnotation(kind: .rect(CGRect(x: 110, y: 10, width: 30, height: 20)))
        let mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
            shape: .rect(CGRect(x: 100, y: 0, width: 60, height: 40)), effect: .solid
        )), style: ScreenshotAnnotationStyle(color: .white))

        let pixels = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: [box, mosaic]))

        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 10, 20), Self.red))
        XCTAssertEqual(Self.rgba(pixels, 25, 20), [255, 255, 255, 255])
    }

    func testEveryKindDraws() throws {
        let display = Self.display(scale: 1, image: ScreenCaptureTestSupport.image(width: 60, height: 40, gray: 0))
        let crop = display.frame
        let kinds: [ScreenshotAnnotation.Kind] = [
            .ellipse(CGRect(x: 105, y: 5, width: 20, height: 20)),
            .arrow(from: CGPoint(x: 105, y: 35), to: CGPoint(x: 155, y: 35)),
            .arrow(from: CGPoint(x: 150, y: 5), to: CGPoint(x: 152, y: 5)),
            .arrow(from: CGPoint(x: 150, y: 5), to: CGPoint(x: 150, y: 5)),
            .path([CGPoint(x: 130, y: 5), CGPoint(x: 140, y: 15)]),
            .highlight([CGPoint(x: 120, y: 30)]),
            .text(origin: CGPoint(x: 130, y: 10), "Hi", fontSize: 14),
            .counter(center: CGPoint(x: 145, y: 20))
        ]
        let annotations = kinds.map { ScreenshotAnnotation(kind: $0) }

        let pixels = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: annotations))

        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 5, 15), Self.red, tolerance: 40), "Ellipse's left edge")
        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 50, 35), Self.red, tolerance: 40), "Arrow head")
        XCTAssertTrue(Self.isClose(Self.rgba(pixels, 36, 20), Self.red, tolerance: 40), "Counter")
        let highlight = Self.rgba(pixels, 20, 30)
        XCTAssertGreaterThan(highlight[0], 60, "Translucent red over black")
        XCTAssertLessThan(highlight[0], 200)
    }

    // MARK: Screen matches export

    /// Draws the overlay's canvas the way the screen shows it: the frozen image, then the canvas.
    private func screenImage(of display: ScreenSnapshot.Display, crop: CGRect,
                             annotations: [ScreenshotAnnotation]) throws -> CGImage {
        let local = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let canvas = ScreenshotAnnotationCanvasView(frame: CGRect(origin: .zero, size: display.frame.size),
                                                    source: display.image)
        canvas.model = .init(crop: local, annotations: annotations.map {
            $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        })
        let base = try ScreenshotImageExporter.crop(display, to: crop)
        let context = try XCTUnwrap(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: ScreenshotMosaicEffects.colorSpace(of: base),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: 1, y: -1)
        ScreenshotRenderer.drawImage(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height),
                                     context: context)
        context.scaleBy(x: display.scale, y: display.scale)
        context.translateBy(x: -local.minX, y: -local.minY)
        canvas.drawContents(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    func testExportMatchesWhatTheOverlayShows() throws {
        let display = Self.display(scale: 2)
        let crop = CGRect(x: 105, y: 4, width: 50, height: 32)
        let annotations: [ScreenshotAnnotation] = [
            ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
                shape: .rect(CGRect(x: 100, y: 0, width: 25, height: 20)), effect: .pixelate
            ))),
            ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(
                shape: .brush([CGPoint(x: 130, y: 30), CGPoint(x: 150, y: 28)], width: 8), effect: .blur
            ))),
            ScreenshotAnnotation(kind: .rect(CGRect(x: 110, y: 8, width: 20, height: 12)),
                                 style: .init(color: .green, width: .thin)),
            ScreenshotAnnotation(kind: .ellipse(CGRect(x: 130, y: 8, width: 20, height: 12))),
            ScreenshotAnnotation(kind: .arrow(from: CGPoint(x: 108, y: 34), to: CGPoint(x: 140, y: 22)),
                                 style: .init(color: .yellow, width: .thick)),
            ScreenshotAnnotation(kind: .path([CGPoint(x: 112, y: 25), CGPoint(x: 118, y: 30), CGPoint(x: 125, y: 24)])),
            ScreenshotAnnotation(kind: .highlight([CGPoint(x: 135, y: 15), CGPoint(x: 152, y: 15)]),
                                 style: .init(color: .yellow)),
            ScreenshotAnnotation(kind: .text(origin: CGPoint(x: 120, y: 4), "Q3", fontSize: 12),
                                 style: .init(color: .blue)),
            ScreenshotAnnotation(kind: .counter(center: CGPoint(x: 148, y: 30)), style: .init(color: .white))
        ]

        let exported = Self.pixels(try ScreenshotRenderer.render(display, crop: crop, annotations: annotations))
        let shown = Self.pixels(try screenImage(of: display, crop: crop, annotations: annotations))

        XCTAssertEqual(exported.width, 100)
        XCTAssertEqual(exported.height, 64)
        XCTAssertEqual(shown.width, exported.width)
        var differing = 0
        for (lhs, rhs) in zip(exported.bytes, shown.bytes) where abs(Int(lhs) - Int(rhs)) > 2 {
            differing += 1
        }
        XCTAssertEqual(differing, 0, "Every pixel of the export matches the screen")
    }

    // MARK: Mosaic patches

    func testPatchesAreCachedUntilTheMosaicOrRegionChanges() {
        let display = Self.display(scale: 1)
        let canvas = ScreenshotAnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 60, height: 40),
                                                    source: display.image)
        XCTAssertNil(canvas.hitTest(CGPoint(x: 5, y: 5)))
        XCTAssertTrue(canvas.isFlipped)
        var mosaic = ScreenshotAnnotation(kind: .mosaic(ScreenshotMosaic(shape: .rect(CGRect(x: 5, y: 5, width: 20,
                                                                                             height: 20)))))
        let context = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        canvas.drawContents(in: context)
        XCTAssertEqual(canvas.patchComputations, 0, "Nothing without a region")

        canvas.model = .init(crop: CGRect(x: 0, y: 0, width: 60, height: 40), annotations: [mosaic],
                             selection: mosaic.frame, handles: [CGPoint(x: 5, y: 5)])
        canvas.drawContents(in: context)
        canvas.drawContents(in: context)
        XCTAssertEqual(canvas.patchComputations, 1)

        mosaic.style.color = .green
        canvas.model.annotations = [mosaic]
        canvas.drawContents(in: context)
        XCTAssertEqual(canvas.patchComputations, 2)
        canvas.model.crop = CGRect(x: 0, y: 0, width: 30, height: 30)
        canvas.drawContents(in: context)
        XCTAssertEqual(canvas.patchComputations, 3)

        canvas.releaseImage()
        canvas.model.crop = CGRect(x: 0, y: 0, width: 20, height: 20)
        canvas.drawContents(in: context)
        XCTAssertEqual(canvas.patchComputations, 3, "No image, no mosaic")
    }

    func testCanvasDrawsThroughAppKit() throws {
        let display = Self.display(scale: 1)
        let canvas = ScreenshotAnnotationCanvasView(frame: CGRect(x: 0, y: 0, width: 60, height: 40),
                                                    source: display.image)
        canvas.model = .init(crop: CGRect(x: 0, y: 0, width: 60, height: 40),
                             annotations: [ScreenshotAnnotation(kind: .rect(CGRect(x: 10, y: 10, width: 20,
                                                                                   height: 20)))])
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        XCTAssertGreaterThan(bitmap.colorAt(x: Int(10 * scale), y: Int(20 * scale))?.alphaComponent ?? 0, 0.5)
        XCTAssertEqual(bitmap.colorAt(x: Int(20 * scale), y: Int(20 * scale))?.alphaComponent ?? 1, 0)
    }

    func testPatchMissingTheRegionIsNil() {
        let display = Self.display(scale: 1)
        let mosaic = ScreenshotMosaic(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(ScreenshotRenderer.mosaicPatch(for: mosaic, color: .red, source: display.image,
                                                    sourceFrame: CGRect(x: 0, y: 0, width: 60, height: 40),
                                                    crop: CGRect(x: 30, y: 30, width: 10, height: 10)))
        let patch = ScreenshotRenderer.mosaicPatch(for: mosaic, color: .red, source: display.image,
                                                   sourceFrame: CGRect(x: 0, y: 0, width: 60, height: 40),
                                                   crop: CGRect(x: 5, y: 5, width: 20, height: 20))
        XCTAssertEqual(patch?.rect, CGRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(patch?.pixelRect, CGRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(ScreenshotRenderer.pixelScale(imageWidth: 10, imageHeight: 10, frame: .zero),
                       CGSize(width: 1, height: 1))
    }

    // MARK: Effects

    func testPixelateAveragesEachBlockFromTheTopLeft() {
        // Row 0: 0 100 200 50 / row 1: 100 200 0 150, gray, three columns wide blocks of 2.
        let values: [[UInt8]] = [[0, 100, 200], [100, 200, 0]]
        var bytes: [UInt8] = []
        for row in values { for value in row { bytes += [value, value, value, 255] } }
        var pixels = Pixels(width: 3, height: 2, bytes: bytes)

        ScreenshotMosaicEffects.pixelate(&pixels, block: 2)

        XCTAssertEqual(Self.rgba(pixels, 0, 0), [100, 100, 100, 255])
        XCTAssertEqual(Self.rgba(pixels, 1, 1), [100, 100, 100, 255])
        XCTAssertEqual(Self.rgba(pixels, 2, 0), [100, 100, 100, 255], "The partial block on the edge")
        XCTAssertEqual(Self.rgba(pixels, 2, 1), [100, 100, 100, 255])
    }

    func testBlurKeepsFlatColorsAndSoftensEdges() throws {
        var flat = Pixels(width: 4, height: 4, bytes: [UInt8](repeating: 80, count: 64))
        ScreenshotMosaicEffects.boxBlur(&flat, radius: 2)
        XCTAssertTrue(flat.bytes.allSatisfy { $0 == 80 })

        let image = Self.checkerboard(width: 40, height: 30)
        for radius in [2, 30] {
            let blurred = try XCTUnwrap(ScreenshotMosaicEffects.blurred(image, radius: radius))
            XCTAssertEqual(blurred.width, 40)
            XCTAssertEqual(blurred.height, 30)
            let center = Self.rgba(Self.pixels(blurred), 20, 15)
            XCTAssertTrue(center[0] > 90 && center[0] < 165, "Radius \(radius) blends to gray: \(center)")
        }
    }

    func testEffectsDispatch() throws {
        let image = Self.checkerboard(width: 8, height: 8)
        let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let solid = try XCTUnwrap(ScreenshotMosaicEffects.apply(.solid, to: image, block: 2, radius: 2, color: green))
        XCTAssertEqual(Self.rgba(Self.pixels(solid), 3, 3), [0, 255, 0, 255])
        XCTAssertNotNil(ScreenshotMosaicEffects.apply(.pixelate, to: image, block: 4, radius: 2, color: Self.redColor))
        XCTAssertNotNil(ScreenshotMosaicEffects.apply(.blur, to: image, block: 4, radius: 2, color: Self.redColor))
        XCTAssertNil(ScreenshotMosaicEffects.solid(width: 0, height: 4, color: Self.redColor, space: Self.sRGB))
        let gray = ScreenCaptureTestSupport.image(width: 2, height: 2)
        XCTAssertEqual(ScreenshotMosaicEffects.colorSpace(of: gray).model, .rgb)
    }

    private static let redColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    // MARK: Strength

    func testStrongerMosaicsUseBiggerBlocksAndGrowWithText() {
        func mosaic(_ strength: ScreenshotMosaic.Strength, text: CGFloat? = nil) -> ScreenshotMosaic {
            ScreenshotMosaic(shape: .rect(.zero), strength: strength, textHeight: text)
        }
        XCTAssertEqual(mosaic(.low).blockSize(scale: 1), 5)
        XCTAssertEqual(mosaic(.low, text: 100).blockSize(scale: 2), 10, "Light ignores the text")
        XCTAssertEqual(mosaic(.medium).blockSize(scale: 1), 12, "Never under 12 px")
        XCTAssertEqual(mosaic(.medium).blockSize(scale: 2), 18)
        XCTAssertEqual(mosaic(.high).blockSize(scale: 1), 14)
        XCTAssertEqual(mosaic(.medium, text: 40).blockSize(scale: 2), 40)
        XCTAssertEqual(mosaic(.high, text: 40).blockSize(scale: 2), 64)
        XCTAssertEqual(mosaic(.medium).blockSize(scale: 0), 12, "A scale under one counts as one")

        XCTAssertEqual(mosaic(.low).blurRadius(scale: 1), 3)
        XCTAssertEqual(mosaic(.medium).blurRadius(scale: 1), 12)
        XCTAssertEqual(mosaic(.high, text: 40).blurRadius(scale: 1), 28)
        XCTAssertEqual(mosaic(.high).blurRadius(scale: 2), 20)
    }

    // MARK: Text height

    func testTallestTextLine() {
        XCTAssertEqual(VisionTextHeightMeasurer.tallest(normalizedBoxes: [CGRect(x: 0, y: 0, width: 1, height: 0.1),
                                                                         CGRect(x: 0, y: 0.5, width: 1, height: 0.25)],
                                                        imageHeight: 200), 50)
        XCTAssertNil(VisionTextHeightMeasurer.tallest(normalizedBoxes: [], imageHeight: 200))
        let blank = ScreenCaptureTestSupport.image(width: 64, height: 64, gray: 1)
        XCTAssertNil(VisionTextHeightMeasurer().tallestLineHeight(in: blank),
                     "No text on a blank image")
    }

    func testVisionFindsTheHeightOfRealText() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: Self.sRGB,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 160))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Revenue 128,430" as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())

        let height = try XCTUnwrap(VisionTextHeightMeasurer().tallestLineHeight(in: image))
        XCTAssertGreaterThan(height, 20)
        XCTAssertLessThan(height, 120)
    }
}
