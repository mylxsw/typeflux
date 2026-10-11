import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Notebook Markdown helpers")
struct AskNotebookMarkdownTests {
    static let doc = """
    # Title
    intro
    ```
    # not a heading
    - [ ] not a task
    ```
    ## Steps
    - [x] done
    - [ ] todo
    ### Detail
    text
    ## End
    last
    """

    @Test func headingsSkipCodeAndKnowTheirLines() {
        let headings = AskNoteHeading.parse(Self.doc)
        #expect(headings.map(\.text) == ["Title", "Steps", "Detail", "End"])
        #expect(headings.map(\.level) == [1, 2, 3, 2] && headings[1].line == 6 && headings[1].id == 6)
        #expect(AskNoteHeading.heading("#nospace") == nil && AskNoteHeading.heading("#### deep") == nil)
        #expect(AskNoteHeading.heading("## ") == nil)
    }

    @Test func matchingFencesKeepCodeOutOfTasksHeadingsAndHighlights() throws {
        let markdown = """
        ````markdown
        ```swift
        # nested code
        - [ ] nested task
        ```
        - [ ] still code
        ````
        ~~~text
        ## tilde code
        - [ ] another code task
        ~~~
        ## Actual
        - [ ] real task
        """
        #expect(AskNoteHeading.parse(markdown).map(\.text) == ["Actual"])
        #expect(AskNoteTasks.taskLines(markdown).map(\.text) == ["real task"])
        let changed = try #require(AskNoteTasks.toggling(markdown, task: 0))
        #expect(changed == markdown.replacingOccurrences(of: "- [ ] real task", with: "- [x] real task"))
        let spans = AskMarkdownHighlighter.spans(markdown)
        let nested = (markdown as NSString).range(of: "# nested code")
        #expect(spans.contains { $0.range == nested && $0.kind == .code })
        #expect(spans.filter { $0.kind == .fence }.count == 4)
        #expect(AskNote.plainText(markdown).contains("# nested code"))
        #expect(AskNoteHeading.parse("    # indented code\n\t## also code\n# Heading").map(\.text) == ["Heading"])
    }

    @Test func sectionsAndAppending() {
        #expect(AskNoteHeading.section(Self.doc, heading: "steps") == "## Steps\n- [x] done\n- [ ] todo\n### Detail\ntext")
        #expect(AskNoteHeading.section(Self.doc, heading: "## End") == "## End\nlast")
        #expect(AskNoteHeading.section(Self.doc, heading: "Missing") == nil)
        let appended = AskNoteHeading.appending("- [ ] new", to: Self.doc, under: "Steps")
        #expect(appended.contains("text\n\n- [ ] new\n\n## End"))
        #expect(AskNoteHeading.appending("tail", to: "body\n\n", under: nil) == "body\n\ntail")
        #expect(AskNoteHeading.appending("tail", to: "", under: "x") == "tail")
        #expect(AskNoteHeading.appending("  ", to: "body", under: nil) == "body")
        let atEnd = AskNoteHeading.appending("more", to: "## Last\nline\n\n", under: "Last")
        #expect(atEnd == "## Last\nline\n\nmore\n\n")
        #expect(AskNoteHeading.appending("    code", to: "    old code\n", under: nil) == "    old code\n\n    code")
    }

    @Test func tasksToggleOneBoxAndDisplayAsGlyphs() throws {
        let tasks = AskNoteTasks.taskLines(Self.doc)
        #expect(tasks.map(\.done) == [true, false] && tasks.map(\.text) == ["done", "todo"])
        let toggled = try #require(AskNoteTasks.toggling(Self.doc, task: 1))
        #expect(AskNoteTasks.taskLines(toggled).map(\.done) == [true, true])
        #expect(toggled.contains("- [ ] not a task"), "code blocks are left alone")
        let back = try #require(AskNoteTasks.toggling(toggled, task: 0))
        #expect(AskNoteTasks.taskLines(back).map(\.done) == [false, true])
        #expect(AskNoteTasks.toggling(Self.doc, task: 5) == nil)
        #expect(AskNoteTasks.toggling("* [X] Upper", task: 0) == "* [ ] Upper")
        let display = AskNoteTasks.displayText("- [x] a\n- [ ] b\n```\n- [ ] c\n```")
        #expect(display.hasPrefix("- ☑\u{FE0E} a\n- ☐\u{FE0E} b") && display.contains("- [ ] c"))
        let note = AskNote(title: "t", body: Self.doc, command: "", keyword: "", input: "", createdAt: .now, updatedAt: .now)
        #expect(note.taskProgress == (1, 2) && note.headings.count == 4 && note.characterCount > 10)
    }

