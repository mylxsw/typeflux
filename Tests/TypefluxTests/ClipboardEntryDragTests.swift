import AppKit
@testable import Typeflux
import XCTest

/// What a dragged clipboard entry carries, and how the panel reacts to the drop.
final class ClipboardEntryDragTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardEntryDragTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Writes `items` to a private pasteboard and returns it, so lazy data providers run.
    private func pasteboard(with items: [NSPasteboardWriting]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardEntryDragTests.\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertTrue(board.writeObjects(items))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testDragStartsOnlyPastTheThreshold() {
        XCTAssertFalse(ClipboardEntryDrag.beginsDrag(from: .zero, to: NSPoint(x: 2, y: 3)))
        XCTAssertTrue(ClipboardEntryDrag.beginsDrag(from: .zero, to: NSPoint(x: 0, y: -4)))
        XCTAssertTrue(ClipboardEntryDrag.beginsDrag(from: NSPoint(x: 10, y: 10), to: NSPoint(x: 13, y: 13)))
    }

    func testTextAndLinksCarryStringsAndLinksAlsoAURL() throws {
        let text = ClipboardTestSupport.entry(.text, text: "Meeting at 10")
        let board = pasteboard(with: ClipboardEntryDrag.items(for: text, isMissing: false))
        XCTAssertEqual(board.string(forType: .string), "Meeting at 10")
        XCTAssertNil(board.string(forType: .URL))

        let link = ClipboardTestSupport.entry(.link, text: "https://example.com/a")
        let linkBoard = pasteboard(with: ClipboardEntryDrag.items(for: link, isMissing: false))
        XCTAssertEqual(linkBoard.string(forType: .string), "https://example.com/a")
        XCTAssertEqual(linkBoard.string(forType: .URL), "https://example.com/a")

        let voice = ClipboardTestSupport.entry(.voice, text: "spoken")
        XCTAssertEqual(pasteboard(with: ClipboardEntryDrag.items(for: voice, isMissing: false))
            .string(forType: .string), "spoken")
        XCTAssertTrue(ClipboardEntryDrag.items(for: ClipboardTestSupport.entry(.text, text: ""), isMissing: false).isEmpty)
        let huge = String(repeating: "a", count: ClipboardCaptureRules.maximumTextBytes + 1)
        XCTAssertTrue(ClipboardEntryDrag.items(for: ClipboardTestSupport.entry(.text, text: huge), isMissing: false).isEmpty)
    }

    func testFilesCarryTheirURLsAndMissingFilesCannotBeDragged() throws {
        let first = directory.appendingPathComponent("a.txt")
        let second = directory.appendingPathComponent("b.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: second.path, contents: Data("b".utf8))
        let files = ClipboardTestSupport.entry(.files, filePaths: [first.path, second.path])
        let board = pasteboard(with: ClipboardEntryDrag.items(for: files, isMissing: false))
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.txt", "b.pdf"])
        XCTAssertTrue(ClipboardEntryDrag.items(for: files, isMissing: true).isEmpty)
        let nul = ClipboardTestSupport.entry(.files, filePaths: ["/tmp/a\u{0}b"])
        XCTAssertTrue(ClipboardEntryDrag.items(for: nul, isMissing: false).isEmpty)
    }

    func testStoredImageIsProvidedAsPNGDataOnlyWhileItIsTheRecordedFile() throws {
        let png = directory.appendingPathComponent("shot.png")
        let data = ClipboardTestSupport.imageData(width: 40, height: 30)
        FileManager.default.createFile(atPath: png.path, contents: data)
        let image = ClipboardTestSupport.entry(.image, imagePath: png.path)
        let items = ClipboardEntryDrag.items(for: image, isMissing: false)
        XCTAssertEqual(items.count, 1)
        let board = pasteboard(with: items)
        XCTAssertEqual(board.data(forType: .png), data)
        XCTAssertNil(board.propertyList(forType: .fileURL), "The stored file's path is not handed out")

        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: png)
        XCTAssertNil(ClipboardImageDragProvider(path: link.path).pngData(), "Only a regular file is read")
        XCTAssertNil(ClipboardImageDragProvider(path: directory.appendingPathComponent("gone.png").path).pngData())
        XCTAssertEqual(ClipboardImageDragProvider(path: png.path).pngData(), data)
        XCTAssertTrue(ClipboardEntryDrag.items(for: image, isMissing: true).isEmpty)
    }

    @MainActor
    func testControlCopiesOutsideTheAppAndReportsTheDrop() {
        XCTAssertEqual(ClipboardRowClickArea.Control.operationMask(for: .outsideApplication), .copy)
        XCTAssertEqual(ClipboardRowClickArea.Control.operationMask(for: .withinApplication), [])
        let control = ClipboardRowClickArea.Control()
        var ended: [Bool] = []
        control.onDragEnded = { ended.append($0) }
        control.finishDrag(operation: .copy)
        control.finishDrag(operation: [])
        XCTAssertEqual(ended, [true, false])
        XCTAssertFalse(control.isDragging)
        // A drag without a preceding mouse-down never starts.
        control.dragItems = { XCTFail("not asked"); return [] }
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)
        if let drag { control.mouseDragged(with: drag) }
        XCTAssertFalse(control.isDragging)
    }

    func testAcceptedDropClosesThePanel() {
        let model = ClipboardPanelModel()
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        model.dragEnded(accepted: false)
        XCTAssertEqual(dismissed, 0)
        model.dragEnded(accepted: true)
        XCTAssertEqual(dismissed, 1)
    }
}
