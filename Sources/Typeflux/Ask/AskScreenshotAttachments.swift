import CoreGraphics
import Foundation

/// Turns a screenshot into image attachments for a question. A long screenshot is cut into
/// overlapping pieces (`ImageTiling.slices`) that each stay legible once shrunk to the
/// attachment size; one that needs more pieces than a question carries is refused, and the
/// launcher offers to read its text instead.
enum AskScreenshotAttachments {
    enum Failure: Error, Equatable {
        /// It would take this many pieces.
        case tooLong(Int)
        case unreadable
    }

    static func make(_ screenshot: ScreenshotFollowUpImage,
                     maximumCount: Int = AskAttachmentLimits.maximumImages) -> Result<[AskAttachment], Failure> {
        switch ImageTiling.slices(imageSize: screenshot.pixelSize, longEdge: AskAttachmentLimits.imageLongEdge,
                                  maximumCount: maximumCount) {
        case let .failure(.tooManySlices(count)):
            return .failure(.tooLong(count))
        case .failure(.empty):
            return .failure(.unreadable)
        case let .success(rects):
            // Every piece fits in its share of the request, as well as under the per-image limit.
            let share = AskAttachmentLimits.maximumPayloadBytes / max(rects.count, 1) - 1024
            let limit = min(AskAttachmentLimits.maximumImageDataURLBytes, share)
            var items: [AskAttachment] = []
            for (index, rect) in rects.enumerated() {
                guard let piece = screenshot.image.cropping(to: rect),
                      let shrunk = shrink(piece, longEdge: AskAttachmentLimits.imageLongEdge),
                      let dataURL = AskAttachmentLoader.jpegDataURL(shrunk, limit: limit) else {
                    return .failure(.unreadable)
                }
                let name = rects.count == 1 ? L("screenshot.ask.attachmentName")
                    : L("screenshot.ask.attachmentPart", index + 1, rects.count)
                items.append(AskAttachment(kind: .image, name: name, byteSize: dataURL.utf8.count, image: dataURL,
                                          screenshot: true))
            }
            return .success(items)
        }
    }

    /// The image shrunk so its longer side is at most `longEdge` pixels; never enlarged.
    static func shrink(_ image: CGImage, longEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longEdge else { return image }
        let factor = CGFloat(longEdge) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
