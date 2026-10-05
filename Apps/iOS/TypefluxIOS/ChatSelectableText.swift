import SwiftUI
import UIKit

/// A single text storage lets the system selection handles cross paragraph boundaries.
struct ChatSelectableText: UIViewRepresentable {
    let blocks: [ChatMarkdown.Block]
    var plainText: String?
    var foreground: UIColor = .label
    var scrolls = false
    @Environment(\.sizeCategory) private var sizeCategory

    func makeUIView(context _: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context _: Context) {
        view.isScrollEnabled = scrolls
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory))
        let text = ChatSelectableContent.render(blocks, plainText: plainText, foreground: foreground, traits: traits)
        Self.update(view, text: text)
    }

    static func update(_ view: UITextView, text: NSAttributedString) {
        // SwiftUI updates unrelated state frequently; assigning identical text destroys selection.
        guard !view.attributedText.isEqual(to: text) else { return }
        let selection = view.selectedRange
        let offset = view.contentOffset
        view.attributedText = text
        if selection.location != NSNotFound, NSMaxRange(selection) <= text.length {
            view.selectedRange = selection
        }
        view.setContentOffset(offset, animated: false)
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
        guard !scrolls, let width = proposal.width, width > 0 else { return nil }
        return Self.fittingSize(uiView, width: width, fitsContent: plainText != nil)
    }

    static func fittingSize(_ view: UITextView, width: CGFloat, fitsContent: Bool) -> CGSize {
        // Short user messages should keep a compact bubble instead of filling the transcript.
        let textWidth = ceil(view.attributedText.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).width)
        let fittedWidth = fitsContent ? min(width, max(1, textWidth)) : width
        return CGSize(width: fittedWidth, height: ceil(view.sizeThatFits(
            CGSize(width: fittedWidth, height: .greatestFiniteMagnitude)
        ).height))
    }
}

enum ChatSelectableContent {
    /// Keep complex blocks in their original scrollable cards during normal reading.
    static func groups(_ blocks: [ChatMarkdown.Block]) -> [[ChatMarkdown.Block]] {
        var result: [[ChatMarkdown.Block]] = []
        var prose: [ChatMarkdown.Block] = []
        for block in blocks {
            switch block {
            case .code, .table:
                if !prose.isEmpty {
                    result.append(prose); prose = []
                }
                result.append([block])
            default: prose.append(block)
            }
        }
        if !prose.isEmpty {
            result.append(prose)
        }
        return result
    }

    static func render(_ blocks: [ChatMarkdown.Block], plainText: String? = nil,
                       foreground: UIColor = .label, traits: UITraitCollection = .current) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16), compatibleWith: traits)
        if let plainText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            return NSAttributedString(string: plainText, attributes: [
                .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
            ])
        }
        let result = NSMutableAttributedString(string: "")
        for block in blocks {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            }
            result.append(render(block, font: font, foreground: foreground, traits: traits))
        }
        return result
    }

    private static func render(_ block: ChatMarkdown.Block, font: UIFont,
                               foreground: UIColor, traits: UITraitCollection) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        var blockFont = font
        var color = foreground
        var source: String
        var literal = false
        switch block {
        case let .paragraph(text): source = text
        case let .heading(level, text):
            source = text
            blockFont = UIFontMetrics(forTextStyle: .headline).scaledFont(
                for: .systemFont(ofSize: level == 1 ? 20 : level == 2 ? 18 : 17, weight: .semibold),
                compatibleWith: traits
            )
        case let .listItem(marker, text, depth):
            source = marker + "  " + text
            paragraph.firstLineHeadIndent = CGFloat(depth) * 14
            paragraph.headIndent = paragraph.firstLineHeadIndent + 24
        case let .quote(text):
            source = text
            paragraph.firstLineHeadIndent = 14
            paragraph.headIndent = 14
            color = .secondaryLabel
        case let .code(_, text):
            source = text
            literal = true
            blockFont = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedSystemFont(ofSize: 14, weight: .regular), compatibleWith: traits
            )
        case let .table(headers, rows):
            // Plain row separators keep every cell selectable in the full-message sheet.
            source = ([headers] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .divider: source = "────────"; literal = true
        }
        let text = literal ? NSMutableAttributedString(string: source) : inline(source, font: blockFont)
        let range = NSRange(location: 0, length: text.length)
        text.addAttributes([.paragraphStyle: paragraph, .foregroundColor: color], range: range)
        if literal {
            text.addAttribute(.font, value: blockFont, range: range)
        }
        return text
    }

    private static func inline(_ source: String, font: UIFont) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let intent = run.inlinePresentationIntent ?? []
            var symbolic = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) {
                symbolic.insert(.traitBold)
            }
            if intent.contains(.emphasized) {
                symbolic.insert(.traitItalic)
            }
            if intent.contains(.code) {
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attributes[.backgroundColor] = UIColor.secondarySystemFill
            } else if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
                attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

struct ChatTextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatSelectableText(blocks: ChatMarkdown.parse(text), scrolls: true)
                .accessibilityIdentifier("chat.selection.text")
                .padding(20)
                .background(ChatTheme.background)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("chat.selection.done")
                    }
                }
        }
    }
}
