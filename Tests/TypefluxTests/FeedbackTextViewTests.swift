import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackTextViewTests {
    private func makeView(_ text: String = "") -> FeedbackTextView {
        let view = FeedbackTextView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        view.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: FeedbackRichText.baseAttributes
        ))
        return view
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
    }

    // MARK: - Inline formats

    @Test func `bold italic and strikethrough toggle on a selection`() {
        let view = makeView("hello world")
        let range = NSRange(location: 0, length: 5)
        view.setSelectedRange(range)
        for format in [FeedbackInlineFormat.bold, .italic, .strikethrough] {
            #expect(!view.isInlineFormatApplied(format, in: range))
            view.toggleInline(format)
            #expect(view.isInlineFormatApplied(format, in: range))
            view.toggleInline(format)
            #expect(!view.isInlineFormatApplied(format, in: range))
        }
        // The rest of the line is untouched.
        view.toggleInline(.bold)
        #expect(!view.isInlineFormatApplied(.bold, in: NSRange(location: 6, length: 5)))
        #expect(!view.isInlineFormatApplied(.bold, in: NSRange(location: 0, length: 0)))
    }

    @Test func `inline formats on a cursor change what is typed next`() throws {
        let view = makeView("x")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.toggleInline(.bold)
        #expect(isBold(view.typingAttributes[.font] as? NSFont))
        view.toggleInline(.bold)
        #expect(!isBold(view.typingAttributes[.font] as? NSFont))
        view.toggleInline(.italic)
        let italic = try #require(view.typingAttributes[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        view.toggleInline(.strikethrough)
        #expect(view.typingAttributes[.strikethroughStyle] != nil)
        view.toggleInline(.strikethrough)
        #expect(view.typingAttributes[.strikethroughStyle] == nil)
    }

    @Test func `bold skips attachment blocks inside the selection`() {
        let view = makeView("ab")
        view.insertAttachmentBlock(FeedbackTextAttachment(attachmentID: UUID()))
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.toggleInline(.bold)
        #expect(view.attachmentIDs.count == 1)
    }

    @Test func `links apply and clear on a selection`() {
        let view = makeView("site")
        view.applyLink(URL(string: "https://example.com"))
        #expect(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) == nil, "no selection, no link")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.applyLink(URL(string: "https://example.com"))
        #expect((view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.host == "example.com")
        view.applyLink(nil)
        #expect(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    // MARK: - Code

    @Test func `code is inline on one line and a block across lines`() {
        let view = makeView("one two\nthree")
        view.setSelectedRange(NSRange(location: 4, length: 3))
        view.toggleCode()
        #expect(view.textStorage?.attribute(FeedbackRichText.codeKey, at: 4, effectiveRange: nil) != nil)
        view.toggleCode()
        #expect(view.textStorage?.attribute(FeedbackRichText.codeKey, at: 4, effectiveRange: nil) == nil)

        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.toggleCode()
        #expect(view.currentBlockFormat == .code)
        view.toggleCode()
        #expect(view.currentBlockFormat == nil)
    }

    @Test func `code on a cursor toggles the typing style`() {
        let view = makeView("")
        view.toggleCode()
        #expect(view.typingAttributes[FeedbackRichText.codeKey] != nil)
        view.toggleCode()
        #expect(view.typingAttributes[FeedbackRichText.codeKey] == nil)
    }

    // MARK: - Blocks

    @Test(arguments: [FeedbackBlockFormat.heading, .bulletList, .numberedList, .quote, .code])
    func `blocks toggle on the selected paragraphs`(format: FeedbackBlockFormat) throws {
        let view = makeView("first\nsecond")
        view.setSelectedRange(NSRange(location: 0, length: 12))
        view.toggleBlock(format)
        #expect(view.currentBlockFormat == format)
        let storage = try #require(view.textStorage)
        #expect(FeedbackRichText.blockFormat(of: storage.attributes(at: 8, effectiveRange: nil)) == format)
        view.toggleBlock(format)
        #expect(view.currentBlockFormat == nil)
        let plain = storage.attributes(at: 8, effectiveRange: nil)
        #expect((plain[.font] as? NSFont)?.pointSize == FeedbackRichText.baseFontSize)
    }

    @Test func `a block on an empty line is carried by the typing attributes`() {
        let view = makeView("")
        view.toggleBlock(.numberedList)
        #expect(view.currentBlockFormat == .numberedList)
        view.toggleBlock(.numberedList)
        #expect(view.currentBlockFormat == nil)
    }

    @Test func `return ends an empty list item and a heading`() {
        let view = makeView("")
        #expect(!view.handleNewline(), "plain text keeps the default Return")

        view.toggleBlock(.bulletList)
        #expect(view.handleNewline())
        #expect(view.currentBlockFormat == nil)

        let filled = makeView("item")
        filled.setSelectedRange(NSRange(location: 4, length: 0))
        filled.toggleBlock(.bulletList)
        #expect(!filled.handleNewline(), "a list item with text continues the list")

        let heading = makeView("Title")
        heading.setSelectedRange(NSRange(location: 5, length: 0))
        heading.toggleBlock(.heading)
        #expect(heading.handleNewline())
        #expect(heading.string == "Title\n")
        #expect(FeedbackRichText.blockFormat(of: heading.typingAttributes) == nil)

        let code = makeView("log")
        code.setSelectedRange(NSRange(location: 3, length: 0))
        code.toggleBlock(.code)
        #expect(!code.handleNewline())
    }

    // MARK: - Markdown shortcuts

    @Test(arguments: [("-", FeedbackBlockFormat.bulletList), ("1.", .numberedList), (">", .quote), ("##", .heading)])
    func `a marker followed by a space starts the block`(marker: String, format: FeedbackBlockFormat) {
        let view = makeView(marker + "hello")
        let cursor = NSRange(location: marker.utf16.count, length: 0)
        view.setSelectedRange(cursor)

        #expect(view.applyMarkdownShortcut(replacingRange: cursor, replacement: " "))
        #expect(view.string == "hello")
        #expect(view.currentBlockFormat == format)
        #expect(FeedbackRichText.blockFormat(of: view.typingAttributes) == format)
    }

    @Test func `a marker alone leaves an empty block line`() {
        let view = makeView("-")
        let cursor = NSRange(location: 1, length: 0)
        view.setSelectedRange(cursor)
        #expect(view.applyMarkdownShortcut(replacingRange: cursor, replacement: " "))
        #expect(view.string.isEmpty)
        #expect(view.currentBlockFormat == .bulletList)
    }

    @Test func `other typing is not a shortcut`() {
        let view = makeView("-hello")
        let cursor = NSRange(location: 1, length: 0)
        #expect(!view.applyMarkdownShortcut(replacingRange: cursor, replacement: "x"))
        #expect(!view.applyMarkdownShortcut(replacingRange: NSRange(location: 1, length: 2), replacement: " "))
        #expect(!view.applyMarkdownShortcut(replacingRange: NSRange(location: 0, length: 0), replacement: " "))

        let long = makeView("#####x")
        #expect(!long.applyMarkdownShortcut(replacingRange: NSRange(location: 5, length: 0), replacement: " "))
        let word = makeView("abcx")
        #expect(!word.applyMarkdownShortcut(replacingRange: NSRange(location: 3, length: 0), replacement: " "))

        let already = makeView("-hello")
        already.setSelectedRange(cursor)
        already.toggleBlock(.quote)
        #expect(!already.applyMarkdownShortcut(replacingRange: cursor, replacement: " "), "no shortcut inside a block")
    }

    // MARK: - Attachment blocks

    @Test func `attachment blocks sit on their own line after the current paragraph`() {
        let view = makeView("intro")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let first = UUID()
        view.insertAttachmentBlock(FeedbackTextAttachment(attachmentID: first))
        #expect(view.string.hasPrefix("intro\n\u{FFFC}\n"))
        view.insertText("after", replacementRange: view.selectedRange())
        let second = UUID()
        view.insertAttachmentBlock(FeedbackTextAttachment(attachmentID: second))
        #expect(view.attachmentIDs == [first, second])

        view.refreshAttachment(id: first)
        view.removeAttachmentBlock(id: first)
        #expect(view.attachmentIDs == [second])
        view.removeAttachmentBlock(id: UUID())
        #expect(view.attachmentIDs == [second])
    }

    @Test func `attachments can start the document`() {
        let view = makeView("")
        view.insertAttachmentBlock(FeedbackTextAttachment(attachmentID: UUID()))
        #expect(view.attachmentIDs.count == 1)
        #expect(view.string.hasSuffix("\n"))
    }

    // MARK: - Paste

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("typeflux.feedback.test.\(UUID().uuidString)"))
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func `pasting files and screenshots becomes attachments`() throws {
        let view = makeView("")
        var files: [URL] = []
        var images: [Data] = []
        view.onFiles = { files = $0 }
        view.onImageData = { images.append($0) }

        let filePasteboard = scratchPasteboard()
        let url = URL(fileURLWithPath: "/tmp/feedback-test.log")
        filePasteboard.clearContents()
        filePasteboard.writeObjects([url as NSURL])
        view.paste(from: filePasteboard)
        #expect(files.map(\.lastPathComponent) == ["feedback-test.log"])

        let imagePasteboard = scratchPasteboard()
        imagePasteboard.clearContents()
        try imagePasteboard.setData(pngData(), forType: .png)
        view.paste(from: imagePasteboard)
        #expect(images.count == 1)

        // A screenshot is not taken when the pasteboard also carries text (copied from a web page).
        let mixed = scratchPasteboard()
        mixed.clearContents()
        mixed.setString("caption", forType: .string)
        try mixed.setData(pngData(), forType: .png)
        view.paste(from: mixed)
        #expect(images.count == 1)
        #expect(view.string == "caption")
    }

    @Test func `pasted rich text keeps only the supported formats`() {
        let view = makeView("")
        let source = NSMutableAttributedString(string: "styled", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.red
        ])
        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        let rtf = try? source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])
        pasteboard.setData(rtf, forType: .rtf)

        view.paste(from: pasteboard)

        #expect(view.string == "styled")
        let attributes = view.textStorage?.attributes(at: 0, effectiveRange: nil)
        #expect((attributes?[.font] as? NSFont)?.pointSize == FeedbackRichText.baseFontSize)
        #expect(isBold(attributes?[.font] as? NSFont))
    }

    @Test func `html and an empty pasteboard are handled`() {
        let html = scratchPasteboard()
        html.clearContents()
        html.setData(Data("<b>bold</b> text".utf8), forType: .html)
        #expect(FeedbackTextView.pastedAttributedString(from: html)?.string.contains("bold") == true)

        let empty = scratchPasteboard()
        empty.clearContents()
        #expect(FeedbackTextView.pastedAttributedString(from: empty) == nil)
        #expect(FeedbackTextView.pastedImageData(from: empty) == nil)
        let view = makeView("keep")
        view.paste(from: empty)
        #expect(view.string == "keep")
    }

    // MARK: - Keys and drawing

    private func key(_ character: String, flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
        ))
    }

    @Test func `command shortcuts format and request links`() throws {
        let view = makeView("text")
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        var linkRequests = 0
        view.onLinkRequest = { linkRequests += 1 }
        view.setSelectedRange(NSRange(location: 0, length: 4))

        #expect(try view.performKeyEquivalent(with: key("b", flags: .command, window: window)))
        #expect(view.isInlineFormatApplied(.bold, in: NSRange(location: 0, length: 4)))
        #expect(try view.performKeyEquivalent(with: key("i", flags: .command, window: window)))
        #expect(view.isInlineFormatApplied(.italic, in: NSRange(location: 0, length: 4)))
        #expect(try view.performKeyEquivalent(with: key("k", flags: .command, window: window)))
        #expect(linkRequests == 1)
        #expect(try !view.performKeyEquivalent(with: key("j", flags: .command, window: window)))
        #expect(try !view.performKeyEquivalent(with: key("b", flags: [.command, .shift], window: window)))
        window.close()
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        try renderInWindow(view)
    }

    @Test func `the placeholder shows only while the body is empty`() throws {
        let view = makeView("")
        view.placeholder = "Write here"
        _ = try render(view)
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        _ = try render(view)
        #expect(view.string == "x")
    }

    @Test func `list markers and quote bars are drawn without entering the text`() throws {
        let view = makeView("")
        let storage = try #require(view.textStorage)
        for (text, format) in [
            ("one\n", FeedbackBlockFormat.bulletList), ("two\n", .bulletList), ("a\n", .numberedList),
            ("b\n", .numberedList), ("said\n", .quote), ("plain\n", .heading)
        ] {
            storage.append(NSAttributedString(
                string: text,
                attributes: FeedbackRichText.paragraphAttributes(for: format)
            ))
        }
        let before = view.string
        _ = try render(view)
        #expect(view.string == before)
        let markdown = FeedbackRichText.markdown(from: storage) { _ in nil }
        #expect(markdown == "- one\n- two\n\n1. a\n2. b\n\n> said\n\n## plain")
    }
}

