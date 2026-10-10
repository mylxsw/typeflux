import AppKit
@testable import Typeflux
import XCTest

final class ImageTextRecognizerTests: XCTestCase {
    private var directory: URL!
    private let recognizer = VisionImageTextRecognizer()

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ImageTextRecognizerTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// White 900 × 400 px with "TYPEFLUX" near the top edge.
    private func textNearTopImage() throws -> CGImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 400).fill()
        ("TYPEFLUX" as NSString).draw(at: NSPoint(x: 20, y: 300), withAttributes: [
            .font: NSFont.systemFont(ofSize: 60, weight: .bold), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.cgImage)
    }

    func testRecognizesTextInCGImagesWithTopLeftBounds() async throws {
        let result = try await recognizer.recognizeText(in: .image(textNearTopImage()))
        let line = try XCTUnwrap(result.lines.first { $0.text.uppercased().contains("TYPEFLUX") })
        XCTAssertGreaterThan(line.confidence, 0)
        // Drawn near the top edge, so a top-left box sits in the upper part of the image.
        XCTAssertLessThan(line.boundingBox.midY, 0.4)
        XCTAssertLessThan(line.boundingBox.minX, 0.2)
        let pixels = line.pixelRect(imageWidth: 900, imageHeight: 400)
        XCTAssertGreaterThan(pixels.width, 100)
        XCTAssertLessThan(pixels.maxY, 200)
        XCTAssertEqual(result.string?.uppercased().contains("TYPEFLUX"), true)
    }

    func testRecognizesTextInFiles() async throws {
        let file = directory.appendingPathComponent("text.png")
        try ClipboardTestSupport.imageData(width: 900, height: 240, text: "TYPEFLUX").write(to: file)
        let result = try await recognizer.recognizeText(in: .url(file))
        XCTAssertEqual(result.string?.uppercased().contains("TYPEFLUX"), true)
    }

    func testBlankImagesHaveNoText() async throws {
        let data = ClipboardTestSupport.imageData(width: 200, height: 200)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        let result = try await recognizer.recognizeText(in: .image(image))
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertNil(result.string)
    }

    func testMissingFilesThrow() async {
        do {
            _ = try await recognizer.recognizeText(in: .url(directory.appendingPathComponent("missing.png")))
            XCTFail("Expected a failure")
        } catch {}
    }

    func testJoinsAndTrimsLines() {
        let lines = [" first", "second ", "  "].map {
            RecognizedText.Line(text: $0, confidence: 1, boundingBox: .zero)
        }
        XCTAssertEqual(RecognizedText(lines: lines).string, "first\nsecond")
        let blank = RecognizedText.Line(text: " \n", confidence: 1, boundingBox: .zero)
        XCTAssertNil(RecognizedText(lines: [blank]).string)
        XCTAssertNil(RecognizedText(lines: []).string)
    }

    func testConvertsVisionBoxesToTopLeftOrigin() {
        let box = RecognizedText.topLeftBox(fromVision: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2))
        XCTAssertEqual(box.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.2, accuracy: 1e-9)
        let line = RecognizedText.Line(text: "x", confidence: 1, boundingBox: box)
        let pixels = line.pixelRect(imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(pixels.minX, 100, accuracy: 1e-6)
        XCTAssertEqual(pixels.minY, 50, accuracy: 1e-6)
        XCTAssertEqual(pixels.width, 500, accuracy: 1e-6)
        XCTAssertEqual(pixels.height, 100, accuracy: 1e-6)
    }
}
