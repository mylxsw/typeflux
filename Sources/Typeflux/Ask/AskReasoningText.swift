import AppKit
import SwiftUI

/// Reasoning is untrusted, frequently changing plain text. Keep it in a bounded
/// native viewport instead of parsing Markdown and measuring the entire stream
/// inside the transcript's layout pass.
struct AskReasoningText: NSViewRepresentable {
    let text: String
    var monospaced = false
    var isError = false
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context _: Context) -> NSScrollView {
        Self.makeScrollView()
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = Editor(frame: scroll.contentView.bounds)
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .secondaryLabelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if let editor = scroll.documentView as? Editor {
            editor.setContent(text, monospaced: monospaced, isError: isError)
        }
    }

    final class Editor: NSTextView {
        private var source = ""

        private var code = false
        private var error = false

        func setContent(_ text: String, monospaced: Bool = false, isError: Bool = false) {
            let restyle = code != monospaced || error != isError
            guard source != text || restyle, let storage = textStorage else { return }
            code = monospaced
            error = isError
            let selection = selectedRange()
            // NSTextStorage string edits do not inherit NSTextView's textColor
            // when storage is empty. Style every inserted run explicitly.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: monospaced ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: isError ? NSColor.systemRed : NSColor.secondaryLabelColor
            ]
            // Providers normally append. Do not replace the existing storage or
            // invalidate its laid-out prefix for every token.
            if !restyle, text.hasPrefix(source) {
                let offset = source.utf16.count
                storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                          with: NSAttributedString(string: (text as NSString).substring(from: offset),
                                                                   attributes: attributes))
            } else {
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                          with: NSAttributedString(string: text, attributes: attributes))
            }
            source = text
            if NSMaxRange(selection) <= storage.length { setSelectedRange(selection) }
        }
    }
}
