import AppKit
@testable import Typeflux
import XCTest

final class ClipboardCaptureRulesTests: XCTestCase {
    func testTextIsCapturedAsIs() {
        let contents = PasteboardContents(types: ["public.utf8-plain-text"], string: "  hello\n")
        let capture = ClipboardCaptureRules.capture(from: contents)
        XCTAssertEqual(capture, .text("  hello\n"))
    }

    func testWhitespaceOnlyAndEmptyContentsAreSkipped() {
        XCTAssertNil(ClipboardCaptureRules.capture(from: PasteboardContents(string: " \n\t")))
        XCTAssertNil(ClipboardCaptureRules.capture(from: PasteboardContents()))
    }

    func testOversizedTextIsSkipped() {
        let text = String(repeating: "a", count: ClipboardCaptureRules.maximumTextBytes + 1)
        XCTAssertNil(ClipboardCaptureRules.capture(from: PasteboardContents(string: text)))
    }

    func testPrivateAndTransientContentIsIgnored() {
        for type in ClipboardCaptureRules.ignoredTypes {
            let contents = PasteboardContents(types: [type, "public.utf8-plain-text"], string: "secret")
            XCTAssertNil(ClipboardCaptureRules.capture(from: contents), type)
            XCTAssertTrue(ClipboardCaptureRules.shouldIgnore(types: contents.types))
        }
        XCTAssertFalse(ClipboardCaptureRules.shouldIgnore(types: ["public.utf8-plain-text"]))
    }

    func testFileURLsWinOverTextAndImages() {
        let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(string: "https://example.com")!]
        let contents = PasteboardContents(string: "a.pdf", fileURLs: urls, imageData: ClipboardTestSupport.imageData())
        XCTAssertEqual(ClipboardCaptureRules.capture(from: contents), .files([URL(fileURLWithPath: "/tmp/a.pdf")]))
    }

    func testImageWithoutTextIsCapturedAsPNG() throws {
        let png = ClipboardTestSupport.imageData(width: 5, height: 2)
        let capture = try XCTUnwrap(ClipboardCaptureRules.capture(from: PasteboardContents(imageData: png)))
        XCTAssertEqual(capture, .image(png: png, pixelWidth: 5, pixelHeight: 2))
    }

    func testImageNextToItsURLIsCapturedAsImage() throws {
        let png = ClipboardTestSupport.imageData()
        let contents = PasteboardContents(string: "https://example.com/cat.png", imageData: png)
        guard case .image = try XCTUnwrap(ClipboardCaptureRules.capture(from: contents)) else {
            return XCTFail("Expected an image capture")
        }
    }

    func testImageNextToRealTextKeepsTheText() {
        // Office apps add a rendered picture of copied text; the text is what the user copied.
        let contents = PasteboardContents(string: "quarterly numbers", imageData: ClipboardTestSupport.imageData())
        XCTAssertEqual(ClipboardCaptureRules.capture(from: contents), .text("quarterly numbers"))
    }

    func testTIFFIsConvertedToPNG() throws {
        let tiff = ClipboardTestSupport.imageData(width: 6, height: 4, type: .tiff)
        let capture = try XCTUnwrap(ClipboardCaptureRules.image(from: tiff))
        guard case let .image(png, width, height) = capture else { return XCTFail("Expected an image") }
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(width, 6)
        XCTAssertEqual(height, 4)
    }

    func testUndecodableImageIsSkipped() {
        XCTAssertNil(ClipboardCaptureRules.image(from: Data([1, 2, 3])))
        XCTAssertNil(ClipboardCaptureRules.capture(from: PasteboardContents(imageData: Data([1, 2, 3]))))
    }

    func testContentHashIsStableAndPayloadSpecific() {
        XCTAssertEqual(ClipboardCapture.text("a").contentHash, ClipboardCapture.text("a").contentHash)
        XCTAssertNotEqual(ClipboardCapture.text("a").contentHash, ClipboardCapture.text("b").contentHash)
        XCTAssertNotEqual(
            ClipboardCapture.text("/tmp/a").contentHash,
            ClipboardCapture.files([URL(fileURLWithPath: "/tmp/a")]).contentHash
        )
        let png = ClipboardTestSupport.imageData()
        XCTAssertEqual(
            ClipboardCapture.image(png: png, pixelWidth: 1, pixelHeight: 1).contentHash,
            ClipboardCapture.image(png: png, pixelWidth: 2, pixelHeight: 2).contentHash
        )
    }
}
