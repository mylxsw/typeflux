import AppKit

/// Draws the list markers and the quote bar in the indent of the feedback body. The markers are
/// not part of the text, so selecting, deleting and serializing a list never sees them.
final class FeedbackLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let nsText = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var location = nsText.paragraphRange(for: NSRange(location: characters.location, length: 0)).location
        while location < NSMaxRange(characters), location < nsText.length {
            let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
            drawDecoration(forParagraph: paragraph, in: storage, origin: origin)
            location = NSMaxRange(paragraph)
        }
    }

    private func drawDecoration(forParagraph paragraph: NSRange, in storage: NSTextStorage, origin: NSPoint) {
        guard let format = FeedbackRichText.blockFormat(
            of: storage.attributes(at: paragraph.location, effectiveRange: nil)
        ) else { return }
        let glyphRange = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let firstLine = lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

        switch format {
        case .bulletList:
            draw(marker: "•", in: firstLine, origin: origin)
        case .numberedList:
            draw(
                marker: "\(orderedIndex(of: paragraph, in: storage.string as NSString, storage: storage)).",
                in: firstLine,
                origin: origin
            )
        case .quote:
            let bounds = boundingRect(forGlyphRange: glyphRange, in: textContainers[0])
            let bar = NSRect(x: origin.x + bounds.minX - 10, y: origin.y + bounds.minY, width: 3, height: bounds.height)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        case .heading, .code:
            break
        }
    }

    private func draw(marker: String, in lineRect: NSRect, origin: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: FeedbackRichText.baseFont, .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = (marker as NSString).size(withAttributes: attributes)
        (marker as NSString).draw(
            at: NSPoint(x: origin.x + lineRect.minX + 20 - size.width, y: origin.y + lineRect.minY + 1),
            withAttributes: attributes
        )
    }

    /// 1-based position of the numbered item among the consecutive numbered items above it.
    private func orderedIndex(of paragraph: NSRange, in nsText: NSString, storage: NSTextStorage) -> Int {
        var index = 1
        var start = paragraph.location
        while start > 0 {
            let previous = nsText.paragraphRange(for: NSRange(location: start - 1, length: 0))
            let format = FeedbackRichText.blockFormat(of: storage.attributes(
                at: previous.location,
                effectiveRange: nil
            ))
            guard format == .numberedList else { break }
            index += 1
            start = previous.location
        }
        return index
    }
}
