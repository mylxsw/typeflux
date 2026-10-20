import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackRichTextTests {
    private func body(_ text: String, format: FeedbackBlockFormat? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: FeedbackRichText.paragraphAttributes(for: format))
    }

    private func markdown(_ parts: [NSAttributedString], attachments: [UUID: String] = [:]) -> String {
        let result = NSMutableAttributedString()
        for part in parts {
            result.append(part)
        }
        return FeedbackRichText.markdown(from: result) { attachments[$0] }
    }

    @Test func `plain paragraphs are separated by blank lines`() {
        #expect(markdown([body("one\n"), body("two")]) == "one\n\ntwo")
        #expect(markdown([body("")]) == "")
    }

    @Test func `blocks serialize to markdown`() {
        let text = markdown([
            body("Title\n", format: .heading),
            body("a\n", format: .bulletList), body("b\n", format: .bulletList),
            body("x\n", format: .numberedList), body("y\n", format: .numberedList),
            body("said\n", format: .quote),
            body("line1\n", format: .code), body("line2\n", format: .code),
            body("after")
        ])
        #expect(text == "## Title\n\n- a\n- b\n\n1. x\n2. y\n\n> said\n\n```\nline1\nline2\n```\n\nafter")
    }

    @Test func `code block at the end is closed`() {
        #expect(markdown([body("log\n", format: .code)]) == "```\nlog\n```")
    }

    @Test func `numbered list restarts after another block`() {
        let text = markdown([
            body("x\n", format: .numberedList), body("p\n"), body("y\n", format: .numberedList)
        ])
        #expect(text == "1. x\n\np\n\n1. y")
    }

    @Test func `inline formats serialize with markers outside the spaces`() throws {
        var bold = FeedbackRichText.baseAttributes
        bold[.font] = NSFontManager.shared.convert(FeedbackRichText.baseFont, toHaveTrait: .boldFontMask)
        var italic = FeedbackRichText.baseAttributes
        italic[.font] = NSFontManager.shared.convert(FeedbackRichText.baseFont, toHaveTrait: .italicFontMask)
        var both = bold
        both[.font] = try NSFontManager.shared.convert(#require(bold[.font] as? NSFont), toHaveTrait: .italicFontMask)
        var strike = FeedbackRichText.baseAttributes
        strike[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        var code = FeedbackRichText.baseAttributes
        code[FeedbackRichText.codeKey] = true
        var link = FeedbackRichText.baseAttributes
        link[.link] = try #require(URL(string: "https://example.com"))
        var badLink = FeedbackRichText.baseAttributes
        badLink[.link] = try #require(URL(string: "javascript:alert(1)"))

        let text = NSMutableAttributedString()
        for (string, attributes) in [
            (" b ", bold), ("i", italic), ("bi", both), ("s", strike), ("c", code), ("l", link), ("x", badLink),
            ("  ", bold)
        ] as [(String, [NSAttributedString.Key: Any])] {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        let result = FeedbackRichText.markdown(from: text) { _ in nil }
        #expect(result == " **b** *i****bi***~~s~~`c`[l](https://example.com)x  ")
    }

    @Test func `attachments become images or links where they stand`() {
        let imageID = UUID(), fileID = UUID(), pendingID = UUID()
        let text = NSMutableAttributedString(string: "before\n", attributes: FeedbackRichText.baseAttributes)
        for id in [imageID, fileID, pendingID] {
            text.append(NSAttributedString(attachment: FeedbackTextAttachment(attachmentID: id)))
            text.append(NSAttributedString(string: "\n", attributes: FeedbackRichText.baseAttributes))
        }
        text.append(NSAttributedString(string: "after", attributes: FeedbackRichText.baseAttributes))
        let result = FeedbackRichText.markdown(from: text) {
            [imageID: "![a.jpg](https://cdn/a.jpg)", fileID: "[l.log](https://cdn/l.log)"][$0]
        }
        #expect(result == "before\n\n![a.jpg](https://cdn/a.jpg)\n\n[l.log](https://cdn/l.log)\n\nafter")
    }

    @Test(arguments: [
        ("example.com", "https://example.com"), ("http://a.org/x", "http://a.org/x"),
        (" https://a.org ", "https://a.org")
    ])
    func `links accept http and https`(input: String, expected: String) {
        #expect(FeedbackRichText.normalizedLinkURL(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "javascript:alert(1)", "file:///etc/passwd", "ftp://a.org", "https://"])
    func `links refuse other schemes`(input: String) {
        #expect(FeedbackRichText.normalizedLinkURL(input) == nil)
    }

    @Test func `pasted text keeps only the supported formats`() {
        let source = NSMutableAttributedString()
        source.append(NSAttributedString(string: "plain ", attributes: [
            .font: NSFont(name: "Times New Roman", size: 30) ?? .systemFont(ofSize: 30),
            .foregroundColor: NSColor.red, .backgroundColor: NSColor.yellow
        ]))
        source.append(NSAttributedString(string: "bold", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20), .underlineStyle: 1,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ]))
        source.append(NSAttributedString(string: " site", attributes: [.link: "https://example.com"]))
        source.append(NSAttributedString(string: " evil", attributes: [.link: "javascript:alert(1)"]))
        source.append(NSAttributedString(attachment: FeedbackTextAttachment(attachmentID: UUID())))

        let clean = FeedbackRichText.sanitized(source)

        #expect(clean.string == "plain bold site evil")
        let first = clean.attributes(at: 0, effectiveRange: nil)
        #expect((first[.font] as? NSFont)?.pointSize == FeedbackRichText.baseFontSize)
        #expect(first[.backgroundColor] == nil)
        #expect(first[.foregroundColor] as? NSColor == NSColor.labelColor)
        let boldRun = clean.attributes(at: 6, effectiveRange: nil)
        #expect((boldRun[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(boldRun[.strikethroughStyle] != nil)
        #expect(boldRun[.underlineStyle] == nil)
        #expect((clean.attributes(at: 11, effectiveRange: nil)[.link] as? URL)?.absoluteString == "https://example.com")
        #expect(clean.attributes(at: clean.length - 1, effectiveRange: nil)[.link] == nil)
    }

    @Test(arguments: [
        ("-", FeedbackBlockFormat.bulletList), ("*", .bulletList), ("1.", .numberedList), ("12.", .numberedList),
        (">", .quote), ("#", .heading), ("##", .heading)
    ])
    func `markdown shortcuts map to blocks`(prefix: String, format: FeedbackBlockFormat) {
        #expect(FeedbackTextView.shortcutFormat(for: prefix) == format)
    }

    @Test(arguments: ["a.", "x", "-1", "####", ".", "1"])
    func `other prefixes are not shortcuts`(prefix: String) {
        #expect(FeedbackTextView.shortcutFormat(for: prefix) == nil)
    }
}
