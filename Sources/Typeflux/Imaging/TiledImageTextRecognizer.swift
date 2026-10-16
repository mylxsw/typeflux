import CoreGraphics
import Foundation
import TypefluxMediaProtocol

/// Reads a tall image (a long screenshot) band by band, since Vision shrinks a whole one
/// until its text is too small to read. Bands overlap and the lines read twice are joined
/// (`ImageTiling.merge`); images that fit one band, and files, go straight to `base`.
struct TiledImageTextRecognizer: ImageTextRecognizing {
    private static let admission = AskToolPixelBudget(limit: 2)
    var base: any ImageTextRecognizing
    var bandHeight = ImageTiling.textBandHeight
    var overlap = ImageTiling.textBandOverlap

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        try Task.checkCancellation()
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        if case let .image(image) = source {
            guard image.width <= 16384, image.height <= 65536, image.width <= 64_000_000 / image.height
            else { throw MediaFailure.tooLarge }
        }
        guard case let .image(image) = source, image.height > bandHeight else {
            return try await base.recognizeText(in: source)
        }
        guard bandHeight > 0, bandHeight <= 65536, overlap >= 0, overlap < bandHeight else { throw MediaFailure.invalidProtocol }
        guard (image.height - overlap + bandHeight - overlap - 1) / (bandHeight - overlap) <= 32 else { throw MediaFailure.tooLarge }
        let bands = ImageTiling.bands(imageHeight: image.height, height: bandHeight, overlap: overlap)
        guard bands.count <= 32 else { throw MediaFailure.tooLarge }
        var bytes = 0, count = 0
        var results: [(band: ImageTiling.Band, text: RecognizedText)] = []
        for band in bands {
            try Task.checkCancellation()
            let rect = CGRect(x: 0, y: band.start, width: image.width, height: band.height)
            guard let piece = image.cropping(to: rect) else { throw ImageTilingError.unreadable }
            let text = try await base.recognizeText(in: .image(piece))
            try Task.checkCancellation()
            bytes += text.lines.reduce(0) { $0 + $1.text.utf8.count }
            count += text.lines.count
            guard bytes <= 1024 * 1024, count <= 4096 else { throw MediaFailure.tooLarge }
            results.append((band, text))
        }
        return ImageTiling.merge(results, imageSize: CGSize(width: image.width, height: image.height))
    }
}

enum ImageTilingError: Error, Equatable {
    case unreadable
}
