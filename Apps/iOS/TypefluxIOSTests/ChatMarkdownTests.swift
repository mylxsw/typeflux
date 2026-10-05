import Foundation
import Testing
@testable import TypefluxIOS
import UIKit

struct ChatMarkdownTests {
    @Test func `paragraph boundaries and soft line breaks survive parsing`() {
        #expect(ChatMarkdown.parse("First line\r\nsecond line\r\n\r\nThird paragraph") == [
            .paragraph("First line\nsecond line"), .paragraph("Third paragraph")
        ])
        #expect(ChatMarkdown.parse(" \n\t\n").isEmpty)
        #expect(ChatMarkdown.parse("One\r\rTwo") == [.paragraph("One"), .paragraph("Two")])
    }

    @Test func `headings preserve levels and inline markup`() {
        #expect(ChatMarkdown.parse("# **Title**\n### Subtitle\n###### Small\n#not-heading\n####### Too many") == [
            .heading(1, "**Title**"), .heading(3, "Subtitle"), .heading(6, "Small"),
            .paragraph("#not-heading\n####### Too many")
        ])
    }

    @Test func `lists retain numbering and nested indentation`() {
        #expect(ChatMarkdown.parse("- One\n  * Two\n\t+ Three\n7. Seven\n8) Eight\n2.No list") == [
            .listItem(marker: "•", text: "One", depth: 0),
            .listItem(marker: "•", text: "Two", depth: 1),
            .listItem(marker: "•", text: "Three", depth: 2),
            .listItem(marker: "7.", text: "Seven", depth: 0),
            .listItem(marker: "8.", text: "Eight", depth: 0),
            .paragraph("2.No list")
        ])
    }

    @Test func `fences preserve code whitespace and ignore embedded markdown`() {
        #expect(ChatMarkdown.parse("Before\n```swift\n  let value = 1\n\n# literal\n```\nAfter") == [
            .paragraph("Before"), .code(language: "swift", text: "  let value = 1\n\n# literal"), .paragraph("After")
        ])
    }

    @Test func `streaming unclosed and longer fences preserve content`() {
        #expect(ChatMarkdown.parse("```\npartial()") == [.code(language: "", text: "partial()")])
        #expect(ChatMarkdown.parse("~~~~text\n~~~\nbody\n~~~~") == [.code(language: "text", text: "~~~\nbody")])
        #expect(ChatMarkdown.parse("``inline``") == [.paragraph("``inline``")])
    }

    @Test func `quotes and dividers have distinct blocks`() {
        #expect(ChatMarkdown.parse("> One\n> **Two**\n---\n* * *\n___\n--\n-*-") == [
            .quote("One\n**Two**"), .divider, .divider, .divider, .paragraph("--\n-*-")
        ])
    }

    @Test func `tables accept alignment and fill missing trailing cells`() {
        #expect(ChatMarkdown.parse("| Name | Value |\n| :--- | ---: |\n| A | 1 |\n| B |\n\nAfter") == [
            .table(headers: ["Name", "Value"], rows: [["A", "1"], ["B", ""]]), .paragraph("After")
        ])
        #expect(ChatMarkdown.parse("A | B\n--- | ---\nx | y") == [
            .table(headers: ["A", "B"], rows: [["x", "y"]])
        ])
    }

    @Test func `escaped and inline code pipes do not create columns`() {
        #expect(ChatMarkdown.tableCells(#"| a\|b | `c|d` | ``e`|f`` |"#) == ["a|b", "`c|d`", "``e`|f``"])
        #expect(ChatMarkdown.tableCells(#"| \*literal\* | tail\"#) == [#"\*literal\*"#, #"tail\"#])
        #expect(ChatMarkdown.tableCells("plain text") == nil)
        #expect(ChatMarkdown.tableCells("|") == nil)
    }

    @Test func `invalid tables remain prose and extra cells are not dropped`() {
        #expect(ChatMarkdown.parse("A | B\n-- | ---\nx | y") == [.paragraph("A | B\n-- | ---\nx | y")])
        #expect(ChatMarkdown.parse("A | B\n---\nx | y") == [.paragraph("A | B"), .divider, .paragraph("x | y")])
        #expect(ChatMarkdown.parse("A | B\n--- | ---\nx | y | z") == [
            .table(headers: ["A", "B"], rows: []), .paragraph("x | y | z")
        ])
    }
}

