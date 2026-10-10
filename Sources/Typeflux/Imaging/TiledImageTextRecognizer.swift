import CoreGraphics
import Foundation

/// Reads a tall image (a long screenshot) band by band, since Vision shrinks a whole one
/// until its text is too small to read. Bands overlap and the lines read twice are joined
/// (`ImageTiling.merge`); images that fit one band, and files, go straight to `base`.
struct TiledImageTextRecognizer: ImageTextRecognizing {
    var base: any ImageTextRecognizing
    var bandHeight = ImageTiling.textBandHeight
    var overlap = ImageTiling.textBandOverlap

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        guard case let .image(image) = source, image.height > bandHeight else {
            return try await base.recognizeText(in: source)
        }
        let bands = ImageTiling.bands(imageHeight: image.height, height: bandHeight, overlap: overlap)
        var results: [(band: ImageTiling.Band, text: RecognizedText)] = []
        for band in bands {
            try Task.checkCancellation()
            let rect = CGRect(x: 0, y: band.start, width: image.width, height: band.height)
            guard let piece = image.cropping(to: rect) else { throw ImageTilingError.unreadable }
            results.append((band, try await base.recognizeText(in: .image(piece))))
        }
        return ImageTiling.merge(results, imageSize: CGSize(width: image.width, height: image.height))
    }
}

enum ImageTilingError: Error, Equatable {
    case unreadable
}