    @Test func frontMatterParses() {
        let text = "\u{FEFF}---\r\ntitle: \"A \\\"quoted\\\" title\"\r\ntags: [x, \"y z\"]\r\ncreated: 2026-10-01T08:00:00Z\r\nbad line\r\n---\r\n\r\nBody"
        let (fields, body) = AskNoteFrontMatter.split(text)
        #expect(body == "Body" && fields["bad line"] == nil)
        #expect(AskNoteFrontMatter.scalar(fields["title"] ?? "") == "A \"quoted\" title")
        #expect(AskNoteFrontMatter.list(fields["tags"] ?? "") == ["x", "y z"])
        #expect(AskNoteFrontMatter.date(fields["created"] ?? "") == Date(timeIntervalSince1970: 1_790_841_600))
        #expect(AskNoteFrontMatter.date("2026-10-01") != nil && AskNoteFrontMatter.date("soon") == nil)
        #expect(AskNoteFrontMatter.scalar("'it''s'") == "it's" && AskNoteFrontMatter.list("a, b") == ["a", "b"])
        #expect(AskNoteFrontMatter.split("no front matter").fields.isEmpty)
        #expect(AskNoteFrontMatter.split("---\nunterminated").body == "---\nunterminated")
    }

    @Test func frontMatterKeepsMarkdownRulesAndParsesQuotedLists() {
        let rules = "---\nA paragraph between rules\n---\n    indented code  "
        #expect(AskNoteFrontMatter.split(rules).body == rules)
        #expect(AskNoteFrontMatter.split("\u{FEFF}# Heading").body == "# Heading")
        #expect(AskNoteFrontMatter.list("[plain, \"a,b\", 'it''s, fine', user's tag]")
            == ["plain", "a,b", "it's, fine", "user's tag"])
        #expect(AskNoteFrontMatter.list("[\"quote\\\",comma\", \"back\\\\slash\"]") == ["quote\",comma", "back\\slash"])
        #expect(AskNoteFrontMatter.date("2026-10-01T08:00:00.125Z") == Date(timeIntervalSince1970: 1_790_841_600.125))
    }
}

