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

    /// Vision's own bounds for part of a line, which follow the glyphs exactly.
    static func locator(for candidate: VNRecognizedText) -> RecognizedText.Line.RangeLocator {
        let candidate = UncheckedSendable(candidate)
        return { range in
            let string = candidate.value.string
            guard let swiftRange = Range(range, in: string),
                  let box = try? candidate.value.boundingBox(for: swiftRange)?.boundingBox else { return nil }
            return RecognizedText.topLeftBox(fromVision: box)
        }
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
                                       boundingBox: RecognizedText.topLeftBox(fromVision: observation.boundingBox),
                                       locate: Self.locator(for: candidate))
        })
    }
}

/// Carries a value Vision made and never changes again across concurrency domains.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
