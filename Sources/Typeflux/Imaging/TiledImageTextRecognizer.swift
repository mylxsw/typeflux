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
    var crop: @Sendable (CGImage, CGRect) -> CGImage? = { $0.cropping(to: $1) }

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        try Task.checkCancellation()
        // Production bases are the native facade. Custom/actor bases retain their own contract.
        let native = base as? VisionImageTextRecognizer
        let authorization = native?.worker.authorization()
        func check() throws {
            try Task.checkCancellation()
            if let native, let authorization, !native.worker.permits(authorization) { throw MediaFailure.unavailable }
        }
        func read(_ source: ImageTextSource) async throws -> RecognizedText {
            try check()
            let result: RecognizedText
            if let native, let authorization {
                result = try await native.recognizeText(in: source, authorization: authorization)
            } else { result = try await base.recognizeText(in: source) }
            try check()
            return result
        }
        try check()
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        if case let .image(image) = source {
            guard image.width <= 16384, image.height <= 65536, image.width <= 64_000_000 / image.height
            else { throw MediaFailure.tooLarge }
        }
        guard bandHeight > 0, bandHeight <= 65536, overlap >= 0, overlap < bandHeight else { throw MediaFailure.invalidProtocol }
        guard case let .image(image) = source else {
            return try await read(source)
        }
        let safeHeight = Self.safeBandHeight(width: image.width, requested: bandHeight)
        guard safeHeight > 0 else { throw MediaFailure.tooLarge }
        if image.height <= safeHeight { return try await read(source) }
        let safeOverlap = min(overlap, safeHeight / 4)
        guard (image.height - safeOverlap + safeHeight - safeOverlap - 1) / (safeHeight - safeOverlap) <= 32
        else { throw MediaFailure.tooLarge }
        let bands = ImageTiling.bands(imageHeight: image.height, height: safeHeight, overlap: safeOverlap)
        guard bands.count <= 32 else { throw MediaFailure.tooLarge }
        var bytes = 0, count = 0
        var results: [(band: ImageTiling.Band, text: RecognizedText)] = []
        let crop = self.crop
        for band in bands {
            try check()
            let rect = CGRect(x: 0, y: band.start, width: image.width, height: band.height)
            guard let piece = crop(image, rect) else { throw ImageTilingError.unreadable }
            let text = try await read(.image(piece))
            bytes += text.lines.reduce(0) { $0 + $1.text.utf8.count }
            count += text.lines.count
            guard bytes <= 1024 * 1024, count <= 4096 else { throw MediaFailure.tooLarge }
            results.append((band, text))
        }
        try check()
        let result = ImageTiling.merge(results, imageSize: CGSize(width: image.width, height: image.height))
        try check()
        return result
    }

    static func safeBandHeight(width: Int, requested: Int) -> Int {
        guard width > 0, requested > 0 else { return 0 }
        return min(requested, 16_000_000 / width)
    }
}

enum ImageTilingError: Error, Equatable {
    case unreadable
}
