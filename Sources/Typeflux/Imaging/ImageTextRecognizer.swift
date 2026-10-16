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
    var readRevision: @Sendable (URL) throws -> ClipboardImageRevision = { try ClipboardImageRevision($0) }
    var readPixels: @Sendable (CGImage, MediaTextInput) throws -> Data = { try Self.pixels($0, shape: $1) }

    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        try await recognizeText(in: source, authorization: worker.authorization())
    }

    /// Internal bands retain the enclosing batch's original native generation.
    func recognizeText(in source: ImageTextSource, authorization: MediaWorker.Authorization) async throws -> RecognizedText {
        let response = try await perform(source, operation: .recognizeText, authorization: authorization)
        guard let result = response.recognition else { throw MediaFailure.invalidProtocol }
        return Self.materialize(result)
    }

    func textGeometry(in image: CGImage) async throws -> MediaTextGeometry {
        let response = try await perform(.image(image), operation: .textGeometry)
        guard let result = response.geometry else { throw MediaFailure.invalidProtocol }
        return result
    }

    private func perform(_ source: ImageTextSource, operation: MediaRequest.Operation,
                         authorization original: MediaWorker.Authorization? = nil) async throws -> MediaResponse {
        try Task.checkCancellation()
        let authorization = original ?? worker.authorization()
        guard worker.permits(authorization) else { throw MediaFailure.unavailable }
        let slot = try Self.admission.acquire(bytes: 1)
        defer { withExtendedLifetime(slot) {} }
        let cancellation = AskSearchCancellation(), input = UncheckedSendable(source), worker = self.worker
        let readRevision = self.readRevision, readPixels = self.readPixels
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || !worker.permits(authorization) }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                if cancelled() { throw CancellationError() }
                let media: MediaWorker.Input, options: MediaTextInput?, revision: ClipboardImageRevision?
                switch input.value {
                case let .url(url):
                    revision = try readRevision(url); media = .file(url); options = nil
                case let .image(image):
                    let shape = MediaTextInput(width: image.width, height: image.height)
                    try shape.validate()
                    media = .data(try readPixels(image, shape)); options = shape; revision = nil
                }
                if cancelled() { throw CancellationError() }
                let result = try worker.perform(operation, input: media, textInput: options,
                    authorization: authorization, isCancelled: cancelled) { response, _ in
                        return response
                    }
                if case let .url(url) = input.value, revision?.matches(url) != true { throw MediaFailure.unreadable }
                if cancelled() { throw CancellationError() }
                return result
            }.value
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            return result
        } onCancel: { cancellation.cancel() }
    }

    static func pixels(_ image: CGImage, shape: MediaTextInput) throws -> Data {
        try shape.validate()
        guard shape.width == image.width, shape.height == image.height else { throw MediaFailure.invalidProtocol }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = context.data
        else { throw MediaFailure.unavailable }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: bytes, count: shape.byteCount)
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
