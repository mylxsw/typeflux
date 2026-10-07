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
