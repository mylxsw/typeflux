import AppKit
@testable import Typeflux
import XCTest

final class SystemClipboardContentActionsTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var directory: URL!
    private var downloads: URL!
    private var actions: SystemClipboardContentActions!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("SystemClipboardContentActionsTests-\(UUID().uuidString)"))
        directory = ClipboardTestSupport.temporaryDirectory("SystemClipboardContentActionsTests")
        downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        actions = SystemClipboardContentActions(pasteboard: pasteboard, downloadsDirectory: downloads, imageWorker: MediaWorker(timeout: 3), textWorker: MediaWorker(timeout: 30))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testWritesFilesAsURLsOrPaths() throws {
        let first = ClipboardTestSupport.makeFile(named: "a.pdf", in: directory)
        let second = ClipboardTestSupport.makeFile(named: "b.txt", in: directory)
        let entry = ClipboardTestSupport.entry(.files, filePaths: [first.path, second.path])

        XCTAssertTrue(actions.writeToPasteboard(entry, asPlainText: false, image: nil))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.pdf", "b.txt"])

        XCTAssertTrue(actions.writeToPasteboard(entry, asPlainText: true, image: nil))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(first.path)\n\(second.path)")
    }

    func testWritesStoredImagesAsPNGAndTIFF() async throws {
        let png = ClipboardTestSupport.imageData(width: 4, height: 4)
        let file = directory.appendingPathComponent("shot.png")
        FileManager.default.createFile(atPath: file.path, contents: png)

        let entry = ClipboardTestSupport.entry(.image, imagePath: file.path)
        let prepared = try await actions.prepareImage(entry)
        XCTAssertTrue(actions.writeToPasteboard(entry, asPlainText: false, image: prepared))
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testWritingFailsWithoutContent() {
        let missing = ClipboardTestSupport.entry(.image, imagePath: "/missing.png")
        XCTAssertFalse(actions.writeToPasteboard(missing, asPlainText: false, image: nil))
        XCTAssertFalse(actions.writeToPasteboard(ClipboardTestSupport.entry(.image), asPlainText: false, image: nil))
    }

    func testSavesCopiesIntoDownloadsWithoutOverwriting() throws {
        let source = ClipboardTestSupport.makeFile(named: "x.png", in: directory)
        let first = try XCTUnwrap(actions.saveToDownloads(source))
        let second = try XCTUnwrap(actions.saveToDownloads(source))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, downloads.standardizedFileURL)
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSaveFailsWithoutDownloadsOrSource() {
        XCTAssertNil(actions.saveToDownloads(directory.appendingPathComponent("missing.png")))
        let noDownloads = SystemClipboardContentActions(pasteboard: pasteboard, downloadsDirectory: nil)
        XCTAssertNil(noDownloads.saveToDownloads(directory))
    }

    func testRecognizesTextInImages() async throws {
        let png = ClipboardTestSupport.imageData(width: 900, height: 240, text: "TYPEFLUX")
        let file = directory.appendingPathComponent("text.png")
        try png.write(to: file)
        let text = try await actions.recognizeText(in: file)
        XCTAssertEqual(text?.uppercased().contains("TYPEFLUX"), true)

        let blank = directory.appendingPathComponent("blank.png")
        try ClipboardTestSupport.imageData(width: 200, height: 200).write(to: blank)
        let none = try await actions.recognizeText(in: blank)
        XCTAssertNil(none)

        let missing = try? await actions.recognizeText(in: directory.appendingPathComponent("missing.png"))
        XCTAssertNil(missing)
    }
}

final class SystemClipboardContentActionsRecognizerTests: XCTestCase {
    private struct UnreadableImage: Error {}

    private struct FixedRecognizer: ImageTextRecognizing {
        var result: Result<RecognizedText, Error>
        func recognizeText(in _: ImageTextSource) async throws -> RecognizedText { try result.get() }
    }

    func testUsesTheInjectedRecognizer() async throws {
        let lines = [RecognizedText.Line(text: "Injected", confidence: 1, boundingBox: .zero)]
        let actions = SystemClipboardContentActions(textRecognizer: FixedRecognizer(result: .success(RecognizedText(lines: lines))))
        let text = try await actions.recognizeText(in: URL(fileURLWithPath: "/unused.png"))
        XCTAssertEqual(text, "Injected")
    }

    func testRecognitionFailureIsDistinctFromEmptyText() async {
        let actions = SystemClipboardContentActions(textRecognizer: FixedRecognizer(result: .failure(UnreadableImage())))
        do { _ = try await actions.recognizeText(in: URL(fileURLWithPath: "/unused.png")); XCTFail("Failure became empty text") }
        catch { XCTAssertTrue(error is UnreadableImage) }
    }
}
