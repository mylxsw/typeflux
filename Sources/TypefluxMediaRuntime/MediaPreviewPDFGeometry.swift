import CoreGraphics
import Foundation
import PDFKit
import TypefluxMediaProtocol

/// Coordinates always refer to the exact rotated media-box raster sent to the host.
enum MediaPreviewPDFGeometry {
    static func locate(_ page: PDFPage, context: CGContext, transform: CGAffineTransform,
                       passage: String) -> MediaTextGeometry {
        let text = page.string ?? ""
        if let range = MediaPreviewText.ranges(in: text, passage: passage).first {
            let remainder = (text as NSString).substring(from: NSMaxRange(range))
            guard MediaPreviewText.ranges(in: remainder, passage: passage).isEmpty else { return .init(boxes: []) }
            let boxes = (page.selection(for: range)?.selectionsByLine() ?? []).map { line in
                let rect = line.bounds(for: page).applying(transform)
                return CGRect(x: rect.minX / Double(context.width), y: rect.minY / Double(context.height),
                              width: rect.width / Double(context.width), height: rect.height / Double(context.height))
            }
            guard boxes.count <= 64, boxes.allSatisfy(MediaTextRecognition.valid) else { return .init(boxes: []) }
            return .init(boxes: boxes)
        }
        guard let image = context.makeImage() else { return .init(boxes: []) }
        // Indexed mixed pages prepend the native layer to the full Vision text. Retain that
        // prefix for exact matching; only real OCR substring boxes are painted for its supplement.
        return (try? MediaPreviewOCR.locate(image, passage: passage, prefix: text)) ?? .init(boxes: [])
    }
}
