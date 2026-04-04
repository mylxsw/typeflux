import XCTest
@testable import Typeflux

final class MarkdownHTMLRendererTests: XCTestCase {

    private let renderer = MarkdownHTMLRenderer()

    // MARK: - Basic elements

    func testPlainParagraph() {
        let html = renderer.render(markdown: "Hello, world!")
        XCTAssertTrue(html.contains("<p>Hello, world!</p>"))
    }

    func testHeadingLevels() {
        for level in 1...6 {
            let md = String(repeating: "#", count: level) + " Heading"
            let html = renderer.render(markdown: md)
            XCTAssertTrue(html.contains("<h\(level)>Heading</h\(level)>"), "h\(level) should render correctly")
        }
    }

    func testEmphasis() {
        let html = renderer.render(markdown: "This is *italic* text")
        XCTAssertTrue(html.contains("<em>italic</em>"))
    }

    func testStrong() {
        let html = renderer.render(markdown: "This is **bold** text")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
    }

    func testStrikethrough() {
        let html = renderer.render(markdown: "This is ~~deleted~~ text")
        XCTAssertTrue(html.contains("<del>deleted</del>"))
    }

    func testInlineCode() {
        let html = renderer.render(markdown: "Use `code` here")
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    func testCodeBlock() {
        let md = """
        ```swift
        let x = 1
        ```
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(html.contains("let x = 1"))
        XCTAssertTrue(html.contains("</code></pre>"))
    }

    func testCodeBlockWithoutLanguage() {
        let md = """
        ```
        plain code
        ```
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("<pre><code>"))
        XCTAssertFalse(html.contains("class="))
    }

    func testBlockQuote() {
        let html = renderer.render(markdown: "> This is a quote")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("This is a quote"))
        XCTAssertTrue(html.contains("</blockquote>"))
    }

    // MARK: - Links and images

    func testLink() {
        let html = renderer.render(markdown: "[click](https://example.com)")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">click</a>"))
    }

    func testImage() {
        let html = renderer.render(markdown: "![alt text](image.png)")
        XCTAssertTrue(html.contains("<img src=\"image.png\""))
        XCTAssertTrue(html.contains("alt=\"alt text\""))
    }

    // MARK: - Lists

    func testUnorderedList() {
        let md = """
        - Item 1
        - Item 2
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>Item 1</li>"))
        XCTAssertTrue(html.contains("<li>Item 2</li>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testOrderedList() {
        let md = """
        1. First
        2. Second
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>First</li>"))
        XCTAssertTrue(html.contains("</ol>"))
    }

    func testOrderedListWithCustomStart() {
        let md = """
        3. Third
        4. Fourth
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("start=\"3\""))
    }

    // MARK: - Breaks

    func testThematicBreak() {
        let html = renderer.render(markdown: "---")
        XCTAssertTrue(html.contains("<hr />"))
    }

    // MARK: - HTML escaping

    func testHTMLEscaping() {
        let html = renderer.render(markdown: "Apples & oranges are great")
        XCTAssertTrue(html.contains("&amp;"), "Ampersand should be escaped: \(html)")
    }

    func testQuoteEscapingInAttributes() {
        let html = renderer.render(markdown: "[link](https://example.com?q=\"test\")")
        XCTAssertTrue(html.contains("&quot;"), "Quotes should be escaped in attributes: \(html)")
    }

    func testAngleBracketEscaping() {
        let html = renderer.render(markdown: "Use `<div>` element")
        XCTAssertTrue(html.contains("&lt;div&gt;"))
    }

    func testCodeBlockHTMLEscaping() {
        let md = """
        ```
        <div class="test">&</div>
        ```
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("&lt;div"))
        XCTAssertTrue(html.contains("&amp;"))
    }

    func testLinkURLEscaping() {
        let html = renderer.render(markdown: "[test](https://example.com?a=1&b=2)")
        XCTAssertTrue(html.contains("a=1&amp;b=2"))
    }

    // MARK: - Nested elements

    func testBoldInsideListItem() {
        let md = """
        - **bold** item
        """
        let html = renderer.render(markdown: md)
        XCTAssertTrue(html.contains("<li><strong>bold</strong> item</li>"))
    }

    func testEmphasisInsideLink() {
        let html = renderer.render(markdown: "[*emphasis*](url)")
        XCTAssertTrue(html.contains("<a href=\"url\"><em>emphasis</em></a>"))
    }

    // MARK: - Inline HTML

    func testInlineHTMLPassthrough() {
        let html = renderer.render(markdown: "Hello <br> world")
        XCTAssertTrue(html.contains("<br>"))
    }

    // MARK: - Empty input

    func testEmptyMarkdown() {
        let html = renderer.render(markdown: "")
        XCTAssertTrue(html.isEmpty)
    }
}
