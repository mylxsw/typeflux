import AppKit
import Markdown
import SwiftUI

/// A single text storage per message makes selection continuous across Markdown
/// blocks. Unchanged messages never replace their storage during stream updates.
struct AskTranscriptText: NSViewRepresentable {
    var text: String
    var markdown = true
    var onAsk: ((String, String) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context _: Context) -> Editor {
        let editor = Editor()
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return editor
    }

    func updateNSView(_ editor: Editor, context _: Context) {
        editor.onAsk = onAsk
        editor.setContent(text, markdown: markdown, dark: colorScheme == .dark)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Editor, context _: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Editor: NSTextView {
        private var source: String?
        private var dark = false
        private var usesMarkdown = true
        private var dragging = false
        private var pending: (String, Bool, Bool)?
        var onAsk: ((String, String) -> Void)? {
            didSet { if onAsk == nil { askPopover.close() } }
        }
        let askPopover = NSPopover()

        var selectedExcerpt: String? {
            let range = selectedRange()
            guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return nil }
            let excerpt = (string as NSString).substring(with: range)
            return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
        }

        func showSelectionAction() {
            askPopover.close()
            guard onAsk != nil, let excerpt = selectedExcerpt, window != nil,
                  let layout = layoutManager, let container = textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
            var anchor = layout.boundingRect(forGlyphRange: glyphs, in: container)
            anchor.origin.x += textContainerOrigin.x
            anchor.origin.y += textContainerOrigin.y
            // A long drag may scroll the start of the selection out of view.
            // Anchor to the visible part instead of silently losing the action.
            anchor = anchor.intersection(visibleRect)
            guard !anchor.isNull, !anchor.isEmpty else { return }
            anchor.size.height = min(anchor.height, 18)
            askPopover.behavior = .transient
            askPopover.animates = false
            askPopover.contentViewController = NSHostingController(rootView:
                AskSelectionActionBar { [weak self] action in self?.perform(action, excerpt: excerpt) }
                    .onCopyCommand { [NSItemProvider(object: excerpt as NSString)] }
            )
            askPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        }

        /// Selecting text used to cost four steps: select, press Ask, fill in an
        /// optional question in a modal, then find the excerpt back in the
        /// composer. Each action here finishes in one click, and the modal is gone.
        func perform(_ action: AskSelectionAction, excerpt: String) {
            switch action {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt, forType: .string)
            default:
                onAsk?(excerpt, action.question)
            }
            askPopover.close()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { askPopover.close() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func keyUp(with event: NSEvent) {
            super.keyUp(with: event)
            if event.modifierFlags.contains(.shift) { showSelectionAction() }
        }

        override func mouseDown(with event: NSEvent) {
            askPopover.close()
            dragging = true
            defer {
                dragging = false
                if let pending {
                    self.pending = nil; setContent(pending.0, markdown: pending.1, dark: pending.2)
                }
                showSelectionAction()
            }
            super.mouseDown(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }

        func setContent(_ text: String, markdown: Bool, dark: Bool) {
            guard source != text || self.dark != dark || usesMarkdown != markdown else { return }
            if dragging {
                pending = (text, markdown, dark); return
            }
            let oldSelection = selectedRange()
            let oldString = string as NSString
            source = text; self.dark = dark; usesMarkdown = markdown
            let rendered = AskMarkdownText.render(text, markdown: markdown)
            textStorage?.setAttributedString(rendered)
            // Preserve a selection only if the selected prefix is still identical.
            if NSMaxRange(oldSelection) <= oldString.length, NSMaxRange(oldSelection) <= rendered.length,
               oldString.substring(to: NSMaxRange(oldSelection)) == (rendered.string as NSString)
               .substring(to: NSMaxRange(oldSelection)) {
                setSelectedRange(oldSelection)
            }
            invalidateIntrinsicContentSize()
        }
    }
}

enum AskMarkdownText {
    static func render(_ text: String, markdown: Bool = true) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 7
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        guard markdown else { return NSAttributedString(string: text, attributes: base) }
        let result = NSMutableAttributedString()
        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        func visit(_ node: any Markup, _ inherited: [NSAttributedString.Key: Any]) {
            var attributes = inherited
            if let text = node as? Markdown.Text {
                append(text.string, attributes); return
            }
            if let code = node as? InlineCode {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                append(code.code, attributes); return
            }
            if let code = node as? CodeBlock {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                append(code.code + (code.code.hasSuffix("\n") ? "" : "\n"), attributes); return
            }
            if let heading = node as? Heading {
                attributes[.font] = NSFont.systemFont(
                    ofSize: CGFloat(max(14, 23 - heading.level * 2)),
                    weight: .semibold
                )
            }
            if node is BlockQuote {
                let quoted = paragraph.mutableCopy() as! NSMutableParagraphStyle
                quoted.headIndent = 12; quoted.firstLineHeadIndent = 12
                attributes[.paragraphStyle] = quoted
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if node is Strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if node is Markdown.Table.Row || node is Markdown.Table.Head {
                if node is Markdown.Table.Head {
                    attributes[.font] = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
                }
                for (index, cell) in node.children.enumerated() {
                    if index > 0 {
                        append("  |  ", attributes)
                    }
                    visit(cell, attributes)
                }
                append("\n", attributes)
                return
            }
            if node is Strong {
                attributes[.font] = NSFontManager.shared.convert(
                    attributes[.font] as! NSFont,
                    toHaveTrait: .boldFontMask
                )
            }
            if node is Emphasis {
                attributes[.font] = NSFontManager.shared.convert(
                    attributes[.font] as! NSFont,
                    toHaveTrait: .italicFontMask
                )
            }
            if let link = node as? Markdown.Link, let destination = link.destination,
               let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme ?? "") {
                attributes[.link] = url
            }
            if node is SoftBreak {
                append(" ", attributes); return
            }
            if node is LineBreak {
                append("\n", attributes); return
            }
            if node is ThematicBreak {
                append("────────────\n", attributes); return
            }
            if let list = node as? OrderedList {
                for (index, child) in list.children.enumerated() {
                    append(
                        "\(Int(list.startIndex) + index). ",
                        attributes
                    ); visit(child, attributes)
                }
                return
            }
            if let list = node as? UnorderedList {
                for child in list.children {
                    append("• ", attributes); visit(child, attributes)
                }
                return
            }
            for child in node.children {
                visit(child, attributes)
            }
            if node is Paragraph || node is Heading {
                append("\n", attributes)
            }
        }
        visit(Document(parsing: text), base)
        if result.string
            .hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }
}
