import CoreGraphics
import Foundation
import TypefluxMediaProtocol

enum ImageTextSource {
    case url(URL)
    case image(CGImage)
}

protocol ImageTextRecognizing {
    /// Recognizes text on this Mac. Throws when the image cannot be read.
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText
}

/// Stable file/raw-pixel facade; Vision objects exist only in the disposable media child.
struct VisionImageTextRecognizer: ImageTextRecognizing {
    private static let admission = AskToolPixelBudget(limit: 2)
    var worker: MediaWorker = .textRecognition

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        let response = try await perform(source, operation: .recognizeText)
        guard let result = response.recognition else { throw MediaFailure.invalidProtocol }
        return Self.materialize(result)
    }

    func textGeometry(in image: CGImage) async throws -> MediaTextGeometry {
        let response = try await perform(.image(image), operation: .textGeometry)
        guard let result = response.geometry else { throw MediaFailure.invalidProtocol }
        return result
    }

    private func perform(_ source: ImageTextSource, operation: MediaRequest.Operation) async throws -> MediaResponse {
        try Task.checkCancellation()
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancelled = AskSearchCancellation(), input = UncheckedSendable(source), worker = self.worker
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                if cancelled.isCancelled { throw CancellationError() }
                let media: MediaWorker.Input, options: MediaTextInput?, revision: ClipboardImageRevision?
                switch input.value {
                case let .url(url):
                    revision = try ClipboardImageRevision(url); media = .file(url); options = nil
                case let .image(image):
                    let shape = MediaTextInput(width: image.width, height: image.height)
                    try shape.validate()
                    guard let context = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data
                    else { throw MediaFailure.unavailable }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    media = .data(Data(bytes: bytes, count: shape.byteCount)); options = shape; revision = nil
                }
                let result = try worker.perform(operation, input: media, textInput: options,
                    isCancelled: { cancelled.isCancelled }) { response, _ in
                        return response
                    }
                if case let .url(url) = input.value, revision?.matches(url) != true { throw MediaFailure.unreadable }
                return result
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancelled.cancel() }
    }

    static func materialize(_ result: MediaTextRecognition) -> RecognizedText {
        RecognizedText(lines: result.lines.map { value in
            let ranges = value.regions
            var line = RecognizedText.Line(text: value.text, confidence: value.confidence, boundingBox: value.box,
                locate: { range in ranges.first { $0.range == range }?.box })
            line.sensitiveMatches = ranges.map { .init(kind: $0.kind, range: $0.range) }
            return line
        })
    }
}

/// Carries a value Vision made and never changes again across concurrency domains.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
