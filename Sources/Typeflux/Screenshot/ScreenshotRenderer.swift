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
        context.setStrokeColor(style.color.cgColor())
        context.setFillColor(style.color.cgColor())
        context.setLineWidth(style.lineWidth)
        switch annotation.kind {
        case let .rect(rect):
            context.stroke(rect.standardized)
        case let .ellipse(rect):
            context.strokeEllipse(in: rect.standardized)
        case let .arrow(from, to):
            drawArrow(from: from, to: to, lineWidth: style.lineWidth, in: context)
        case let .path(points):
            context.addPath(ScreenshotAnnotation.polyline(points))
            context.strokePath()
        case let .highlight(points):
            context.setStrokeColor(style.color.cgColor(alpha: ScreenshotAnnotationStyle.highlighterAlpha))
            context.setLineWidth(style.highlighterWidth)
            context.addPath(ScreenshotAnnotation.polyline(points))
            context.strokePath()
        case let .text(origin, text, fontSize):
            drawText(text, at: origin,
                     attributes: ScreenshotAnnotation.textAttributes(fontSize: fontSize, color: style.color.cgColor()),
                     in: context)
        case .counter:
            let frame = annotation.frame
            context.fillEllipse(in: frame)
            let label = "\(number)"
            let attributes = ScreenshotAnnotation.textAttributes(fontSize: (frame.height * 0.55).rounded(),
                                                                 color: style.color.contrastingTextColor)
            let size = (label as NSString).size(withAttributes: attributes)
            drawText(label, at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
                     attributes: attributes, in: context)
        case .mosaic:
            break
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let head = min(ScreenshotAnnotation.arrowHeadLength(lineWidth: lineWidth), length)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let base = CGPoint(x: to.x - unit.x * head, y: to.y - unit.y * head)
        let half = head * 0.5
        if length > head {
            context.move(to: from)
            // Into the head a little, so no gap shows between them.
            context.addLine(to: CGPoint(x: base.x + unit.x, y: base.y + unit.y))
            context.strokePath()
        }
        context.move(to: to)
        context.addLine(to: CGPoint(x: base.x - unit.y * half, y: base.y + unit.x * half))
        context.addLine(to: CGPoint(x: base.x + unit.y * half, y: base.y - unit.x * half))
        context.closePath()
        context.fillPath()
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
