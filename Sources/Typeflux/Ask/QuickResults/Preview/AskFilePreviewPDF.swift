import AppKit
import PDFKit

/// Rasterizes the matched page, with passage highlights in the PDF's own coordinate space.
enum AskFilePreviewPDF {
    struct Result: @unchecked Sendable {
        var images: [CGImage]
        var numbers: [Int]
        var pages: Int
    }

    static func render(_ url: URL, pixels: CGSize, evidence: AskFileHit.Evidence?,
                       cancellation: AskSearchCancellation) throws -> Result {
        guard !cancellation.isCancelled, let document = PDFDocument(url: url), !document.isLocked,
              document.pageCount > 0 else { throw AskFileReadError.unavailable }
        let indices: [Int]
        if let number = evidence?.page, (1 ... document.pageCount).contains(number) { indices = [number - 1] } else {
            indices = Array(0 ..< min(3, document.pageCount))
        }
        let images = try indices.map { index in
            guard !cancellation.isCancelled, let page = document.page(at: index), let reference = page.pageRef
            else { throw AskFileReadError.cancelled }
            let box = page.bounds(for: .mediaBox)
            let rotated = abs(page.rotation) % 180 == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width > 0, size.height > 0, pixels.width.isFinite, pixels.height.isFinite,
                  pixels.width > 0, pixels.height > 0 else { throw AskFileReadError.unavailable }
            let scale = min(pixels.width / size.width, pixels.height / size.height)
            let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw AskFileReadError.unavailable }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.concatenate(reference.getDrawingTransform(.mediaBox, rect: rect, rotate: 0,
                                                                preserveAspectRatio: true))
            context.drawPDFPage(reference)
            if evidence?.page == index + 1, let passage = evidence?.text, let text = page.string {
                context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.05, alpha: 0.38))
                for range in ranges(in: text, passage: passage) {
                    for line in page.selection(for: range)?.selectionsByLine() ?? [] {
                        context.fill(line.bounds(for: page).insetBy(dx: -1, dy: -1))
                    }
                }
            }
            guard let image = context.makeImage() else { throw AskFileReadError.unavailable }
            return image
        }
        return Result(images: images, numbers: indices.map { $0 + 1 }, pages: document.pageCount)
    }

    /// The index may normalize line breaks; retain UTF-16 offsets back to the actual PDF text.
    static func ranges(in text: String, passage: String) -> [NSRange] {
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let direct = (text as NSString).range(of: passage, options: [.caseInsensitive, .diacriticInsensitive])
        if direct.location != NSNotFound { return [direct] }
        func compact(_ value: String) -> (String, [Int]) {
            var units: [UInt16] = [], offsets: [Int] = [], position = 0
            for scalar in value.unicodeScalars {
                let encoded = Array(String(scalar).utf16)
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    units += encoded; offsets += encoded.indices.map { position + $0 }
                }
                position += encoded.count
            }
            return (String(decoding: units, as: UTF16.self), offsets)
        }
        let (source, offsets) = compact(text), (needle, _) = compact(passage)
        guard !needle.isEmpty else { return [] }
        let range = (source as NSString).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound, NSMaxRange(range) <= offsets.count else { return [] }
        let start = offsets[range.location], end = offsets[NSMaxRange(range) - 1] + 1
        return [NSRange(location: start, length: end - start)]
    }
}
