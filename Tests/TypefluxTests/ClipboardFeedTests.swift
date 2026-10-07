@testable import Typeflux
import XCTest

final class ClipboardFeedTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ payload: ClipboardItem.Payload = .text,
        text: String? = nil,
        filePaths: [String] = [],
        imagePath: String? = nil,
        offset: TimeInterval,
        pinned: Bool = false,
        app: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(), payload: payload, date: base.addingTimeInterval(offset), text: text, filePaths: filePaths,
            imagePath: imagePath,
            imagePixelWidth: imagePath == nil ? nil : 10,
            imagePixelHeight: imagePath == nil ? nil : 20,
            byteSize: 99, contentHash: UUID().uuidString, sourceBundleID: nil, sourceAppName: app, isPinned: pinned
        )
    }

    private func voice(_ text: String, offset: TimeInterval) -> HistoryRecord {
        HistoryRecord(date: base.addingTimeInterval(offset), transcriptText: text)
    }

    func testMergesVoiceAndClipboardNewestFirstWithPinnedOnTop() {
        let pinned = item(text: "pinned", offset: 0, pinned: true)
        let entries = ClipboardFeed.entries(
            clipboardItems: [item(text: "copied", offset: 20), pinned],
            voiceRecords: [voice("spoken", offset: 30), voice("older", offset: 10)],
            pinnedVoiceRecordIDs: []
        )
        XCTAssertEqual(entries.map(\.title), ["pinned", "spoken", "copied", "older"])
        XCTAssertEqual(entries.map(\.kind), [.text, .voice, .text, .voice])
    }

    func testCopiedVoiceTextFoldsIntoTheVoiceEntry() {
        let record = voice("hello world", offset: 0)
        let entries = ClipboardFeed.entries(
            clipboardItems: [item(text: "hello world\n", offset: 50)],
            voiceRecords: [record, voice("hello world", offset: -10)],
            pinnedVoiceRecordIDs: [record.id]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.origin, .voice(record.id))
        XCTAssertEqual(entries.first?.date, base.addingTimeInterval(50))
        XCTAssertEqual(entries.first?.isPinned, true)
    }

    func testVoiceRecordsWithoutTextAreSkipped() {
        let entries = ClipboardFeed.entries(
            clipboardItems: [],
            voiceRecords: [HistoryRecord(date: base, transcriptText: "  "), HistoryRecord(date: base)],
            pinnedVoiceRecordIDs: []
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func testEntryMapsPayloadsToKinds() {
        let image = ClipboardFeed.entry(for: item(.image, imagePath: "/tmp/x.png", offset: 0))
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.imagePixelSize, CGSize(width: 10, height: 20))
        XCTAssertNil(image.text)

        let files = ClipboardFeed.entry(for: item(.files, filePaths: ["/a.mov"], offset: 0, app: "Finder"))
        XCTAssertEqual(files.kind, .video)
        XCTAssertEqual(files.sourceAppName, "Finder")
        XCTAssertEqual(files.byteSize, 99)

        XCTAssertEqual(ClipboardFeed.entry(for: item(text: "https://a.b", offset: 0)).kind, .link)
        XCTAssertEqual(ClipboardFeed.entry(for: item(text: nil, offset: 0)).kind, .text)
    }

    func testFilterByCategoryAndQuery() {
        let entries = ClipboardFeed.entries(
            clipboardItems: [
                item(text: "Quarterly Report", offset: 5, app: "Notes"),
                item(.files, filePaths: ["/docs/Report.pdf"], offset: 4),
                item(.image, imagePath: "/tmp/i.png", offset: 3, app: "Safari")
            ],
            voiceRecords: [voice("dictated report", offset: 2)],
            pinnedVoiceRecordIDs: []
        )
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .all, query: "").count, 4)
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .text, query: "").map(\.title), ["Quarterly Report"])
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .file, query: "").map(\.title), ["Report.pdf"])
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .image, query: "").count, 1)
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .voice, query: "").map(\.kind), [.voice])
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .all, query: " report ").count, 3)
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .all, query: "safari").count, 1)
        XCTAssertTrue(ClipboardFeed.filter(entries, category: .voice, query: "pdf").isEmpty)
    }

    func testSections() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        func section(_ offset: TimeInterval, pinned: Bool = false) -> ClipboardFeed.Section {
            ClipboardFeed.section(
                for: ClipboardTestSupport.entry(.text, date: now.addingTimeInterval(offset), isPinned: pinned),
                now: now,
                calendar: calendar
            )
        }
        XCTAssertEqual(section(-60), .today)
        XCTAssertEqual(section(-9 * 3600), .yesterday)
        XCTAssertEqual(section(-3 * 86400), .earlier)
        XCTAssertEqual(section(-3 * 86400, pinned: true), .pinned)
        for value in [ClipboardFeed.Section.pinned, .today, .yesterday, .earlier] {
            XCTAssertFalse(value.title.hasPrefix("clipboard."))
        }
    }

    func testEntryTitlesAndURLs() {
        XCTAssertEqual(ClipboardTestSupport.entry(.text, text: "abc").title, "abc")
        XCTAssertEqual(ClipboardTestSupport.entry(.pdf, filePaths: ["/a/b.pdf"]).title, "b.pdf")
        let twoFiles = ClipboardTestSupport.entry(.files, filePaths: ["/a", "/b"])
        XCTAssertEqual(twoFiles.title, L("clipboard.entry.fileCount", 2))
        let twoImages = ClipboardTestSupport.entry(.images, filePaths: ["/a.png", "/b.png"])
        XCTAssertEqual(twoImages.title, L("clipboard.entry.imageCount", 2))
        XCTAssertEqual(ClipboardTestSupport.entry(.image, imagePath: "/i.png").title, L("clipboard.entry.image"))

        let image = ClipboardTestSupport.entry(.image, imagePath: "/i.png")
        XCTAssertEqual(image.contentURLs, [URL(fileURLWithPath: "/i.png")])
        let files = ClipboardTestSupport.entry(.files, filePaths: ["/a", "/b"])
        XCTAssertEqual(files.contentURLs, files.fileURLs)

        let id = UUID()
        XCTAssertEqual(ClipboardTestSupport.entry(.voice, id: id).id, "voice-\(id.uuidString)")
        XCTAssertEqual(ClipboardTestSupport.entry(.text, id: id).id, "clipboard-\(id.uuidString)")
    }
}
