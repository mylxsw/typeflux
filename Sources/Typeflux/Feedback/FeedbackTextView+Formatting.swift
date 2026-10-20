import AppKit

enum FeedbackInlineFormat {
    case bold, italic, strikethrough
}

/// Formatting commands of the feedback toolbar and keyboard shortcuts.
extension FeedbackTextView {
    // MARK: - Inline

    func toggleInline(_ format: FeedbackInlineFormat) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            toggleInlineTypingAttribute(format)
            return
        }
        let enable = !isInlineFormatApplied(format, in: range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            guard attributes[.attachment] == nil else { return }
            switch format {
            case .bold, .italic:
                let font = (attributes[.font] as? NSFont) ?? FeedbackRichText.baseFont
                storage.addAttribute(.font, value: Self.font(font, format: format, enabled: enable), range: subrange)
            case .strikethrough:
                if enable {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: subrange)
                } else {
                    storage.removeAttribute(.strikethroughStyle, range: subrange)
                }
            }
        }
        storage.endEditing()
        didChangeText()
    }

    private func toggleInlineTypingAttribute(_ format: FeedbackInlineFormat) {
        var attributes = typingAttributes
        switch format {
        case .bold, .italic:
            let font = (attributes[.font] as? NSFont) ?? FeedbackRichText.baseFont
            let trait: NSFontTraitMask = format == .bold ? .boldFontMask : .italicFontMask
            let enabled = NSFontManager.shared.traits(of: font).contains(trait)
            attributes[.font] = Self.font(font, format: format, enabled: !enabled)
        case .strikethrough:
            if attributes[.strikethroughStyle] != nil {
                attributes.removeValue(forKey: .strikethroughStyle)
            } else {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        typingAttributes = attributes
    }

    static func font(_ font: NSFont, format: FeedbackInlineFormat, enabled: Bool) -> NSFont {
        let trait: NSFontTraitMask = format == .bold ? .boldFontMask : .italicFontMask
        let manager = NSFontManager.shared
        return enabled ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
    }

    func isInlineFormatApplied(_ format: FeedbackInlineFormat, in range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0 else { return false }
        var allApplied = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.attachment] != nil {
                return
            }
            let applied: Bool
            switch format {
            case .bold, .italic:
                let font = (attributes[.font] as? NSFont) ?? FeedbackRichText.baseFont
                let trait: NSFontTraitMask = format == .bold ? .boldFontMask : .italicFontMask
                applied = NSFontManager.shared.traits(of: font).contains(trait)
            case .strikethrough:
                applied = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
            if !applied {
                allApplied = false
                stop.pointee = true
            }
        }
        return allApplied
    }

    // MARK: - Links

    func applyLink(_ url: URL?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if let url {
            storage.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range)
        } else {
            storage.removeAttribute(.link, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        didChangeText()
    }

    // MARK: - Code

    /// A selection inside one line becomes inline code; a selection across lines becomes a code block.
    func toggleCode() {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        let nsText = storage.string as NSString
        let spansLines = range.length > 0
            && nsText.substring(with: range).rangeOfCharacter(from: .newlines) != nil
        if spansLines {
            toggleBlock(.code)
            return
        }
        guard range.length > 0 else {
            var attributes = typingAttributes
            if attributes[FeedbackRichText.codeKey] != nil {
                attributes.removeValue(forKey: FeedbackRichText.codeKey)
                attributes[.font] = FeedbackRichText.baseFont
                attributes.removeValue(forKey: .backgroundColor)
            } else {
                attributes[FeedbackRichText.codeKey] = true
                attributes[.font] = FeedbackRichText.codeFont
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            typingAttributes = attributes
            return
        }
        let isCode = storage.attribute(FeedbackRichText.codeKey, at: range.location, effectiveRange: nil) != nil
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if isCode {
            storage.removeAttribute(FeedbackRichText.codeKey, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.font, value: FeedbackRichText.baseFont, range: range)
        } else {
            storage.addAttributes([
                FeedbackRichText.codeKey: true,
                .font: FeedbackRichText.codeFont,
                .backgroundColor: NSColor.quaternaryLabelColor
            ], range: range)
        }
        didChangeText()
    }

    // MARK: - Blocks

    /// The block format at the start of the paragraph holding the cursor.
    var currentBlockFormat: FeedbackBlockFormat? {
        guard let storage = textStorage, storage.length > 0 else {
            return FeedbackRichText.blockFormat(of: typingAttributes)
        }
        let nsText = storage.string as NSString
        let location = min(selectedRange().location, max(0, nsText.length - 1))
        let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
        if paragraph.length == 0 {
            return FeedbackRichText.blockFormat(of: typingAttributes)
        }
        return FeedbackRichText.blockFormat(of: storage.attributes(at: paragraph.location, effectiveRange: nil))
    }

    /// Applies `format` to the selected paragraphs, or removes it when they all have it already.
    func toggleBlock(_ format: FeedbackBlockFormat) {
        guard let storage = textStorage else { return }
        let nsText = storage.string as NSString
        let selection = selectedRange()
        let paragraphs = nsText.paragraphRange(for: selection)
        let target: FeedbackBlockFormat? = currentBlockFormat == format ? nil : format

        guard paragraphs.length > 0 else {
            // An empty line only has typing attributes to carry the format.
            typingAttributes = FeedbackRichText.paragraphAttributes(for: target)
            return
        }
        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        nsText.enumerateSubstrings(in: paragraphs, options: .byParagraphs) { _, _, enclosing, _ in
            Self.restyle(paragraph: enclosing, in: storage, as: target)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Restyles one paragraph, leaving attachment blocks untouched and inline formats alone.
    static func restyle(paragraph range: NSRange, in storage: NSTextStorage, as format: FeedbackBlockFormat?) {
        let attributes = FeedbackRichText.paragraphAttributes(for: format)
        storage.removeAttribute(FeedbackRichText.blockKey, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.addAttribute(.paragraphStyle, value: attributes[.paragraphStyle] as Any, range: range)
        if let format {
            storage.addAttribute(FeedbackRichText.blockKey, value: format.rawValue, range: range)
        }
        storage.enumerateAttributes(in: range) { current, subrange, _ in
            guard current[.attachment] == nil else { return }
            switch format {
            case .heading, .code:
                storage.addAttribute(.font, value: attributes[.font] as Any, range: subrange)
                if format == .code {
                    storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: subrange)
                }
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: subrange)
                storage.addAttribute(.font, value: FeedbackRichText.baseFont, range: subrange)
            case .bulletList, .numberedList, nil:
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: subrange)
                if let font = current[.font] as? NSFont,
                   abs(font.pointSize - FeedbackRichText.baseFontSize) > 0.5 || font.isFixedPitch {
                    storage.addAttribute(.font, value: FeedbackRichText.baseFont, range: subrange)
                }
            }
        }
    }

    // MARK: - Markdown shortcuts

    /// Turns `- `, `* `, `1. `, `> ` and `## ` typed at the start of a line into the block format.
    /// Returns true when the space was consumed by a shortcut.
    func applyMarkdownShortcut(replacingRange range: NSRange, replacement: String) -> Bool {
        guard replacement == " ", range.length == 0, let storage = textStorage,
              currentBlockFormat == nil else { return false }
        let nsText = storage.string as NSString
        let paragraph = nsText.paragraphRange(for: NSRange(location: range.location, length: 0))
        let prefixRange = NSRange(location: paragraph.location, length: range.location - paragraph.location)
        guard prefixRange.length > 0, prefixRange.length <= 4,
              let format = Self.shortcutFormat(for: nsText.substring(with: prefixRange))
        else { return false }
        guard shouldChangeText(in: prefixRange, replacementString: "") else { return false }
        storage.beginEditing()
        storage.replaceCharacters(in: prefixRange, with: "")
        let styled = NSRange(location: paragraph.location, length: max(0, paragraph.length - prefixRange.length))
        if styled.length > 0 {
            Self.restyle(paragraph: styled, in: storage, as: format)
        }
        storage.endEditing()
        setSelectedRange(NSRange(location: paragraph.location, length: 0))
        typingAttributes = FeedbackRichText.paragraphAttributes(for: format)
        didChangeText()
        return true
    }

    static func shortcutFormat(for prefix: String) -> FeedbackBlockFormat? {
        switch prefix {
        case "-", "*": return .bulletList
        case ">": return .quote
        case "#", "##", "###": return .heading
        default:
            if prefix.hasSuffix("."), prefix.count >= 2, prefix.dropLast().allSatisfy(\.isNumber) {
                return .numberedList
            }
            return nil
        }
    }
}