/// A drag of files over the editor, without a real drag session.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? {
        nil
    }

    var draggingSourceOperationMask: NSDragOperation {
        .copy
    }

    var draggingLocation: NSPoint {
        .zero
    }

    var draggedImageLocation: NSPoint {
        .zero
    }

    var draggedImage: NSImage? {
        nil
    }

    var draggingSource: Any? {
        nil
    }

    var draggingSequenceNumber: Int {
        1
    }

    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions,
        for _: NSView?,
        classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackTextViewDropTests {
    private func pasteboard(files: [URL]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("typeflux.feedback.drop.\(UUID().uuidString)"))
        board.clearContents()
        if !files.isEmpty {
            board.writeObjects(files.map { $0 as NSURL })
        } else {
            board.setString("plain text", forType: .string)
        }
        return board
    }

    @Test func `dropping files hands them to the editor`() throws {
        let view = FeedbackTextView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var dropped: [URL] = []
        view.onFiles = { dropped = $0 }
        let info = StubDraggingInfo(pasteboard: pasteboard(files: [URL(fileURLWithPath: "/tmp/a.log")]))

        #expect(view.draggingEntered(info) == .copy)
        #expect(view.isDropTargeted)
        #expect(view.draggingUpdated(info) == .copy)
        _ = try renderInWindow(view)

        #expect(view.performDragOperation(info))
        #expect(!view.isDropTargeted)
        #expect(dropped.map(\.lastPathComponent) == ["a.log"])

        _ = view.draggingEntered(info)
        view.draggingExited(info)
        #expect(!view.isDropTargeted)
    }

    @Test func `dragging plain text keeps the default behaviour`() {
        let view = FeedbackTextView()
        var dropped = false
        view.onFiles = { _ in dropped = true }
        let info = StubDraggingInfo(pasteboard: pasteboard(files: []))

        _ = view.draggingEntered(info)
        #expect(!view.isDropTargeted)
        _ = view.draggingUpdated(info)
        #expect(!dropped)
    }
}

/// Draws `view` into a bitmap of a fixed size, through its own drawing code.
@MainActor
private func renderInWindow(_ view: NSView) throws -> NSBitmapImageRep {
    let size = NSSize(width: 420, height: 320)
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    view.displayIgnoringOpacity(NSRect(origin: .zero, size: size), in: context)
    return rep
}
