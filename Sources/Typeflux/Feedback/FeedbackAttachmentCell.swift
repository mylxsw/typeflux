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

    /// The remove button's hit area inside a block drawn in `frame`.
    static func removeButtonRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - 30, y: frame.minY + 8, width: 22, height: 22)
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
        let radius: CGFloat = 10
        let clip = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        switch attachment.kind {
        case .image: drawImage(attachment, in: frame)
        case .video: drawVideo(attachment, in: frame)
        case .file: drawFile(attachment, in: frame)
        }
        drawStateOverlay(attachment, in: frame)
        NSGraphicsContext.restoreGraphicsState()

        let isError = switch attachment.state {
        case .failed, .rejected: true
        default: false
        }
        (isError ? NSColor.systemRed : NSColor.separatorColor).setStroke()
        clip.lineWidth = isError ? 1.5 : 1
        clip.stroke()

        drawRemoveButton(in: frame)
    }

    // MARK: - Kinds

    private func drawImage(_ attachment: FeedbackAttachment, in frame: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        frame.fill()
        attachment.thumbnail?.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        if attachment.state.isReady, attachment.sizeBytes > 0 {
            drawChip(FeedbackAttachmentPolicy.formattedSize(attachment.sizeBytes), at: frame, trailingBottom: true)
        }
    }

    private func drawVideo(_ attachment: FeedbackAttachment, in frame: NSRect) {
        NSColor.black.withAlphaComponent(0.85).setFill()
        frame.fill()
        attachment.thumbnail?.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil
        )
        let diameter: CGFloat = 44
        let circle = NSRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: circle.minX + 17, y: circle.minY + 13))
        triangle.line(to: NSPoint(x: circle.minX + 17, y: circle.maxY - 13))
        triangle.line(to: NSPoint(x: circle.maxX - 12, y: circle.midY))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()
        guard attachment.state.isReady else { return }
        var caption = attachment.filename
        if let duration = attachment.durationSeconds {
            caption += " · " + Self.formattedDuration(duration)
        }
        drawChip(caption, at: frame, trailingBottom: false)
    }

    private func drawFile(_ attachment: FeedbackAttachment, in frame: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        frame.fill()
        let badge = NSRect(x: frame.minX + 12, y: frame.midY - 17, width: 34, height: 34)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        let ext = (attachment.filename as NSString).pathExtension.uppercased()
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.controlAccentColor
        ]
        let badgeSize = (ext as NSString).size(withAttributes: badgeAttributes)
        (ext as NSString).draw(
            at: NSPoint(x: badge.midX - badgeSize.width / 2, y: badge.midY - badgeSize.height / 2),
            withAttributes: badgeAttributes
        )
        let textX = badge.maxX + 10
        let textWidth = frame.maxX - textX - 40
        (attachment.filename as NSString).draw(
            in: NSRect(x: textX, y: frame.minY + 10, width: textWidth, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.truncatingStyle
            ]
        )
        let detail = attachment.sizeBytes > 0 ? FeedbackAttachmentPolicy.formattedSize(attachment.sizeBytes) : " "
        (detail as NSString).draw(
            in: NSRect(x: textX, y: frame.minY + 29, width: textWidth, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
    }

    // MARK: - State

    private func drawStateOverlay(_ attachment: FeedbackAttachment, in frame: NSRect) {
        let message: String
        switch attachment.state {
        case let .preparing(progress):
            let label = attachment
                .kind == .video ? L("feedback.attachment.state.compressing") : L("feedback.attachment.state.preparing")
            message = progress.map { "\(label) \(Int(($0 * 100).rounded()))%" } ?? label
            drawProgressBar(progress, in: frame)
        case .uploading:
            message = L("feedback.attachment.state.uploading")
            drawProgressBar(nil, in: frame)
        case let .failed(reason):
            message = L("feedback.attachment.state.failed") + " · " + reason
        case let .rejected(reason):
            message = reason
        case .uploaded:
            return
        }
        let isError = switch attachment.state {
        case .failed, .rejected: true
        default: false
        }
        // Errors on media can need two lines; the file card is short, so its message stays on one.
        let wraps = isError && attachment.kind != .file
        let bandHeight: CGFloat = wraps ? 42 : 30
        let band = NSRect(x: frame.minX, y: frame.maxY - bandHeight, width: frame.width, height: bandHeight)
        if isError || attachment.kind != .file {
            (isError ? NSColor.systemRed.withAlphaComponent(0.82) : NSColor.black.withAlphaComponent(0.45)).setFill()
            band.fill()
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
            frame.fill()
        }
        let color: NSColor = attachment.kind == .file && !isError ? .labelColor : .white
        (message as NSString).draw(
            in: NSRect(x: band.minX + 10, y: band.minY + 6, width: band.width - 46, height: bandHeight - 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: color,
                .paragraphStyle: wraps ? Self.wrappingStyle : Self.truncatingStyle
            ]
        )
    }

    private func drawProgressBar(_ progress: Double?, in frame: NSRect) {
        let track = NSRect(x: frame.minX, y: frame.maxY - 3, width: frame.width, height: 3)
        NSColor.black.withAlphaComponent(0.2).setFill()
        track.fill()
        NSColor.controlAccentColor.setFill()
        let fraction = progress.map { max(0.02, min(1, $0)) } ?? 0.35
        NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height).fill()
    }

    private func drawChip(_ text: String, at frame: NSRect, trailingBottom: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = min(size.width + 14, frame.width - 24)
        let chip = NSRect(
            x: trailingBottom ? frame.maxX - width - 8 : frame.minX + 8,
            y: frame.maxY - 26, width: width, height: 18
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(
            in: NSRect(x: chip.minX + 7, y: chip.minY + 2, width: chip.width - 14, height: 14),
            withAttributes: attributes.merging([.paragraphStyle: Self.truncatingStyle]) { $1 }
        )
    }

    private func drawRemoveButton(in frame: NSRect) {
        let rect = Self.removeButtonRect(in: frame)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let cross = NSBezierPath()
        let inset: CGFloat = 7
        cross.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        cross.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        cross.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        cross.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }

    // MARK: - Helpers

    private static let wrappingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
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
