import AppKit

/// Draws an attachment block (the text view is flipped: y grows downward) in the feedback body: a thumbnail for images,
/// a cover with a play
/// button for videos and a file card for documents, with the compress/upload/failed state on top.
final class FeedbackAttachmentCell: NSTextAttachmentCell {
    private let attachmentID: UUID
    private let provider: (UUID) -> FeedbackAttachment?

    init(attachmentID: UUID, provider: @escaping (UUID) -> FeedbackAttachment?) {
        self.attachmentID = attachmentID
        self.provider = provider
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static let maxImageSize = NSSize(width: 360, height: 220)
    static let videoSize = NSSize(width: 320, height: 180)
    static let fileSize = NSSize(width: 360, height: 56)

    /// The remove button's hit area inside a block drawn in `frame`: a 24pt circle in the top
    /// right corner of a picture, or at the end of a file row.
    static func removeButtonRect(in frame: NSRect, kind: FeedbackAttachmentKind) -> NSRect {
        let side = TFControlSize.small.height
        switch kind {
        case .image, .video:
            return NSRect(x: frame.maxX - side - 6, y: frame.minY + 6, width: side, height: side)
        case .file:
            return NSRect(x: frame.maxX - side - 8, y: frame.midY - side / 2, width: side, height: side)
        }
    }

    static func size(for attachment: FeedbackAttachment?) -> NSSize {
        guard let attachment else { return fileSize }
        switch attachment.kind {
        case .video:
            return videoSize
        case .file:
            return fileSize
        case .image:
            guard let image = attachment.thumbnail, image.size.width > 0, image.size.height > 0 else {
                return NSSize(width: 240, height: 140)
            }
            let scale = min(
                maxImageSize.width / image.size.width, maxImageSize.height / image.size.height, 1
            )
            return NSSize(
                width: max(120, (image.size.width * scale).rounded()),
                height: max(80, (image.size.height * scale).rounded())
            )
        }
    }

    override func cellSize() -> NSSize {
        let size = Self.size(for: provider(attachmentID))
        return NSSize(width: size.width, height: size.height + 8)
    }

    override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func draw(withFrame cellFrame: NSRect, in _: NSView?) {
        guard let attachment = provider(attachmentID) else { return }
        let frame = cellFrame.insetBy(dx: 0, dy: 4)
        let shape = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        switch attachment.kind {
        case .image: drawImage(attachment, in: frame)
        case .video: drawVideo(attachment, in: frame)
        case .file: drawFile(attachment, in: frame)
        }
        if attachment.kind != .file {
            drawMediaState(attachment, in: frame)
        }
        NSGraphicsContext.restoreGraphicsState()

        // A hairline like every card; a failed or refused file gets a red edge.
        let isError = attachment.kind == .file && attachment.state.isError
        let stroke = NSBezierPath(
            roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
        )
        stroke.lineWidth = isError ? 1 : TFMetrics.borderWidth
        (isError ? Palette.danger : Palette.border).setStroke()
        stroke.stroke()

        drawRemoveButton(in: Self.removeButtonRect(in: frame, kind: attachment.kind), onPicture: attachment.kind != .file)
    }

    /// Blocks use the field radius; they sit inside the 10pt text area.
    static let cornerRadius = TFMetrics.fieldCornerRadius

    /// The component library's colors as AppKit colors; they follow the appearance.
    private enum Palette {
        static var card: NSColor { NSColor(TFColors.card) }
        static var control: NSColor { NSColor(TFColors.control) }
        static var border: NSColor { NSColor(TFColors.border) }
        static var accent: NSColor { NSColor(TFColors.accent) }
        static var danger: NSColor { NSColor(TFColors.danger) }
        static var textPrimary: NSColor { NSColor(TFColors.textPrimary) }
        static var textSecondary: NSColor { NSColor(TFColors.textSecondary) }
        static var textTertiary: NSColor { NSColor(TFColors.textTertiary) }
        /// Error text on the dark scrim over a picture.
        static let dangerOnScrim = NSColor(calibratedRed: 1, green: 0.54, blue: 0.5, alpha: 1)
    }

    // MARK: - Kinds

    private func drawImage(_ attachment: FeedbackAttachment, in frame: NSRect) {
        Palette.card.setFill()
        frame.fill()
        attachment.thumbnail?.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        if attachment.state.isReady, attachment.sizeBytes > 0 {
            drawTag(FeedbackAttachmentPolicy.formattedSize(attachment.sizeBytes), in: frame, trailing: false,
                    sharesRow: false)
        }
    }

    private func drawVideo(_ attachment: FeedbackAttachment, in frame: NSRect) {
        NSColor.black.setFill()
        frame.fill()
        attachment.thumbnail?.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        guard attachment.state.isReady else { return }
        // The 36pt glass play button of a large icon-only TFButton.
        let side = TFControlSize.large.height
        let circle = NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        Self.scrimColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        drawSymbol("play.fill", size: TFControlSize.large.iconSize, color: .white,
                   centeredIn: circle.offsetBy(dx: 1, dy: 0))
        let hasDuration = attachment.durationSeconds != nil
        if attachment.sizeBytes > 0 {
            drawTag(FeedbackAttachmentPolicy.formattedSize(attachment.sizeBytes), in: frame, trailing: false,
                    sharesRow: hasDuration)
        }
        if let duration = attachment.durationSeconds {
            drawTag(Self.formattedDuration(duration), in: frame, trailing: true, sharesRow: attachment.sizeBytes > 0)
        }
    }

    /// A `TFListRow`: 28pt neutral icon tile, 13pt semibold name, 11.5pt detail line.
    private func drawFile(_ attachment: FeedbackAttachment, in frame: NSRect) {
        Palette.card.setFill()
        frame.fill()
        let tileSide = TFMetrics.iconTileSize
        let tile = NSRect(x: frame.minX + TFMetrics.rowHorizontalPadding, y: frame.midY - tileSide / 2,
                          width: tileSide, height: tileSide)
        Palette.control.setFill()
        NSBezierPath(roundedRect: tile, xRadius: TFMetrics.iconTileCornerRadius,
                     yRadius: TFMetrics.iconTileCornerRadius).fill()
        drawSymbol("doc.text", size: tileSide * 0.54, color: Palette.textSecondary, centeredIn: tile)

        let textX = tile.maxX + 10
        let textWidth = frame.maxX - textX - TFControlSize.small.height - 16
        (attachment.filename as NSString).draw(
            in: NSRect(x: textX, y: frame.midY - 18, width: textWidth, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Palette.textPrimary,
                .paragraphStyle: Self.truncatingStyle
            ]
        )
        let detailFrame = NSRect(x: textX, y: frame.midY + 2, width: textWidth, height: 16)
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5), .paragraphStyle: Self.truncatingStyle
        ]
        switch attachment.state {
        case let .preparing(progress):
            drawMeter(progress, at: NSPoint(x: textX, y: detailFrame.midY - 3), track: Palette.control)
            (Self.progressLabel(attachment) as NSString).draw(
                in: detailFrame.offsetBy(dx: Self.meterWidth + 8, dy: 0).insetBy(dx: 0, dy: 0),
                withAttributes: detailAttributes.merging([.foregroundColor: Palette.textSecondary]) { $1 }
            )
        case .uploading:
            drawMeter(nil, at: NSPoint(x: textX, y: detailFrame.midY - 3), track: Palette.control)
            (L("feedback.attachment.state.uploading") as NSString).draw(
                in: detailFrame.offsetBy(dx: Self.meterWidth + 8, dy: 0),
                withAttributes: detailAttributes.merging([.foregroundColor: Palette.textSecondary]) { $1 }
            )
        case let .failed(reason):
            (L("feedback.attachment.state.failed") + " · " + reason as NSString).draw(
                in: detailFrame, withAttributes: detailAttributes.merging([.foregroundColor: Palette.danger]) { $1 }
            )
        case let .rejected(reason):
            (reason as NSString).draw(
                in: detailFrame, withAttributes: detailAttributes.merging([.foregroundColor: Palette.danger]) { $1 }
            )
        case .uploaded:
            let detail = attachment.sizeBytes > 0 ? FeedbackAttachmentPolicy.formattedSize(attachment.sizeBytes) : ""
            (detail as NSString).draw(
                in: detailFrame,
                withAttributes: detailAttributes.merging([.foregroundColor: Palette.textSecondary]) { $1 }
            )
        }
    }

    // MARK: - State

    /// Over a picture: a dark scrim with a `TFMeter` and the progress, or the error text.
    private func drawMediaState(_ attachment: FeedbackAttachment, in frame: NSRect) {
        let message: String
        var isError = false
        var progress: Double??
        switch attachment.state {
        case let .preparing(value):
            message = Self.progressLabel(attachment)
            progress = .some(value)
        case .uploading:
            message = L("feedback.attachment.state.uploading")
            progress = .some(nil)
        case let .failed(reason):
            message = L("feedback.attachment.state.failed") + " · " + reason
            isError = true
        case let .rejected(reason):
            message = reason
            isError = true
        case .uploaded:
            return
        }
        NSColor.black.withAlphaComponent(isError ? 0.72 : 0.6).setFill()
        frame.fill()
        let textWidth = min(frame.width - 48, 280)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isError ? .semibold : .medium),
            .foregroundColor: isError ? Palette.dangerOnScrim : NSColor.white,
            .paragraphStyle: Self.centeredWrappingStyle
        ]
        let textHeight = (message as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 60), options: [.usesLineFragmentOrigin], attributes: attributes
        ).height.rounded(.up)
        let meterGap: CGFloat = progress == nil ? 0 : 6 + 8
        let top = frame.midY - (textHeight + meterGap) / 2
        if let progress {
            drawMeter(progress, at: NSPoint(x: frame.midX - Self.meterWidth / 2, y: top),
                      track: NSColor.white.withAlphaComponent(0.22))
        }
        (message as NSString).draw(
            in: NSRect(x: frame.midX - textWidth / 2, y: top + meterGap, width: textWidth, height: textHeight),
            withAttributes: attributes
        )
    }

    private static func progressLabel(_ attachment: FeedbackAttachment) -> String {
        guard case let .preparing(progress) = attachment.state else { return "" }
        let label = attachment.kind == .video
            ? L("feedback.attachment.state.compressing") : L("feedback.attachment.state.preparing")
        return progress.map { "\(label) \(Int(($0 * 100).rounded()))%" } ?? label
    }

    static let meterWidth: CGFloat = 120
    private static let scrimColor = NSColor.black.withAlphaComponent(0.55)

    /// A `TFMeter`: a 6pt capsule track with the accent fill. Unknown progress shows a third.
    private func drawMeter(_ progress: Double?, at origin: NSPoint, track: NSColor) {
        let height: CGFloat = 6
        let bar = NSRect(x: origin.x, y: origin.y, width: Self.meterWidth, height: height)
        track.setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        let fraction = progress.map { max(0.04, min(1, $0)) } ?? 0.35
        Palette.accent.setFill()
        let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: height)
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }

    /// A 16pt capsule caption (the `TFTag` size) in a bottom corner of a picture. Two captions on
    /// one row split the width.
    private func drawTag(_ text: String, in frame: NSRect, trailing: Bool, sharesRow: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let height = TFMetrics.tagHeight
        let available = sharesRow ? frame.width / 2 - 9 : frame.width - 12
        let width = min(size.width.rounded(.up) + 12, available)
        let tag = NSRect(x: trailing ? frame.maxX - width - 6 : frame.minX + 6,
                         y: frame.maxY - height - 6, width: width, height: height)
        Self.scrimColor.setFill()
        NSBezierPath(roundedRect: tag, xRadius: height / 2, yRadius: height / 2).fill()
        (text as NSString).draw(
            in: NSRect(x: tag.minX + 6, y: tag.midY - size.height / 2, width: tag.width - 12, height: size.height),
            withAttributes: attributes.merging([.paragraphStyle: Self.truncatingStyle]) { $1 }
        )
    }

    /// A small icon-only button: glass-like over a picture, plain at the end of a file row.
    private func drawRemoveButton(in rect: NSRect, onPicture: Bool) {
        if onPicture {
            Self.scrimColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        drawSymbol("xmark", size: TFControlSize.small.iconSize, color: onPicture ? .white : Palette.textTertiary,
                   centeredIn: rect)
    }

    private func drawSymbol(_ name: String, size: CGFloat, color: NSColor, centeredIn rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let target = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                            width: image.size.width, height: image.size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: - Helpers

    private static let centeredWrappingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .center
        return style
    }()

    private static let truncatingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    static func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