@MainActor
struct ChatSelectableContentTests {
    @Test func `paragraphs headings lists and quotes share a contiguous selection`() throws {
        let blocks = ChatMarkdown.parse("# Heading\n\nFirst line\nsecond line\n\n- One\n  - Two\n> Quote\n---\nLast")
        #expect(ChatSelectableContent.groups(blocks) == [blocks])
        let rendered = ChatSelectableContent.render(blocks)
        #expect(rendered
            .string == "Heading\n\nFirst line\nsecond line\n\n•  One\n\n•  Two\n\nQuote\n\n────────\n\nLast")
        let view = UITextView()
        view.isEditable = false
        view.attributedText = rendered
        let start = (rendered.string as NSString).range(of: "second").location
        let end = NSMaxRange((rendered.string as NSString).range(of: "Two"))
        view.selectedRange = NSRange(location: start, length: end - start)
        #expect(try view.text(in: #require(view.selectedTextRange)) == "second line\n\n•  One\n\n•  Two")
        view.copy(nil)
        #expect(UIPasteboard.general.string == "second line\n\n•  One\n\n•  Two")
    }

    @Test func `complex blocks keep their cards but full selection includes every cell and code line`() {
        let blocks = ChatMarkdown
            .parse("Before\n```swift\n  let a = 1\n\nlet b = 2\n```\nA | B\n--- | ---\nx | y\n\nAfter")
        #expect(ChatSelectableContent.groups(blocks).count == 4)
        #expect(ChatSelectableContent.groups([]).isEmpty)
        let text = ChatSelectableContent.render(blocks).string
        #expect(text == "Before\n\n  let a = 1\n\nlet b = 2\n\nA | B\nx | y\n\nAfter")
        #expect(ChatSelectableContent.render([]).length == 0)
    }

    @Test func `inline styles and links survive native rendering`() throws {
        let text = ChatSelectableContent
            .render([.paragraph("**Bold** *Italic* `code` ~~deleted~~ [Link](https://example.com)")])
        #expect(text.string == "Bold Italic code deleted Link")
        func attributes(_ value: String) -> [NSAttributedString.Key: Any] {
            text.attributes(at: (text.string as NSString).range(of: value).location, effectiveRange: nil)
        }
        let bold = try #require(attributes("Bold")[.font] as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let italic = try #require(attributes("Italic")[.font] as? UIFont)
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        let code = try #require(attributes("code")[.font] as? UIFont)
        #expect(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(attributes("deleted")[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attributes("Link")[.link] as? URL == URL(string: "https://example.com"))
    }

    @Test func `plain user text preserves markdown literals emoji and newlines`() throws {
        let source = "**literal**\n👨‍👩‍👧‍👦 中文\n\nlast"
        #expect(ChatSelectableContent.render([], plainText: source).string == source)
        let view = UITextView()
        view.attributedText = ChatSelectableContent.render([], plainText: source)
        let range = (source as NSString).range(of: "👨‍👩‍👧‍👦 中文\n\nlast")
        view.selectedRange = range
        #expect(try view.text(in: #require(view.selectedTextRange)) == "👨‍👩‍👧‍👦 中文\n\nlast")
    }

    @Test func `streaming appends and unrelated updates preserve a selected range`() throws {
        let view = UITextView()
        let initial = ChatSelectableContent.render([.paragraph("First\n\nSecond")])
        ChatSelectableText.update(view, text: initial)
        let range = NSRange(location: 2, length: 7)
        view.selectedRange = range
        ChatSelectableText.update(view, text: initial)
        #expect(view.selectedRange == range)
        ChatSelectableText.update(view, text: ChatSelectableContent.render([.paragraph("First\n\nSecond\n\nThird")]))
        #expect(view.selectedRange == range)
        #expect(try view.text(in: #require(view.selectedTextRange)) == "rst\n\nSe")
        ChatSelectableText.update(view, text: NSAttributedString(string: "X"))
        #expect(NSMaxRange(view.selectedRange) <= 1)
    }

    @Test func `fonts grow with accessibility sizes and colors adapt to appearance`() throws {
        let blocks: [ChatMarkdown.Block] = [.heading(1, "Large"), .heading(2, "Medium"), .heading(4, "Small"),
                                            .quote("Quote"), .code(language: "", text: "code")]
        let normal = ChatSelectableContent.render(
            blocks,
            traits: UITraitCollection(preferredContentSizeCategory: .large)
        )
        let large = ChatSelectableContent.render(
            blocks,
            traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        let normalFont = try #require(normal.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let largeFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(largeFont.pointSize > normalFont.pointSize)
        let color = try #require(normal.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        #expect(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) !=
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    }

    @Test func `short user messages retain compact bubble width`() {
        let view = UITextView()
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = ChatSelectableContent.render([], plainText: "Hello")
        let compact = ChatSelectableText.fittingSize(view, width: 300, fitsContent: true)
        #expect(compact.width < 60)
        #expect(compact.height > 0)
        #expect(ChatSelectableText.fittingSize(view, width: 300, fitsContent: false).width == 300)
        view.attributedText = ChatSelectableContent.render([], plainText: "")
        #expect(ChatSelectableText.fittingSize(view, width: 300, fitsContent: true).width == 1)
    }

    @Test func `native text wraps within a narrow viewport and grows vertically`() {
        let view = UITextView()
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = ChatSelectableContent.render([.paragraph(String(
            repeating: "Long paragraph 中文. ",
            count: 30
        ))])
        let narrow = view.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        let wide = view.sizeThatFits(CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        #expect(narrow.width <= 240)
        #expect(narrow.height > wide.height)
    }
}
