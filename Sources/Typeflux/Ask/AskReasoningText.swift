import AppKit
import SwiftUI

/// Reasoning is untrusted, frequently changing plain text. Keep it in a bounded
/// native viewport instead of parsing Markdown and measuring the entire stream
/// inside the transcript's layout pass.
struct AskReasoningText: NSViewRepresentable {
    /// Bound work per streaming update and flatten line breaks for a stable single-line preview.
    static func preview(_ text: String) -> String {
        String(text.prefix(600)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    let text: String
    var monospaced = false
    var isError = false
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context _: Context) -> NSScrollView {
        Self.makeScrollView()
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = Viewport(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView,
                      context _: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let editor = scroll.documentView as? Editor else { return nil }
        return CGSize(width: width, height: editor.viewportHeight(width: width))
    }

    final class Viewport: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            guard let editor = documentView as? Editor,
                  let manager = editor.layoutManager, let container = editor.textContainer,
                  manager.usedRect(for: container).height + editor.textContainerInset.height * 2
                    > contentSize.height + 1 else {
                nextResponder?.scrollWheel(with: event)
                return
            }
            super.scrollWheel(with: event)
        }
    }

    final class Editor: NSTextView {
        private var source = ""

        private var code = false
        private var error = false

        /// Lay out only the visible prefix; very large streamed outputs stay bounded.
        func viewportHeight(width: CGFloat) -> CGFloat {
            guard let container = textContainer, let manager = layoutManager else { return 220 }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            let inset = textContainerInset.height * 2
            manager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: width, height: 220),
                                 in: container)
            let used = manager.usedRect(for: container).maxY
            let trailing = manager.extraLineFragmentTextContainer == container
                ? manager.extraLineFragmentRect.maxY : 0
            return min(220, ceil(max(used, trailing, font?.ascender ?? 13) + inset))
        }

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
