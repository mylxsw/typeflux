import AppKit
import Markdown
import SwiftUI

/// A single text storage per message makes selection continuous across Markdown
/// blocks. Unchanged messages never replace their storage during stream updates.
struct AskTranscriptText: NSViewRepresentable {
    var text: String
    var markdown = true
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

        override func mouseDown(with event: NSEvent) {
            dragging = true
            defer {
                dragging = false
                if let pending {
                    self.pending = nil; setContent(pending.0, markdown: pending.1, dark: pending.2)
                }
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
