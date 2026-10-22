import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask reasoning viewport", .serialized, .exclusiveUIState)
@MainActor struct AskReasoningTextTests {
    @Test func `reasoning stays plain selectable and scrollable`() throws {
        let scroll = AskReasoningText.makeScrollView()
        let editor = try #require(scroll.documentView as? AskReasoningText.Editor)
        let text = "# Thinking\n\n| A | B |\n| --- | --- |\n```swift\nlet a = 1\n```"
        editor.setContent(text)
        #expect(editor.string == text)
        #expect(editor.isSelectable && !editor.isEditable && !editor.isRichText)
        #expect(scroll.hasVerticalScroller)
        #expect(editor.layoutManager?.allowsNonContiguousLayout == true)
        #expect(editor.textContainer?.widthTracksTextView == true)
        editor.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: editor.string.utf16.count)) {
            value, _, _ in
            #expect((value as? NSParagraphStyle)?.textBlocks.isEmpty != false)
        }
    }

    @Test func `stream append preserves Unicode selection and storage prefix`() throws {
        let scroll = AskReasoningText.makeScrollView()
        let editor = try #require(scroll.documentView as? AskReasoningText.Editor)
        let first = "正在思考 👨‍👩‍👧‍👦 café\n"
        editor.setContent(first)
        let selection = NSRange(location: 0, length: 4)
        editor.setSelectedRange(selection)
        let storage = try #require(editor.textStorage)
        let marker = NSAttributedString.Key("prefixMarker")
        storage.addAttribute(marker, value: true, range: selection)
        editor.setContent(first + "继续\n")
        #expect(editor.string == first + "继续\n")
        #expect(editor.selectedRange() == selection)
        #expect(storage.attribute(marker, at: 0, effectiveRange: nil) as? Bool == true)
        editor.setContent(first + "继续\n")
        #expect(editor.selectedRange() == selection)
        editor.setContent("Changed")
        #expect(editor.string == "Changed")
        editor.setContent("")
        #expect(editor.string.isEmpty)
        #expect(NSMaxRange(editor.selectedRange()) == 0)
    }

    @Test func `large streamed reasoning fits a bounded viewport at narrow widths`() throws {
        _ = NSApplication.shared
        let scroll = AskReasoningText.makeScrollView()
        let editor = try #require(scroll.documentView as? AskReasoningText.Editor)
        let source = String(repeating: "**Thinking** 中文 👋 | table | ```\n", count: 8000)
        editor.setContent(source)
        for width: CGFloat in [320, 760, 400] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 220)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            #expect(scroll.contentSize.height <= 220)
            #expect(editor.string == source)
        }
        editor.setContent(source + "Finished")
        #expect(editor.string.hasSuffix("Finished"))
    }
}
