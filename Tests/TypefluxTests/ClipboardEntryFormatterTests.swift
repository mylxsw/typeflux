@testable import Typeflux
import XCTest

final class ClipboardEntryFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func details(_ entry: ClipboardEntry) -> [String] {
        ClipboardEntryFormatter.details(for: entry, now: now)
    }

    func testTextualEntries() {
        let voice = ClipboardTestSupport.entry(.voice, date: now.addingTimeInterval(-5))
        XCTAssertEqual(details(voice), [L("clipboard.kind.voice"), L("clipboard.time.justNow")])

        let text = ClipboardTestSupport.entry(.text, date: now, text: "hello", sourceAppName: "Notes")
        XCTAssertEqual(
            Array(details(text).prefix(3)),
            [L("clipboard.kind.text"), L("clipboard.entry.characters", 5), "Notes"]
        )

        let link = ClipboardTestSupport.entry(.link, date: now, text: "https://github.com/mylxsw")
        XCTAssertEqual(Array(details(link).prefix(2)), [L("clipboard.kind.link"), "github.com"])

        let code = ClipboardTestSupport.entry(.code, date: now, sourceAppName: "")
        XCTAssertEqual(details(code), [L("clipboard.kind.code"), L("clipboard.time.justNow")])
    }

    func testVisualAndFileEntriesIncludeSizes() {
        let stored = ClipboardTestSupport.entry(
            .image, date: now, imagePath: "/i.png", imagePixelSize: CGSize(width: 1280, height: 720), byteSize: 2048
        )
        XCTAssertEqual(Array(details(stored).prefix(2)), ["PNG", "1280×720"])
        XCTAssertTrue(details(stored).contains(ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)))

        XCTAssertEqual(details(ClipboardTestSupport.entry(.image, date: now, filePaths: ["/a.jpeg"])).first, "JPEG")
        XCTAssertEqual(details(ClipboardTestSupport.entry(.images, date: now)).first, L("clipboard.kind.image"))
        XCTAssertEqual(details(ClipboardTestSupport.entry(.pdf, date: now)).first, "PDF")
        XCTAssertEqual(details(ClipboardTestSupport.entry(.document, date: now, filePaths: ["/a.key"])).first, "KEY")
        XCTAssertEqual(details(ClipboardTestSupport.entry(.video, date: now)).first, L("clipboard.kind.video"))
        XCTAssertEqual(details(ClipboardTestSupport.entry(.audio, date: now)).first, L("clipboard.kind.audio"))
        XCTAssertEqual(details(ClipboardTestSupport.entry(.files, date: now)).first, L("clipboard.kind.file"))
    }

    func testMediaInfoAddsLengthAndPages() {
        let info = ClipboardMediaInfo(duration: 222, pageCount: 12)
        let video = ClipboardTestSupport.entry(.video, date: now, byteSize: 1024, sourceAppName: "HapiGo")
        XCTAssertEqual(
            ClipboardEntryFormatter.details(for: video, info: ClipboardMediaInfo(duration: 17), now: now),
            [L("clipboard.kind.video"), "0:17", ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file),
             "HapiGo", L("clipboard.time.justNow")]
        )
        let audio = ClipboardTestSupport.entry(.audio, date: now)
        XCTAssertEqual(Array(ClipboardEntryFormatter.details(for: audio, info: info, now: now).prefix(2)),
                       [L("clipboard.kind.audio"), "3:42"])
        let pdf = ClipboardTestSupport.entry(.pdf, date: now)
        XCTAssertEqual(Array(ClipboardEntryFormatter.details(for: pdf, info: info, now: now).prefix(2)),
                       ["PDF", L("clipboard.preview.pages", 12)])
        // Facts that don't apply to a kind are ignored.
        let text = ClipboardTestSupport.entry(.text, date: now, text: "hi")
        XCTAssertEqual(ClipboardEntryFormatter.details(for: text, info: info, now: now), details(text))
    }

    func testDurationFormatting() {
        XCTAssertEqual(ClipboardEntryFormatter.duration(0), "0:00")
        XCTAssertEqual(ClipboardEntryFormatter.duration(16.6), "0:17")
        XCTAssertEqual(ClipboardEntryFormatter.duration(222), "3:42")
        XCTAssertEqual(ClipboardEntryFormatter.duration(3909), "1:05:09")
        XCTAssertEqual(ClipboardEntryFormatter.duration(-4), "0:00")
    }

    func testRelativeTime() {
        let recent = ClipboardEntryFormatter.relativeTime(from: now.addingTimeInterval(-30), to: now)
        XCTAssertEqual(recent, L("clipboard.time.justNow"))
        let older = ClipboardEntryFormatter.relativeTime(from: now.addingTimeInterval(-7200), to: now)
        XCTAssertFalse(older.isEmpty)
        XCTAssertNotEqual(older, L("clipboard.time.justNow"))
    }

    func testBadgeColorsDistinguishDocumentFamilies() {
        let pdf = ClipboardEntryFormatter.badgeColor(forFilePath: "/a.pdf")
        let word = ClipboardEntryFormatter.badgeColor(forFilePath: "/a.docx")
        let sheet = ClipboardEntryFormatter.badgeColor(forFilePath: "/a.xlsx")
        let slides = ClipboardEntryFormatter.badgeColor(forFilePath: "/a.key")
        let other = ClipboardEntryFormatter.badgeColor(forFilePath: "/a.zip")
        XCTAssertEqual(Set([pdf, word, sheet, slides, other].map { "\($0)" }).count, 5)
    }
}
