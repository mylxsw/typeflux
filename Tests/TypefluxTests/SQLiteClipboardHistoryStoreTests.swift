@testable import Typeflux
import XCTest

final class SQLiteClipboardHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteClipboardHistoryStore!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("SQLiteClipboardHistoryStoreTests")
        store = SQLiteClipboardHistoryStore(baseDir: directory, notificationCenter: NotificationCenter())
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    func testRecordsTextWithSourceAndListsNewestFirst() throws {
        let source = ClipboardSource(bundleID: "com.apple.Notes", appName: "Notes")
        store.record(.text("first"), source: source, at: date(0))
        store.record(.text("second"), source: nil, at: date(10))

        let items = store.items(limit: 10)
        XCTAssertEqual(items.map(\.text), ["second", "first"])
        let first = try XCTUnwrap(items.last)
        XCTAssertEqual(first.payload, .text)
        XCTAssertEqual(first.sourceAppName, "Notes")
        XCTAssertEqual(first.sourceBundleID, "com.apple.Notes")
        XCTAssertEqual(first.byteSize, 5)
        XCTAssertFalse(first.isPinned)
        XCTAssertEqual(store.items(limit: 1).count, 1)
    }

    func testCopyingAgainMovesTheItemUpAndKeepsItsSource() throws {
        let original = try XCTUnwrap(store.record(
            .text("same"), source: ClipboardSource(bundleID: "a", appName: "Mail"), at: date(0)
        ))
        store.record(.text("other"), source: nil, at: date(5))
        let bumped = try XCTUnwrap(store.record(
            .text("same"), source: ClipboardSource(bundleID: "b", appName: "Typeflux"), at: date(20)
        ))

        XCTAssertEqual(bumped.id, original.id)
        XCTAssertEqual(bumped.date, date(20))
        let items = store.items(limit: 10)
        XCTAssertEqual(items.map(\.text), ["same", "other"])
        XCTAssertEqual(items.first?.sourceAppName, "Mail")
    }

    func testImagesAreStoredAsFilesAndRemovedOnDelete() throws {
        let png = ClipboardTestSupport.imageData(width: 8, height: 6)
        let capture = ClipboardCapture.image(png: png, pixelWidth: 8, pixelHeight: 6)
        let item = try XCTUnwrap(store.record(capture, source: nil, at: date(0)))
        let path = try XCTUnwrap(item.imagePath)

        XCTAssertEqual(item.payload, .image)
        XCTAssertEqual(FileManager.default.contents(atPath: path), png)
        XCTAssertTrue(path.hasPrefix(store.imagesDirectory.path))
        XCTAssertEqual(store.items(limit: 1).first?.imagePixelWidth, 8)
        XCTAssertEqual(store.items(limit: 1).first?.imagePixelHeight, 6)
        XCTAssertEqual(item.byteSize, Int64(png.count))

        store.delete(id: item.id)
        XCTAssertTrue(store.items(limit: 10).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFilesKeepPathsAndTotalSize() throws {
        let pdf = ClipboardTestSupport.makeFile(named: "a.pdf", in: directory, bytes: 100)
        let zip = ClipboardTestSupport.makeFile(named: "b.zip", in: directory, bytes: 50)
        let item = try XCTUnwrap(store.record(.files([pdf, zip]), source: nil, at: date(0)))

        XCTAssertEqual(item.payload, .files)
        XCTAssertEqual(store.items(limit: 1).first?.filePaths, [pdf.path, zip.path])
        XCTAssertEqual(item.byteSize, 150)
    }

    func testPinnedItemsSurvivePurgeAndTrim() throws {
        let pinned = try XCTUnwrap(store.record(.text("pinned"), source: nil, at: date(0)))
        store.setPinned(true, id: pinned.id)
        store.record(.text("old"), source: nil, at: date(1))
        store.record(.text("mid"), source: nil, at: date(100))
        store.record(.text("new"), source: nil, at: date(200))

        store.purge(olderThan: date(50))
        XCTAssertEqual(Set(store.items(limit: 10).compactMap(\.text)), ["pinned", "mid", "new"])

        store.trim(toMaxCount: 1)
        let remaining = store.items(limit: 10)
        XCTAssertEqual(remaining.compactMap(\.text), ["new", "pinned"])
        XCTAssertTrue(remaining.last?.isPinned ?? false)

        store.setPinned(false, id: pinned.id)
        store.trim(toMaxCount: 0)
        XCTAssertTrue(store.items(limit: 10).isEmpty)
    }

    func testTrimCapsUnpinnedImagesSeparately() throws {
        let capped = SQLiteClipboardHistoryStore(
            baseDir: directory.appendingPathComponent("capped"),
            maximumImageCount: 1,
            notificationCenter: NotificationCenter()
        )
        func image(_ side: Int) -> ClipboardCapture {
            .image(png: ClipboardTestSupport.imageData(width: side, height: side), pixelWidth: side, pixelHeight: side)
        }
        let old = try XCTUnwrap(capped.record(image(2), source: nil, at: date(0)))
        let pinned = try XCTUnwrap(capped.record(image(3), source: nil, at: date(1)))
        capped.setPinned(true, id: pinned.id)
        capped.record(image(4), source: nil, at: date(2))
        capped.record(.text("text"), source: nil, at: date(3))

        capped.trim(toMaxCount: 10)

        let remaining = capped.items(limit: 10)
        XCTAssertEqual(remaining.map(\.payload), [.text, .image, .image])
        XCTAssertEqual(remaining.compactMap(\.imagePixelWidth), [4, 3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(old.imagePath)))
    }

    func testPurgeRemovesImageFiles() throws {
        let item = try XCTUnwrap(store.record(
            .image(png: ClipboardTestSupport.imageData(), pixelWidth: 4, pixelHeight: 3), source: nil, at: date(0)
        ))
        store.purge(olderThan: date(10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(item.imagePath)))
    }

    func testVoiceRecordPins() {
        let first = UUID()
        let second = UUID()
        store.setVoiceRecordPinned(true, recordID: first)
        store.setVoiceRecordPinned(true, recordID: second)
        store.setVoiceRecordPinned(true, recordID: second)
        XCTAssertEqual(store.pinnedVoiceRecordIDs(), [first, second])

        store.setVoiceRecordPinned(false, recordID: first)
        XCTAssertEqual(store.pinnedVoiceRecordIDs(), [second])
    }

    func testItemsPersistAcrossReopen() {
        store.record(.text("kept"), source: nil, at: date(0))
        store = nil
        let reopened = SQLiteClipboardHistoryStore(baseDir: directory, notificationCenter: NotificationCenter())
        XCTAssertEqual(reopened.items(limit: 10).compactMap(\.text), ["kept"])
    }

    func testChangesPostANotification() {
        let center = NotificationCenter()
        let observed = SQLiteClipboardHistoryStore(baseDir: directory, notificationCenter: center)
        let expectation = expectation(
            forNotification: .clipboardHistoryDidChange, object: nil, notificationCenter: center
        )
        observed.record(.text("ping"), source: nil, at: date(0))
        wait(for: [expectation], timeout: 2)
    }

    func testPurgeAndTrimThatRemoveNothingStayQuiet() {
        let center = NotificationCenter()
        let observed = SQLiteClipboardHistoryStore(baseDir: directory, notificationCenter: center)
        observed.record(.text("recent"), source: nil, at: date(100))
        // Let the record's own notification go out before counting.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        var posts = 0
        let token = center.addObserver(forName: .clipboardHistoryDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        observed.purge(olderThan: date(0))
        observed.trim(toMaxCount: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(posts, 0)

        observed.purge(olderThan: date(200))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(observed.items(limit: 10).isEmpty)

        observed.record(.text("a"), source: nil, at: date(300))
        observed.record(.text("b"), source: nil, at: date(301))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        posts = 0
        observed.trim(toMaxCount: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(observed.items(limit: 10).compactMap(\.text), ["b"])
    }

    func testUnwritableDatabaseFailsSoftly() {
        let file = directory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let broken = SQLiteClipboardHistoryStore(baseDir: file, notificationCenter: NotificationCenter())
        XCTAssertNil(broken.record(.text("x"), source: nil, at: date(0)))
        XCTAssertTrue(broken.items(limit: 10).isEmpty)
        XCTAssertTrue(broken.pinnedVoiceRecordIDs().isEmpty)
        broken.setPinned(true, id: UUID())
        broken.delete(id: UUID())
        broken.purge(olderThan: date(0))
        broken.trim(toMaxCount: 1)
    }
}
