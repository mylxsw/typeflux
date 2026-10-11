import AppKit

/// Turns a frozen display, a region and its annotations into the final image.
///
/// The overlay draws with the same functions (`mosaicPatch` and `draw(_:in:)`), so what is
/// exported is what was on screen. Mosaics only ever read the original screenshot and sit
/// under every other annotation; they only process the part inside the region.
enum ScreenshotRenderer {
    /// A mosaic's finished pixels, ready to lay over the original screenshot.
    struct MosaicPatch {
        /// Transparent outside the mosaic's shape.
        var image: CGImage
        /// Where the image goes, in the source image's pixels.
        var pixelRect: CGRect
        /// The same place in points.
        var rect: CGRect
    }

    /// The region cut out at native pixels, with mosaics applied and annotations drawn on top.
    /// Without annotations it is exactly the cropped screenshot.
    /// - Parameters:
    ///   - crop: the region in global Quartz points.
    ///   - annotations: in global Quartz points.
    static func render(_ display: ScreenSnapshot.Display, crop: CGRect,
                       annotations: [ScreenshotAnnotation]) throws -> CGImage {
        let base = try ScreenshotImageExporter.crop(display, to: crop)
        guard !annotations.isEmpty else { return base }
        guard let cropPixels = ScreenCaptureGeometry.pixelRect(for: crop, displayFrame: display.frame,
                                                               imageSize: display.pixelSize)
        else { throw ScreenshotExportError.emptyRegion }
        let space = ScreenshotMosaicEffects.colorSpace(of: display.image)
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotExportError.encodingFailed }
        // Work top-down in pixels, as the overlay works top-down in points.
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: 1, y: -1)
        drawImage(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), context: context)
        for annotation in annotations {
            guard let mosaic = annotation.mosaic,
                  let patch = mosaicPatch(for: mosaic, color: annotation.style.color, source: display.image,
                                          sourceFrame: display.frame, crop: crop) else { continue }
            drawImage(patch.image, in: patch.pixelRect.offsetBy(dx: -cropPixels.minX, dy: -cropPixels.minY),
                      context: context)
        }
        let scale = pixelScale(imageWidth: display.image.width, imageHeight: display.image.height,
                               frame: display.frame)
        context.translateBy(x: -cropPixels.minX, y: -cropPixels.minY)
        context.scaleBy(x: scale.width, y: scale.height)
        context.translateBy(x: -display.frame.minX, y: -display.frame.minY)
        draw(annotations, in: context)
        guard let image = context.makeImage() else { throw ScreenshotExportError.encodingFailed }
        return image
    }

    // MARK: Mosaic

    /// The mosaic's pixels inside `crop`, taken from the original `source` image.
    /// - Parameters:
    ///   - sourceFrame: where `source` lies, in the same points as the mosaic and the crop.
    /// - Returns: nil when the mosaic misses the region.
    static func mosaicPatch(for mosaic: ScreenshotMosaic, color: ScreenshotAnnotationStyle.Color,
                            source: CGImage, sourceFrame: CGRect, crop: CGRect) -> MosaicPatch? {
        let imageSize = ScreenPixelSize(width: source.width, height: source.height)
        let region = mosaic.frame.intersection(crop)
        guard !region.isNull, !region.isEmpty,
              let cropPixels = ScreenCaptureGeometry.pixelRect(for: crop, displayFrame: sourceFrame,
                                                               imageSize: imageSize),
              let pixels = ScreenCaptureGeometry.pixelRect(for: region, displayFrame: sourceFrame,
                                                           imageSize: imageSize)?.intersection(cropPixels),
              !pixels.isNull, !pixels.isEmpty,
              let piece = source.cropping(to: pixels) else { return nil }
        let scale = pixelScale(imageWidth: source.width, imageHeight: source.height, frame: sourceFrame)
        let pointScale = max(scale.width, scale.height)
        guard let effected = ScreenshotMosaicEffects.apply(mosaic.effect, to: piece,
                                                           block: mosaic.blockSize(scale: pointScale),
                                                           radius: mosaic.blurRadius(scale: pointScale),
                                                           color: color.cgColor()) else { return nil }
        let space = ScreenshotMosaicEffects.colorSpace(of: source)
        guard let context = CGContext(data: nil, width: piece.width, height: piece.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(piece.height))
        context.scaleBy(x: 1, y: -1)
        // Clip to the shape, moved into the piece's top-down pixels.
        var toPiece = CGAffineTransform(translationX: -sourceFrame.minX, y: -sourceFrame.minY)
            .concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
            .concatenating(CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
        guard let mask = mosaic.maskPath.copy(using: &toPiece) else { return nil }
        context.addPath(mask)
        context.clip()
        drawImage(effected, in: CGRect(x: 0, y: 0, width: piece.width, height: piece.height), context: context)
        guard let image = context.makeImage() else { return nil }
        let rect = CGRect(x: sourceFrame.minX + pixels.minX / scale.width,
                          y: sourceFrame.minY + pixels.minY / scale.height,
                          width: pixels.width / scale.width, height: pixels.height / scale.height)
        return MosaicPatch(image: image, pixelRect: pixels, rect: rect)
    }

    // MARK: Vector annotations

    /// Draws every annotation except mosaics, in order, into a context whose y grows downward.
    static func draw(_ annotations: [ScreenshotAnnotation], in context: CGContext) {
        let numbers = ScreenshotAnnotationDocument.counterNumbers(in: annotations)
        for annotation in annotations where !annotation.isMosaic {
            draw(annotation, number: numbers[annotation.id] ?? 0, in: context)
        }
    }

    static func draw(_ annotation: ScreenshotAnnotation, number: Int, in context: CGContext) {
        let style = annotation.style
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(style.cgColor())
        context.setFillColor(style.cgColor())
        context.setLineWidth(style.lineWidth)
        switch annotation.kind {
        case .rect, .ellipse:
            guard let outline = annotation.shapePath else { break }
            switch style.fill {
            case .stroke: break
            case .soft:
                context.setFillColor(style.cgColor(alpha: ScreenshotAnnotationStyle.softFillAlpha))
                context.addPath(outline)
                context.fillPath()
            case .solid:
                context.addPath(outline)
                context.fillPath()
            }
            applyDash(style, in: context)
            context.addPath(outline)
            context.strokePath()
        case let .line(from, to):
            applyDash(style, in: context)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        case let .arrow(from, to):
            if style.outlined {
                drawArrow(from: from, to: to, style: style, outline: arrowOutlineWidth(style.lineWidth),
                          color: CGColor(gray: 1, alpha: style.opacity), in: context)
            }
            drawArrow(from: from, to: to, style: style, outline: 0, color: style.cgColor(), in: context)
        case let .path(points):
            context.addPath(ScreenshotAnnotation.polyline(points))
            context.strokePath()
        case let .highlight(points):
            context.setStrokeColor(style.cgColor(alpha: ScreenshotAnnotationStyle.highlighterAlpha))
            context.setLineWidth(style.highlighterWidth)
            if style.highlighterTip == .square { context.setLineCap(.butt) }
            context.addPath(ScreenshotAnnotation.polyline(points))
            context.strokePath()
        case let .text(origin, text, fontSize):
            drawStyledText(text, at: origin, fontSize: fontSize, frame: annotation.frame, style: style, in: context)
        case .counter:
            let frame = annotation.frame
            if style.counterShape == .bubble {
                context.addPath(counterTail(in: frame, angle: style.counterAngle))
                context.fillPath()
            }
            context.fillEllipse(in: frame)
            let label = ScreenshotAnnotation.counterLabel(number, as: style.counterLabel)
            let textColor = style.color.contrastingTextColor.copy(alpha: style.opacity)
                ?? style.color.contrastingTextColor
            let shrink: CGFloat = label.count > 2 ? 0.38 : label.count > 1 ? 0.45 : 0.55
            let attributes = ScreenshotAnnotation.textAttributes(fontSize: (frame.height * shrink).rounded(),
                                                                 color: textColor)
            let size = (label as NSString).size(withAttributes: attributes)
            drawText(label, at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                     attributes: attributes, in: context)
        case .mosaic:
            break
        }
    }

    /// Dashed outlines and lines; dashes keep round ends, so the gaps are a little longer.
    private static func applyDash(_ style: ScreenshotAnnotationStyle, in context: CGContext) {
        guard style.dash == .dashed else { return }
        context.setLineDash(phase: 0, lengths: ScreenshotAnnotationStyle.dashLengths(lineWidth: style.lineWidth))
    }

    /// How much wider the white outline under an arrow is than the arrow.
    static func arrowOutlineWidth(_ lineWidth: CGFloat) -> CGFloat {
        max(3, lineWidth * 0.75)
    }

    /// The shaft and heads, `outline` points wider all round when drawing the white outline under them.
    private static func drawArrow(from: CGPoint, to: CGPoint, style: ScreenshotAnnotationStyle, outline: CGFloat,
                                  color: CGColor, in context: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color)
        context.setFillColor(color)
        let lineWidth = style.lineWidth
        // Two heads share the length.
        let room = style.arrowHead == .double ? length / 2 : length
        let head = min(ScreenshotAnnotation.arrowHeadLength(lineWidth: lineWidth), room)
        let directions = ScreenshotAnnotation.arrowDirections(from: from, to: to, style: style)
        // Filled heads cover the shaft's ends, so the shaft stops inside them and no square end pokes out.
        let filled = style.arrowHead != .open
        let shaft = ScreenshotAnnotation.arrowShaft(
            from: style.arrowHead == .double ? point(from, back: directions.start, by: head * 0.6) : from,
            to: filled ? point(to, back: directions.end, by: head * 0.6) : to, style: style
        )
        context.setLineWidth(lineWidth + outline * 2)
        context.addPath(shaft)
        context.strokePath()
        var heads = [(to, directions.end)]
        if style.arrowHead == .double { heads.append((from, directions.start)) }
        for (tip, direction) in heads {
            let base = point(tip, back: direction, by: head)
            let half = head * 0.5
            let left = CGPoint(x: base.x - direction.y * half, y: base.y + direction.x * half)
            let right = CGPoint(x: base.x + direction.y * half, y: base.y - direction.x * half)
            if filled {
                context.move(to: tip)
                context.addLine(to: left)
                context.addLine(to: right)
                context.closePath()
                if outline > 0 {
                    context.setLineWidth(outline * 2)
                    context.drawPath(using: .fillStroke)
                } else {
                    context.fillPath()
                }
            } else {
                context.setLineWidth(lineWidth + outline * 2)
                context.addLines(between: [left, tip, right])
                context.strokePath()
            }
        }
    }

    private static func point(_ point: CGPoint, back direction: CGPoint, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x - direction.x * distance, y: point.y - direction.y * distance)
    }

    /// A bubble counter's point: a triangle from the circle out to 1.7 radii along `angle`.
    static func counterTail(in frame: CGRect, angle: CGFloat) -> CGPath {
        let radius = frame.width / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x + cos(angle + 0.75) * radius, y: center.y + sin(angle + 0.75) * radius))
        path.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 1.7, y: center.y + sin(angle) * radius * 1.7))
        path.addLine(to: CGPoint(x: center.x + cos(angle - 0.75) * radius, y: center.y + sin(angle - 0.75) * radius))
        path.closeSubpath()
        return path
    }

    /// The outline of outlined text, as a percentage of the font size (positive: stroke only).
    static let outlineStrokePercent: CGFloat = 24

    /// Plain colored text, text on a block of the color, or white text outlined in the color.
    private static func drawStyledText(_ text: String, at origin: CGPoint, fontSize: CGFloat, frame: CGRect,
                                       style: ScreenshotAnnotationStyle, in context: CGContext) {
        switch style.textStyle {
        case .plain:
            drawText(text, at: origin, attributes: ScreenshotAnnotation.textAttributes(
                fontSize: fontSize, color: style.cgColor(), font: style.font
            ), in: context)
        case .background:
            let radius = min(fontSize * 0.3, frame.height / 2)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            let textColor = style.color.contrastingTextColor.copy(alpha: style.opacity)
                ?? style.color.contrastingTextColor
            drawText(text, at: origin, attributes: ScreenshotAnnotation.textAttributes(
                fontSize: fontSize, color: textColor, font: style.font
            ), in: context)
        case .outline:
            // A wide stroke in the color first, then the white letters over it, so only the outer
            // half of the stroke shows and the letters stay clean. The width is a percentage of the font size.
            var outline = ScreenshotAnnotation.textAttributes(fontSize: fontSize, color: style.cgColor(),
                                                              font: style.font)
            outline[.strokeColor] = NSColor(cgColor: style.cgColor())
            outline[.strokeWidth] = outlineStrokePercent
            drawText(text, at: origin, attributes: outline, in: context)
            drawText(text, at: origin, attributes: ScreenshotAnnotation.textAttributes(
                fontSize: fontSize, color: CGColor(gray: 1, alpha: style.opacity), font: style.font
            ), in: context)
        }
    }

    /// Text in a top-down context: AppKit is told the context is flipped so glyphs stay upright.
    private static func drawText(_ text: String, at origin: CGPoint, attributes: [NSAttributedString.Key: Any],
                                 in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(with: CGRect(origin: origin, size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                          height: .greatestFiniteMagnitude)),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Helpers

    /// Draws an image upright into a context whose y grows downward.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Pixels per point of an image that covers `frame`.
    static func pixelScale(imageWidth: Int, imageHeight: Int, frame: CGRect) -> CGSize {
        CGSize(width: frame.width > 0 ? CGFloat(imageWidth) / frame.width : 1,
               height: frame.height > 0 ? CGFloat(imageHeight) / frame.height : 1)
    }
}
