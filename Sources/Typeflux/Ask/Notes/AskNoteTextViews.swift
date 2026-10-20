import AppKit
import SwiftUI

/// A request to scroll the reader to a heading; a new token repeats the same jump.
struct AskNoteJump: Equatable {
    var heading: Int
    var token = UUID()
}

private struct AskNoteReaderContent: Equatable {
    var text: String
    var highlight: String
    var dark: Bool
}

/// A note's Markdown, rendered like the conversation transcript. Task boxes can be
/// ticked, search words are marked, and the outline scrolls to headings.
struct AskNoteReaderText: NSViewRepresentable {
    var text: String
    var highlight = ""
    var jump: AskNoteJump?
    var onToggleTask: ((Int) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    static let taskScheme = "typeflux-task"

    func makeNSView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.textContainer?.replaceLayoutManager(AskRoundedBackgroundLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = view
        return view
    }

    func updateNSView(_ view: ReaderView, context _: Context) {
        view.onToggleTask = onToggleTask
        view.setContent(text, highlight: highlight, dark: colorScheme == .dark)
        if let jump, jump != view.lastJump {
            view.lastJump = jump
            DispatchQueue.main.async { view.scroll(toHeading: jump.heading) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderView, context _: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    /// The rendered text with task boxes as links and search words marked.
    static func attributed(_ markdown: String, highlight: String) -> NSAttributedString {
        let tasks = AskNoteTasks.taskLines(markdown)
        // The shared renderer only accepts web/mail links. A per-render temporary
        // URL marks our boxes without widening that security boundary.
        let taskLinkPrefix = "https://typeflux-task.invalid/\(UUID().uuidString)/"
        var lines = markdown.components(separatedBy: "\n")
        for (index, task) in tasks.enumerated() {
            let box = task.done ? "☑\u{FE0E}" : "☐\u{FE0E}"
            let marker = task.done ? "[x]" : "[ ]"
            if let range = lines[task.line].range(of: marker, options: .caseInsensitive) {
                lines[task.line].replaceSubrange(range, with: "[\(box)](\(taskLinkPrefix)\(index))")
            }
        }
        let rendered = NSMutableAttributedString(
            attributedString: AskMarkdownText.render(lines.joined(separator: "\n"))
        )
        let string = rendered.string as NSString
        // Only boxes originating from Markdown tasks are interactive. Literal glyphs
        // and examples inside fenced code must never shift the task indices.
        var boxes: [(NSRange, Int)] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)),
                  url.absoluteString.hasPrefix(taskLinkPrefix), let index = Int(url.lastPathComponent),
                  tasks.indices.contains(index) else { return }
            boxes.append((range, index))
        }
        for (range, index) in boxes {
            rendered.addAttribute(.link, value: URL(string: "\(taskScheme)://\(index)")!, range: range)
            let done = tasks[index].done
            rendered.addAttribute(.foregroundColor,
                                  value: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor, range: range)
            if done {
                let line = string.lineRange(for: range)
                let text = NSRange(location: NSMaxRange(range), length: NSMaxRange(line) - NSMaxRange(range))
                rendered.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: text)
                rendered.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: text)
            }
        }
        for word in highlight.split(whereSeparator: \.isWhitespace) where !word.hasPrefix("#") {
            var search = NSRange(location: 0, length: string.length)
            while true {
                let match = string.range(of: String(word), options: [.caseInsensitive], range: search)
                guard match.location != NSNotFound else { break }
                rendered.addAttribute(.backgroundColor,
                                      value: NSColor.systemYellow.withAlphaComponent(0.35), range: match)
                search = NSRange(location: NSMaxRange(match), length: string.length - NSMaxRange(match))
            }
        }
        return rendered
    }

    /// Where each heading starts in the rendered text, in order.
    static func headingRanges(_ rendered: String, headings: [AskNoteHeading]) -> [NSRange] {
        let string = rendered as NSString
        var location = 0
        var result: [NSRange] = []
        for heading in headings {
            let plain = AskNote.plainText(heading.text)
            let found = string.range(of: plain, range: NSRange(location: location, length: string.length - location))
            result.append(found)
            if found.location != NSNotFound { location = NSMaxRange(found) }
        }
        return result
    }

    final class ReaderView: NSTextView, NSTextViewDelegate {
        private var source: AskNoteReaderContent?
        var onToggleTask: ((Int) -> Void)?
        var lastJump: AskNoteJump?
        private var markdown = ""

        func setContent(_ text: String, highlight: String, dark: Bool) {
            let content = AskNoteReaderContent(text: text, highlight: highlight, dark: dark)
            guard source != content else { return }
            source = content
            markdown = text
            textStorage?.setAttributedString(AskNoteReaderText.attributed(text, highlight: highlight))
            invalidateIntrinsicContentSize()
        }

        func scroll(toHeading index: Int) {
            let ranges = AskNoteReaderText.headingRanges(string, headings: AskNoteHeading.parse(markdown))
            guard ranges.indices.contains(index), ranges[index].location != NSNotFound,
                  let layout = layoutManager, let container = textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: ranges[index], actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textContainerOrigin.y
            if let scroll = enclosingScrollView, let document = scroll.documentView {
                let target = convert(rect, to: document)
                let originY = document.isFlipped
                    ? target.minY - 16 : target.maxY + 16 - scroll.contentView.bounds.height
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, originY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                scrollToVisible(rect)
            }
        }

        func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if url.scheme == AskNoteReaderText.taskScheme, let index = Int(url.host ?? "") {
                onToggleTask?(index)
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }

        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Hands the editor's text view to the formatting toolbar.
@MainActor
final class AskMarkdownEditorController: ObservableObject {
    weak var textView: NSTextView?

    func apply(_ format: AskMarkdownFormat) {
        guard let view = textView else { return }
        let edit = format.edit(view.string, selection: view.selectedRange())
        Self.perform(edit, in: view)
        view.window?.makeFirstResponder(view)
    }

    /// Replaces text through the text view so the change can be undone.
    static func perform(_ edit: AskMarkdownFormat.Edit, in view: NSTextView) {
        guard view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        view.didChangeText()
        view.setSelectedRange(edit.selection)
        view.scrollRangeToVisible(edit.selection)
    }
}

/// The Markdown source of a note, highlighted as it is typed. Return continues lists,
/// Tab indents them, and ⌘B, ⌘I, ⌘K, ⌘1–3, ⇧⌘L and ⇧⌘X format the selection.
struct AskMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var controller: AskMarkdownEditorController
    var focusOnAppear = true
    /// The editor sizes to its text and lets the surrounding view scroll.
    var growsWithText = false

    static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = EditorView()
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.font = Self.font
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        view.string = text
        view.delegate = context.coordinator
        view.setAccessibilityIdentifier("ask.notes.editor")
        Self.highlight(view)
        controller.textView = view
        let scroll = TFOverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = !growsWithText
        scroll.autohidesScrollers = true
        scroll.documentView = view
        if focusOnAppear {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        controller.textView = view
        context.coordinator.text = $text
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.undoManager?.removeAllActions()
            Self.highlight(view)
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context _: Context) -> CGSize? {
        guard growsWithText, let width = proposal.width, width > 0,
              let view = nsView.documentView as? NSTextView, let container = view.textContainer,
              let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(240, ceil(layout.usedRect(for: container).height) + 40))
    }

    @MainActor
    static func highlight(_ view: NSTextView) {
        // Restyling while an input method composes (Chinese, Japanese) would break the composition.
        guard let storage = view.textStorage, !view.hasMarkedText() else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: view.defaultParagraphStyle ?? NSParagraphStyle.default], range: all)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for span in AskMarkdownHighlighter.spans(storage.string) where NSMaxRange(span.range) <= storage.length {
            switch span.kind {
            case .marker: storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .heading, .strong: storage.addAttribute(.font, value: bold, range: span.range)
            case .emphasis: storage.addAttribute(.font, value: italic, range: span.range)
            case .code:
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: span.range)
            case .fence: storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: span.range)
            case .link: storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: span.range)
            case .quote: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { AskMarkdownEditor.highlight(view) }
            text.wrappedValue = view.string
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            let edit: AskMarkdownFormat.Edit?
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard view.selectedRange().length == 0 else { return false }
                edit = AskMarkdownFormat.newline(view.string, at: view.selectedRange().location)
            case #selector(NSResponder.insertTab(_:)):
                edit = AskMarkdownFormat.indent(view.string, selection: view.selectedRange(), outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                edit = AskMarkdownFormat.indent(view.string, selection: view.selectedRange(), outdent: true)
            default:
                return false
            }
            guard let edit else { return false }
            MainActor.assumeIsolated { AskMarkdownEditorController.perform(edit, in: view) }
            return true
        }
    }

    final class EditorView: NSTextView {
        /// The formatting keys, matched on the characters typed with ⌘ (and ⇧).
        static func format(for characters: String, shift: Bool) -> AskMarkdownFormat? {
            switch (characters.lowercased(), shift) {
            case ("b", false): .bold
            case ("i", false): .italic
            case ("k", false): .link
            case ("1", false): .heading1
            case ("2", false): .heading2
            case ("3", false): .heading3
            case ("l", true): .taskList
            case ("x", true): .strikethrough
            default: nil
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard window?.firstResponder === self, flags.contains(.command), !flags.contains(.option),
                  !flags.contains(.control), let characters = event.charactersIgnoringModifiers,
                  let format = Self.format(for: characters, shift: flags.contains(.shift))
            else { return super.performKeyEquivalent(with: event) }
            AskMarkdownEditorController.perform(format.edit(string, selection: selectedRange()), in: self)
            return true
        }
    }
}
