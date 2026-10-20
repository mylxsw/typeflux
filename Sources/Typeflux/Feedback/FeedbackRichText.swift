import AppKit

/// An attachment block in the feedback body; `attachmentID` ties it to a `FeedbackAttachment`.
final class FeedbackTextAttachment: NSTextAttachment {
    let attachmentID: UUID

    init(attachmentID: UUID) {
        self.attachmentID = attachmentID
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Paragraph-level formats the feedback editor supports.
enum FeedbackBlockFormat: String, Equatable {
    case heading, bulletList, numberedList, quote, code
}

/// The restricted rich text model of the feedback body: bold, italic, strikethrough, headings,
/// lists, quotes, code and links. Everything else is dropped when text is pasted, and the body is
/// serialized to Markdown on submit.
enum FeedbackRichText {
    static let blockKey = NSAttributedString.Key("ai.gulu.typeflux.feedback.block")
    static let codeKey = NSAttributedString.Key("ai.gulu.typeflux.feedback.code")

    static let baseFontSize: CGFloat = 13
    static let headingFontSize: CGFloat = 17

    static var baseFont: NSFont {
        .systemFont(ofSize: baseFontSize)
    }

    static var codeFont: NSFont {
        .monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraphStyle]
    }

    static var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        return style
    }

    // MARK: - Block styling

    /// The attributes a paragraph gets for `format`, or the base attributes for nil.
    static func paragraphAttributes(for format: FeedbackBlockFormat?) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        switch format {
        case nil:
            break
        case .heading:
            attributes[.font] = NSFont.systemFont(ofSize: headingFontSize, weight: .semibold)
            attributes[blockKey] = format?.rawValue
        case .bulletList, .numberedList:
            // The marker is drawn by `FeedbackLayoutManager` in the indent.
            style.firstLineHeadIndent = 24
            style.headIndent = 24
            attributes[blockKey] = format?.rawValue
        case .quote:
            style.firstLineHeadIndent = 14
            style.headIndent = 14
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            attributes[blockKey] = format?.rawValue
        case .code:
            attributes[.font] = codeFont
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            style.firstLineHeadIndent = 6
            style.headIndent = 6
            attributes[blockKey] = format?.rawValue
        }
        attributes[.paragraphStyle] = style
        return attributes
    }

    static func blockFormat(of attributes: [NSAttributedString.Key: Any]) -> FeedbackBlockFormat? {
        (attributes[blockKey] as? String).flatMap(FeedbackBlockFormat.init(rawValue:))
    }

    // MARK: - Links

    /// A link target the editor accepts: http or https with a host, scheme added when missing.
    static func normalizedLinkURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // MARK: - Pasted text

    /// Keeps only the formats the editor supports (bold, italic, strikethrough, http(s) links)
    /// and drops fonts, colors, sizes, attachments and everything else.
    static func sanitized(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let text = source.attributedSubstring(from: range).string
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            result.append(NSAttributedString(string: text, attributes: supportedAttributes(from: attributes)))
        }
        return result
    }

    private static func supportedAttributes(
        from attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var kept = baseAttributes
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            var target = baseFont
            if traits.contains(.bold) {
                target = NSFontManager.shared.convert(target, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italic) {
                target = NSFontManager.shared.convert(target, toHaveTrait: .italicFontMask)
            }
            kept[.font] = target
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
            kept[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = linkURL(from: attributes[.link]) {
            kept[.link] = link
        }
        return kept
    }

    private static func linkURL(from value: Any?) -> URL? {
        let text: String? = if let url = value as? URL {
            url.absoluteString
        } else {
            value as? String
        }
        return text.flatMap(normalizedLinkURL)
    }

    // MARK: - Markdown

    /// One non-empty paragraph of the body with its block format.
    private struct MarkdownLine {
        let format: FeedbackBlockFormat?
        let body: String
    }

    /// Serializes the body to Markdown. `attachmentMarkdown` resolves an attachment block to its
    /// Markdown (nil drops it, for attachments that have no uploaded URL).
    static func markdown(
        from text: NSAttributedString,
        attachmentMarkdown: (UUID) -> String?
    ) -> String {
        let nsText = text.string as NSString
        var paragraphs: [NSRange] = []
        let whole = NSRange(location: 0, length: nsText.length)
        nsText.enumerateSubstrings(in: whole, options: .byParagraphs) { _, range, _, _ in
            if range.length > 0 {
                paragraphs.append(range)
            }
        }
        var lines: [MarkdownLine] = []
        for range in paragraphs {
            let format = blockFormat(of: text.attributes(at: range.location, effectiveRange: nil))
            let body = inlineMarkdown(text, range: range, format: format, attachmentMarkdown: attachmentMarkdown)
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(MarkdownLine(format: format, body: body))
        }
        return join(lines)
    }

    /// Joins paragraphs: list items and code lines stay together, everything else is separated by
    /// a blank line; consecutive code lines share one fenced block.
    private static func join(_ lines: [MarkdownLine]) -> String {
        var output = ""
        var orderedIndex = 0
        var previous: FeedbackBlockFormat?
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.format != .code, inFence {
                output += "\n```"
                inFence = false
            }
            if index > 0 {
                let grouped = line.format == previous && [.bulletList, .numberedList, .code].contains(line.format)
                output += grouped ? "\n" : "\n\n"
            }
            orderedIndex = line.format == .numberedList ? (previous == .numberedList ? orderedIndex + 1 : 1) : 0
            if line.format == .code, !inFence {
                output += "```\n"
                inFence = true
            }
            output += prefix(for: line.format, orderedIndex: orderedIndex) + line.body
            previous = line.format
        }
        if inFence {
            output += "\n```"
        }
        return output
    }

    private static func prefix(for format: FeedbackBlockFormat?, orderedIndex: Int) -> String {
        switch format {
        case nil, .code: ""
        case .heading: "## "
        case .bulletList: "- "
        case .numberedList: "\(orderedIndex). "
        case .quote: "> "
        }
    }

    private static func inlineMarkdown(
        _ text: NSAttributedString,
        range: NSRange,
        format: FeedbackBlockFormat?,
        attachmentMarkdown: (UUID) -> String?
    ) -> String {
        var output = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let attachment = attributes[.attachment] as? FeedbackTextAttachment {
                output += attachmentMarkdown(attachment.attachmentID) ?? ""
                return
            }
            let run = (text.string as NSString).substring(with: runRange)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            output += format == .code ? run : styled(run, attributes: attributes, inHeading: format == .heading)
        }
        return output
    }

    /// One run of text with its inline formats: code, bold, italic, strikethrough and link.
    private static func styled(
        _ run: String,
        attributes: [NSAttributedString.Key: Any],
        inHeading: Bool
    ) -> String {
        guard !run.isEmpty else { return run }
        var result = run
        if attributes[codeKey] != nil {
            result = wrap(result, marker: "`")
        } else if !inHeading {
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                let marker = (traits.contains(.bold) ? "**" : "") + (traits.contains(.italic) ? "*" : "")
                if !marker.isEmpty {
                    result = wrap(result, marker: marker)
                }
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                result = wrap(result, marker: "~~")
            }
        }
        if let url = linkURL(from: attributes[.link]) {
            result = "[\(result)](\(url.absoluteString))"
        }
        return result
    }

    /// Wraps `text` in `marker`, keeping surrounding whitespace outside the markers because
    /// Markdown does not format text that starts or ends with a space inside them.
    private static func wrap(_ text: String, marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let leading = String(text.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        return leading + marker + trimmed + marker + trailing
    }
}
