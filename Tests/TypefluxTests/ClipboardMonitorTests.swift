import AppKit
@testable import Typeflux
import XCTest

final class ClipboardMonitorTests: XCTestCase {
    private final class FakePasteboard: PasteboardReading {
        var changeCount = 0
        var contents = PasteboardContents()
        var readCount = 0

        func readContents() -> PasteboardContents {
            readCount += 1
            return contents
        }

        func copy(_ contents: PasteboardContents) {
            self.contents = contents
            changeCount += 1
        }
    }

    private var pasteboard: FakePasteboard!
    private var store: InMemoryClipboardHistoryStore!
    private var enabled = true
    private var monitor: ClipboardMonitor!
    private var uptime: TimeInterval = 100
    private var suppression: ClipboardCaptureSuppression!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        store = InMemoryClipboardHistoryStore()
        enabled = true
        uptime = 100
        suppression = ClipboardCaptureSuppression(gracePeriod: 1, uptime: { [unowned self] in uptime })
        monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            store: store,
            isEnabled: { [unowned self] in enabled },
            sourceProvider: { ClipboardSource(bundleID: "com.apple.Safari", appName: "Safari") },
            now: { Date(timeIntervalSince1970: 42) },
            suppression: suppression
        )
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    func testContentOnTheClipboardAtStartIsNotRecorded() {
        pasteboard.copy(PasteboardContents(string: "before launch"))
        monitor.start()
        XCTAssertFalse(monitor.poll())
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testNewTextIsRecordedWithSourceAndTrimmed() throws {
        monitor.start()
        pasteboard.copy(PasteboardContents(types: ["public.utf8-plain-text"], string: "hello"))

        XCTAssertTrue(monitor.poll())
        monitor.drain()

        let item = try XCTUnwrap(store.storedItems.first)
        XCTAssertEqual(item.text, "hello")
        XCTAssertEqual(item.sourceAppName, "Safari")
        XCTAssertEqual(item.date, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(store.trimCounts, [ClipboardMonitor.maximumItemCount])
    }

    func testUnchangedPasteboardIsNotReadAgain() {
        monitor.start()
        pasteboard.copy(PasteboardContents(string: "once"))
        XCTAssertTrue(monitor.poll())
        XCTAssertFalse(monitor.poll())
        monitor.drain()
        XCTAssertEqual(pasteboard.readCount, 1)
        XCTAssertEqual(store.storedItems.count, 1)
    }

    func testDisabledRecordingSkipsChangesWithoutReplayingThemLater() {
        monitor.start()
        enabled = false
        pasteboard.copy(PasteboardContents(string: "private"))
        XCTAssertFalse(monitor.poll())

        enabled = true
        XCTAssertFalse(monitor.poll())
        monitor.drain()
        XCTAssertTrue(store.storedItems.isEmpty)
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testTypefluxSelectionProbesAreNotRecorded() {
        monitor.start()
        suppression.begin()
        pasteboard.copy(PasteboardContents(string: "selected by Typeflux"))
        XCTAssertFalse(monitor.poll())
        suppression.end()

        // The restore right after the probe falls inside the grace period.
        uptime += 0.5
        pasteboard.copy(PasteboardContents(string: "restored"))
        XCTAssertFalse(monitor.poll())

        uptime += 1
        pasteboard.copy(PasteboardContents(string: "user copy"))
        XCTAssertTrue(monitor.poll())
        monitor.drain()
        XCTAssertEqual(store.storedItems.compactMap(\.text), ["user copy"])
    }

    func testSuppressionNests() {
        let suppression = ClipboardCaptureSuppression(gracePeriod: 0)
        XCTAssertFalse(suppression.isSuppressed)
        suppression.begin()
        suppression.begin()
        suppression.end()
        XCTAssertTrue(suppression.isSuppressed)
        suppression.end()
        suppression.end()
        XCTAssertFalse(suppression.isSuppressed)
    }

    func testConcealedContentIsIgnored() {
        monitor.start()
        pasteboard.copy(PasteboardContents(types: ["org.nspasteboard.ConcealedType"], string: "hunter2"))
        XCTAssertFalse(monitor.poll())
        monitor.drain()
        XCTAssertTrue(store.storedItems.isEmpty)
    }

    func testUndecodableContentIsDroppedOffTheMainThread() {
        monitor.start()
        pasteboard.copy(PasteboardContents(imageData: Data([0, 1])))
        XCTAssertTrue(monitor.poll())
        monitor.drain()
        XCTAssertTrue(store.storedItems.isEmpty)
    }

    func testImagesAreRecorded() throws {
        monitor.start()
        pasteboard.copy(PasteboardContents(imageData: ClipboardTestSupport.imageData(width: 3, height: 2)))
        XCTAssertTrue(monitor.poll())
        monitor.drain()
        let item = try XCTUnwrap(store.storedItems.first)
        XCTAssertEqual(item.payload, .image)
        XCTAssertEqual(item.imagePixelWidth, 3)
    }

    func testTimerPollsTheSystemRunLoop() {
        let fast = ClipboardMonitor(
            pasteboard: pasteboard, store: store, isEnabled: { true }, sourceProvider: { nil },
            suppression: ClipboardCaptureSuppression(), interval: 0.05
        )
        fast.start()
        fast.start()
        pasteboard.copy(PasteboardContents(string: "timer"))
        let deadline = Date().addingTimeInterval(2)
        while store.storedItems.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            fast.drain()
        }
        fast.stop()
        XCTAssertEqual(store.storedItems.first?.text, "timer")
    }

    func testFrontmostApplicationSourceDescribesARunningApp() {
        let source = ClipboardMonitor.frontmostApplicationSource()
        if let source {
            XCTAssertNotNil(source.bundleID ?? source.appName)
        }
    }

    func testSystemPasteboardReaderReadsTextFilesAndImages() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("ClipboardMonitorTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let reader = SystemPasteboardReader(pasteboard: board)

        board.clearContents()
        board.setString("plain", forType: .string)
        XCTAssertEqual(reader.readContents().string, "plain")
        XCTAssertTrue(reader.readContents().types.contains(NSPasteboard.PasteboardType.string.rawValue))

        let directory = ClipboardTestSupport.temporaryDirectory()
        let file = ClipboardTestSupport.makeFile(named: "doc.pdf", in: directory)
        board.clearContents()
        board.writeObjects([file as NSURL])
        XCTAssertEqual(reader.readContents().fileURLs.map(\.lastPathComponent), ["doc.pdf"])
        XCTAssertNil(reader.readContents().imageData)

        let png = ClipboardTestSupport.imageData()
        board.clearContents()
        board.setData(png, forType: .png)
        XCTAssertEqual(reader.readContents().imageData, png)

        let changeCount = reader.changeCount
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.writeObjects([item])
        XCTAssertGreaterThan(reader.changeCount, changeCount)
        let concealed = reader.readContents()
        XCTAssertNil(concealed.string)
        XCTAssertTrue(ClipboardCaptureRules.shouldIgnore(types: concealed.types))
    }
}