@Suite("Notebook editor commands")
struct AskMarkdownFormatTests {
    private func apply(_ format: AskMarkdownFormat, _ text: String, _ location: Int, _ length: Int = 0) -> (String, NSRange) {
        let edit = format.edit(text, selection: NSRange(location: location, length: length))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, edit.selection)
    }

    @Test func wrapsAndUnwrapsInlineMarkers() {
        #expect(apply(.bold, "a word b", 2, 4).0 == "a **word** b")
        #expect(apply(.bold, "a **word** b", 2, 8).0 == "a word b")
        #expect(apply(.bold, "a **word** b", 4, 4) == ("a word b", NSRange(location: 2, length: 4)))
        #expect(apply(.italic, "x", 0, 1).0 == "*x*" && apply(.strikethrough, "x", 0, 1).0 == "~~x~~")
        #expect(apply(.code, "", 0) == ("``", NSRange(location: 1, length: 0)))
        #expect(apply(.bold, "abc", 10, 5).0 == "abc****", "an out-of-range selection is clamped")
    }

    @Test func prefixesLinesAndLinks() {
        #expect(apply(.heading2, "# Title", 3).0 == "## Title")
        #expect(apply(.heading2, "## Title", 0).0 == "Title", "the same heading again removes it")
        #expect(apply(.bulletList, "a\nb\n", 0, 3).0 == "- a\n- b\n")
        #expect(apply(.taskList, "- a", 0).0 == "- [ ] a")
        #expect(apply(.quote, "q", 0) == ("> q", NSRange(location: 3, length: 0)))
        #expect(apply(.heading1, "x\ny", 0, 3).1 == NSRange(location: 0, length: 7))
        let link = apply(.link, "see docs", 4, 4)
        #expect(link.0 == "see [docs](https://)" && link.1 == NSRange(location: 11, length: 8))
        #expect(apply(.link, "", 0) == ("[](https://)", NSRange(location: 1, length: 0)))
        #expect(apply(.table, "x", 1).0 == "x\n| | |\n|---|---|\n| | |\n")
        #expect(apply(.table, "", 0).1 == NSRange(location: 2, length: 0))
        #expect(AskMarkdownFormat.allCases.count == 12)
    }

    @Test func returnContinuesAndEndsLists() throws {
        let bullet = try #require(AskMarkdownFormat.newline("- one", at: 5))
        #expect(bullet.replacement == "\n- " && bullet.selection.location == 8)
        #expect(AskMarkdownFormat.newline("  9. nine", at: 9)?.replacement == "\n  10. ")
        #expect(AskMarkdownFormat.newline("- [x] done", at: 10)?.replacement == "\n- [ ] ")
        #expect(AskMarkdownFormat.newline("> quote", at: 7)?.replacement == "\n> ")
        let end = try #require(AskMarkdownFormat.newline("a\n- ", at: 4))
        #expect(end.range == NSRange(location: 2, length: 2) && end.replacement.isEmpty)
        #expect(AskMarkdownFormat.newline("plain", at: 5) == nil && AskMarkdownFormat.newline("x", at: 9) == nil)
    }

    @Test func tabIndentsListLines() throws {
        let indent = try #require(AskMarkdownFormat.indent("- a\n- b", selection: NSRange(location: 2, length: 0), outdent: false))
        #expect(indent.replacement == "  - a\n" && indent.selection.location == 4)
        let outdent = try #require(AskMarkdownFormat.indent("    - a\n", selection: NSRange(location: 6, length: 0), outdent: true))
        #expect(outdent.replacement == "  - a\n" && outdent.selection.location == 4)
        #expect(AskMarkdownFormat.indent("text", selection: NSRange(location: 0, length: 0), outdent: false) == nil)
    }

    @Test func highlighterFindsMarkdownParts() {
        let text = "## Head\n**b** *i* `c` [l](u)\n> q\n- x\n| t |\n```\ncode\n```"
        let spans = AskMarkdownHighlighter.spans(text)
        func kinds(_ fragment: String) -> [AskMarkdownHighlighter.Kind] {
            let range = (text as NSString).range(of: fragment)
            return spans.filter { $0.range == range }.map(\.kind)
        }
        #expect(kinds("Head") == [.heading] && kinds("## ") == [.marker])
        #expect(kinds("b") .contains(.strong) && kinds("i").contains(.emphasis) && kinds("c").contains(.code))
        #expect(kinds("[l](u)") == [.link] && kinds("> q") == [.quote] && kinds("| t |") == [.marker])
        #expect(kinds("code") == [.code] && spans.filter { $0.kind == .fence }.count == 2)
        #expect(spans.contains { $0.kind == .marker && (text as NSString).substring(with: $0.range) == "- " })
    }

    @Test func editorKeysMapToFormats() {
        #expect(AskMarkdownEditor.EditorView.format(for: "B", shift: false) == .bold)
        #expect(AskMarkdownEditor.EditorView.format(for: "l", shift: true) == .taskList)
        #expect(AskMarkdownEditor.EditorView.format(for: "x", shift: true) == .strikethrough)
        #expect(AskMarkdownEditor.EditorView.format(for: "2", shift: false) == .heading2)
        #expect(AskMarkdownEditor.EditorView.format(for: "l", shift: false) == nil)
    }
}
