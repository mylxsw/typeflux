import AppKit
import CoreGraphics
import ImageIO
@testable import Typeflux
import XCTest

final class ScreenshotExportTests: XCTestCase {
    /// A 4 × 2 image whose left half is red and right half is blue.
    private func twoColorImage() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    // MARK: Magnifier

    func testPixelUnderAPointScalesAndClamps() {
        let display = CGSize(width: 100, height: 50)
        let image = ScreenPixelSize(width: 200, height: 100)

        XCTAssertEqual(ScreenshotMagnifier.pixel(at: CGPoint(x: 10.6, y: 20.2), displaySize: display,
                                                 imageSize: image), CGPoint(x: 21, y: 40))
        XCTAssertEqual(ScreenshotMagnifier.pixel(at: CGPoint(x: 100, y: 50), displaySize: display, imageSize: image),
                       CGPoint(x: 199, y: 99))
        XCTAssertEqual(ScreenshotMagnifier.pixel(at: CGPoint(x: -3, y: -3), displaySize: display, imageSize: image),
                       .zero)
        XCTAssertEqual(ScreenshotMagnifier.pixel(at: CGPoint(x: 5, y: 5), displaySize: .zero, imageSize: image), .zero)
    }

    func testSampleIsAnElevenByNineGridAroundThePixel() {
        XCTAssertEqual(ScreenshotMagnifier.sampleRect(around: CGPoint(x: 20, y: 30)),
                       CGRect(x: 15, y: 26, width: 11, height: 9))
    }

    func testLoupeFlipsAwayFromEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = ScreenshotMagnifier.size

        XCTAssertEqual(ScreenshotMagnifier.frame(for: CGPoint(x: 100, y: 100), in: bounds).origin,
                       CGPoint(x: 120, y: 120))
        let corner = ScreenshotMagnifier.frame(for: CGPoint(x: 990, y: 790), in: bounds)
        XCTAssertEqual(corner.origin, CGPoint(x: 990 - 20 - size.width, y: 790 - 20 - size.height))
        XCTAssertTrue(bounds.contains(corner))
        // Never past the top-left edge, even on a tiny display.
        let tiny = ScreenshotMagnifier.frame(for: CGPoint(x: 10, y: 10), in: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(tiny.origin, .zero)
    }

    func testColorOfAPixel() {
        let image = twoColorImage()

        XCTAssertEqual(ScreenshotMagnifier.color(of: image, at: CGPoint(x: 0, y: 0))?.hex, "#FF0000")
        XCTAssertEqual(ScreenshotMagnifier.color(of: image, at: CGPoint(x: 3, y: 1))?.hex, "#0000FF")
        XCTAssertNil(ScreenshotMagnifier.color(of: image, at: CGPoint(x: 4, y: 0)))
        XCTAssertNil(ScreenshotMagnifier.color(of: image, at: CGPoint(x: -1, y: 0)))
        XCTAssertEqual(ScreenshotMagnifier.RGB(red: 47, green: 140, blue: 255).hex, "#2F8CFF")
    }

    // MARK: Crop and encode

    func testCropUsesNativePixelsOfTheDisplay() throws {
        let display = ScreenSnapshot.Display(id: 2, frame: CGRect(x: 1512, y: 0, width: 100, height: 50), scale: 2,
                                             image: ScreenCaptureTestSupport.image(width: 200, height: 100))

        let image = try ScreenshotImageExporter.crop(display, to: CGRect(x: 1522, y: 10, width: 30.5, height: 20))
        XCTAssertEqual(image.width, 61)
        XCTAssertEqual(image.height, 40)

        // A region hanging off the display keeps only its part on it.
        let clipped = try ScreenshotImageExporter.crop(display, to: CGRect(x: 1600, y: 40, width: 50, height: 50))
        XCTAssertEqual(clipped.width, 24)
        XCTAssertEqual(clipped.height, 20)
    }

    func testCropOffTheDisplayFails() {
        let display = ScreenSnapshot.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 1,
                                             image: ScreenCaptureTestSupport.image(width: 100, height: 50))

        let offDisplay = CGRect(x: 200, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try ScreenshotImageExporter.crop(display, to: offDisplay)) {
            XCTAssertEqual($0 as? ScreenshotExportError, .emptyRegion)
        }
    }

    func testPNGKeepsPixelsAndRecordsTheScaleAsDPI() throws {
        let data = try ScreenshotImageExporter.png(twoColorImage(), scale: 2)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 4)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2)
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, 144)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(ScreenshotMagnifier.color(of: decoded, at: CGPoint(x: 3, y: 0))?.hex, "#0000FF")
    }

    // MARK: Output

    func testCopyPutsThePNGOnThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotExportTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let output = ScreenshotOutput(pasteboard: { pasteboard })
        let png = try ScreenshotImageExporter.png(twoColorImage(), scale: 1)

        XCTAssertTrue(output.copy(png))
        XCTAssertEqual(pasteboard.data(forType: .png), png)

        output.copy(text: "#FF0000")
        XCTAssertEqual(pasteboard.string(forType: .string), "#FF0000")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testSaveCreatesTheFolderAndNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotExportTests-\(UUID().uuidString)/nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let output = ScreenshotOutput()
        let date = Date(timeIntervalSince1970: 0)

        let first = try output.save(Data("one".utf8), in: directory, date: date)
        let second = try output.save(Data("two".utf8), in: directory, date: date)

        XCTAssertEqual(first.lastPathComponent, ScreenshotOutput.baseName(for: date) + ".png")
        XCTAssertEqual(second.lastPathComponent, ScreenshotOutput.baseName(for: date) + " (2).png")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testSaveIntoAFileFails() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotExportTests-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try ScreenshotOutput().save(Data("png".utf8), in: file, date: Date()))
    }

    func testFileNamesCountUpWhileTaken() {
        let directory = URL(fileURLWithPath: "/shots", isDirectory: true)
        var taken: Set<String> = ["/shots/Shot.png", "/shots/Shot (2).png"]

        XCTAssertEqual(ScreenshotOutput.availableURL(in: directory, baseName: "Shot") { taken.contains($0.path) }.path,
                       "/shots/Shot (3).png")
        taken = []
        XCTAssertEqual(ScreenshotOutput.availableURL(in: directory, baseName: "Shot") { taken.contains($0.path) }.path,
                       "/shots/Shot.png")
    }

    func testBaseNameContainsASortableTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: 2026, month: 10, day: 10, hour: 16, minute: 32, second: 41)
        let date = try XCTUnwrap(calendar.date(from: components))

        XCTAssertTrue(ScreenshotOutput.baseName(for: date).contains("2026-10-10 16.32.41"))
    }
}
