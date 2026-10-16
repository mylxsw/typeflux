import Foundation
import ImageIO

/// File OCR runs only in the disposable worker, on its private verified snapshot.
enum SemanticImageText {
    static let recipe = "image-vision-accurate-auto-4096-v1"

    static func extract(_ url: URL,
                        recognize: (CGImage) throws -> [String] = SemanticPDFText.recognize,
                        emit: (AskFileReadResponse) throws -> Void) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ] as CFDictionary) else { throw AskFileReadError.unavailable }
        // Unlike clipboard OCR, file OCR has no total line/text cap. IPC stays bounded.
        let bytes = try Data(recognize(image).joined(separator: "\n").utf8)
        var offset = 0
        repeat {
            guard let part = AskFileWorkerCommand.contentSlice(bytes, offset: offset) else {
                throw AskFileReadError.protocolError
            }
            try emit(.init(more: true, pages: [.init(text: part.text, offset: Int64(offset),
                                                     segmentKind: "image-ocr")]))
            offset += part.consumed
        } while offset < bytes.count
    }
}
