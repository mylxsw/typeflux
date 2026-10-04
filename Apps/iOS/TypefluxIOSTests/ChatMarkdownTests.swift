import Testing
@testable import TypefluxIOS

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
