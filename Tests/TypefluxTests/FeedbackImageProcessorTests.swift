import AppKit
@testable import Typeflux
import XCTest

final class FeedbackImageProcessorTests: XCTestCase {
    func testPrepareCompressesImageToJPEGWithinMaxDimension() throws {
        let imageURL = try makeTemporaryPNG(width: 2400, height: 1200)
        defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }

        let prepared = try FeedbackImageProcessor.prepare(url: imageURL)

        XCTAssertEqual(prepared.filename, "feedback-source.jpg")
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertFalse(prepared.data.isEmpty)

        let rep = try XCTUnwrap(NSBitmapImageRep(data: prepared.data))
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), FeedbackImageProcessor.maxPixelDimension)
    }

    func testPrepareImageDataCompressesPastedScreenshots() throws {
        let url = try makeTemporaryPNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = try Data(contentsOf: url)

        let prepared = try FeedbackImageProcessor.prepare(imageData: data, filename: "screenshot-1.png")

        XCTAssertEqual(prepared.filename, "screenshot-1.jpg")
        XCTAssertEqual(prepared.kind, .image)
        XCTAssertLessThanOrEqual(Int64(prepared.data.count), FeedbackAttachmentPolicy.maxImageBytes)
        XCTAssertNotNil(prepared.thumbnail)
    }

    func testPrepareKeepsGIFsUnchanged() throws {
        let png = try Data(contentsOf: makeTemporaryPNG(width: 20, height: 20))
        let prepared = try FeedbackImageProcessor.prepare(imageData: png, filename: "anim.gif")

        XCTAssertEqual(prepared.filename, "anim.gif")
        XCTAssertEqual(prepared.contentType, "image/gif")
        XCTAssertEqual(prepared.data, png)
    }

    func testPrepareRejectsDataThatIsNotAnImage() {
        XCTAssertThrowsError(try FeedbackImageProcessor.prepare(imageData: Data("nope".utf8), filename: "x.png"))
        XCTAssertThrowsError(try FeedbackImageProcessor.prepare(url: URL(fileURLWithPath: "/nonexistent/x.png")))
    }

    func testPrepareNamesImagesWithoutABaseName() throws {
        let png = try Data(contentsOf: makeTemporaryPNG(width: 20, height: 20))
        let prepared = try FeedbackImageProcessor.prepare(imageData: png, filename: ".png")
        XCTAssertTrue(prepared.filename.hasSuffix(".jpg"))
    }

    private func makeTemporaryPNG(width: Int, height: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-feedback-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()

        let rep = try XCTUnwrap(try NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("feedback-source.png")
        try data.write(to: url)
        return url
    }
}
