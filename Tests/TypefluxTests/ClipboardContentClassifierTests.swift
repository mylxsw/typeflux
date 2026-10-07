@testable import Typeflux
import XCTest

final class ClipboardContentClassifierTests: XCTestCase {
    func testLinksNeedAnHTTPSchemeAndHostWithoutSpaces() {
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: " https://github.com/mylxsw/typeflux \n"), .link)
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: "http://localhost:8080/path?q=1"), .link)
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: "see https://github.com"), .text)
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: "ftp://files.example.com"), .text)
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: "https://"), .text)
        XCTAssertFalse(ClipboardContentClassifier.isLink(""))
    }

    func testCodeNeedsSeveralLinesOfCodeMarkers() {
        let swift = "func load() {\n    return items\n}"
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: swift), .code)
        XCTAssertEqual(ClipboardContentClassifier.kind(forText: "let x = 1"), .text)
        XCTAssertEqual(
            ClipboardContentClassifier.kind(forText: "Dear team,\nthanks for the update.\nSee you soon."),
            .text
        )
    }

    func testSingleFileKindsFollowTheirType() {
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/report.PDF"), .pdf)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/logo.png"), .image)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/demo.mov"), .video)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/demo.mp4"), .video)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/talk.m4a"), .audio)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/plan.docx"), .document)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePath: "/a/Makefile"), .document)
    }

    func testMultipleFilesAreImagesOnlyWhenAllAreImages() {
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePaths: ["/a.png", "/b.jpg"]), .images)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePaths: ["/a.png", "/b.pdf"]), .files)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePaths: ["/b.pdf"]), .pdf)
        XCTAssertEqual(ClipboardContentClassifier.kind(forFilePaths: []), .files)
    }

    func testBadgesUseTheUppercasedExtension() {
        XCTAssertEqual(ClipboardContentClassifier.badge(forFilePath: "/a/plan.docx"), "DOCX")
        XCTAssertEqual(ClipboardContentClassifier.badge(forFilePath: "/a/archive.tar.gzip"), "GZIP")
        XCTAssertEqual(ClipboardContentClassifier.badge(forFilePath: "/a/Makefile"), "FILE")
    }

    func testKindCategoriesAndTextuality() {
        XCTAssertEqual(ClipboardEntryKind.voice.category, .voice)
        XCTAssertEqual(ClipboardEntryKind.code.category, .text)
        XCTAssertEqual(ClipboardEntryKind.images.category, .image)
        XCTAssertEqual(ClipboardEntryKind.audio.category, .file)
        XCTAssertTrue(ClipboardEntryKind.link.isTextual)
        XCTAssertFalse(ClipboardEntryKind.image.isTextual)
        XCTAssertEqual(ClipboardCategory.allCases.map(\.id), ["all", "text", "image", "file", "voice"])
        XCTAssertTrue(ClipboardCategory.allCases.allSatisfy { !$0.title.isEmpty && !$0.title.hasPrefix("clipboard.") })
    }
}
