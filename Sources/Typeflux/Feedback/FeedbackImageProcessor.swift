import AppKit
import Foundation

/// A file ready to upload: images and videos after compression, other files as they are.
struct PreparedFeedbackFile: Equatable {
    let data: Data
    let filename: String
    let contentType: String
    var kind: FeedbackAttachmentKind = .image
    var thumbnail: NSImage?
    var durationSeconds: Double?

    static func == (lhs: PreparedFeedbackFile, rhs: PreparedFeedbackFile) -> Bool {
        lhs.data == rhs.data
            && lhs.filename == rhs.filename
            && lhs.contentType == rhs.contentType
            && lhs.kind == rhs.kind
    }
}

enum FeedbackImageProcessor {
    static let maxPixelDimension = 1600
    static let jpegCompression: CGFloat = 0.78
    /// Qualities tried in turn when the first JPEG is still over the size limit.
    static let fallbackCompressions: [CGFloat] = [0.6, 0.45, 0.3]

    static func prepare(url: URL) throws -> PreparedFeedbackFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FeedbackAPIError.networkError(L("feedback.error.invalidImage"))
        }
        return try prepare(imageData: data, filename: url.lastPathComponent)
    }

    /// Compresses image bytes (a picked file or a pasted screenshot) to a JPEG within the
    /// image size limit. GIFs are passed through unchanged so they stay animated.
    static func prepare(imageData: Data, filename: String) throws -> PreparedFeedbackFile {
        guard let sourceImage = NSImage(data: imageData),
              let sourceRep = bitmapRepresentation(for: sourceImage)
        else {
            throw FeedbackAPIError.networkError(L("feedback.error.invalidImage"))
        }

        if (filename as NSString).pathExtension.lowercased() == "gif" {
            return PreparedFeedbackFile(
                data: imageData, filename: filename, contentType: "image/gif",
                kind: .image, thumbnail: sourceImage
            )
        }

        guard let resizedRep = resizedBitmapRepresentation(
            for: sourceImage,
            pixelsWide: sourceRep.pixelsWide,
            pixelsHigh: sourceRep.pixelsHigh
        ),
            var data = resizedRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegCompression]
            )
        else {
            throw FeedbackAPIError.networkError(L("feedback.error.invalidImage"))
        }
        for quality in fallbackCompressions where Int64(data.count) > FeedbackAttachmentPolicy.maxImageBytes {
            guard let smaller = resizedRep.representation(
                using: .jpeg, properties: [.compressionFactor: quality]
            ) else { break }
            data = smaller
        }
        let thumbnail = NSImage(size: resizedRep.size)
        thumbnail.addRepresentation(resizedRep)

        return PreparedFeedbackFile(
            data: data,
            filename: jpegFilename(from: filename),
            contentType: "image/jpeg",
            kind: .image,
            thumbnail: thumbnail
        )
    }

    private static func bitmapRepresentation(for image: NSImage) -> NSBitmapImageRep? {
        if let tiffData = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiffData) {
            return rep
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private static func resizedBitmapRepresentation(
        for image: NSImage,
        pixelsWide: Int,
        pixelsHigh: Int
    ) -> NSBitmapImageRep? {
        let longestSide = max(pixelsWide, pixelsHigh)
        let scale = longestSide > maxPixelDimension
            ? CGFloat(maxPixelDimension) / CGFloat(longestSide)
            : 1
        let targetPixelsWide = max(1, Int((CGFloat(pixelsWide) * scale).rounded()))
        let targetPixelsHigh = max(1, Int((CGFloat(pixelsHigh) * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetPixelsWide,
            pixelsHigh: targetPixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        rep.size = NSSize(width: targetPixelsWide, height: targetPixelsHigh)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetPixelsWide, height: targetPixelsHigh),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        return rep
    }

    private static func jpegFilename(from filename: String) -> String {
        let baseName = ((filename as NSString).deletingPathExtension as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(baseName.isEmpty ? "feedback-image" : baseName).jpg"
    }
}
