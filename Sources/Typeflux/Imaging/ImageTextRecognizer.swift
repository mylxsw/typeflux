import CoreGraphics
import Foundation
import Vision

enum ImageTextSource {
    case url(URL)
    case image(CGImage)
}

protocol ImageTextRecognizing {
    /// Recognizes text on this Mac. Throws when the image cannot be read.
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText
}

/// On-device text recognition with Vision: accurate, language-corrected and
/// detecting the language automatically.
struct VisionImageTextRecognizer: ImageTextRecognizing {
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        try await Task.detached(priority: .userInitiated) {
            try Self.recognize(source)
        }.value
    }

    private static func recognize(_ source: ImageTextSource) throws -> RecognizedText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler: VNImageRequestHandler
        switch source {
        case let .url(url): handler = VNImageRequestHandler(url: url)
        case let .image(image): handler = VNImageRequestHandler(cgImage: image)
        }
        try handler.perform([request])
        return RecognizedText(lines: (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText.Line(text: candidate.string, confidence: candidate.confidence,
                                       boundingBox: RecognizedText.topLeftBox(fromVision: observation.boundingBox))
        })
    }
}
