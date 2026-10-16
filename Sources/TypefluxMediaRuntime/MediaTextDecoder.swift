import Foundation
import CoreGraphics
import ImageIO
import Vision
import TypefluxMediaProtocol

public enum MediaTextDecoder {
    public static func decode(_ request: MediaRequest, directory: URL,
                              recognize: (CGImage) throws -> MediaTextRecognition = recognize,
                              geometry: (CGImage) throws -> MediaTextGeometry = geometry) throws -> MediaResponse {
        try request.validate()
        guard request.operation == .recognizeText || request.operation == .textGeometry else { throw MediaFailure.invalidProtocol }
        let input = try FileHandle(forReadingFrom: directory.appendingPathComponent("input"))
        defer { try? input.close() }
        let limit = request.textInput?.byteCount ?? MediaOCRResult.inputBytes
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw MediaFailure.tooLarge }
        let image: CGImage
        if let raw = request.textInput {
            guard data.count == raw.byteCount, let provider = CGDataProvider(data: data as CFData),
                  let value = CGImage(width: raw.width, height: raw.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: raw.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw MediaFailure.invalidProtocol }
            image = value
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
            else { throw MediaFailure.unreadable }
            try MediaTextInput(width: width, height: height).validate()
            guard let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary) else { throw MediaFailure.unreadable }
            image = value
        }
        var response = MediaResponse(id: request.id)
        if request.operation == .textGeometry { response.geometry = try geometry(image) }
        else { response.recognition = try recognize(image) }
        try response.validate(for: request)
        guard try JSONEncoder().encode(response).count <= MediaOCRResult.responseBytes else { throw MediaFailure.tooLarge }
        return response
    }
    public static func geometry(_ image: CGImage) throws -> MediaTextGeometry {
        let request = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        guard observations.count <= 1024 else { throw MediaFailure.tooLarge }
        let result = MediaTextGeometry(boxes: observations.map(\.boundingBox))
        try result.validate()
        return result
    }
    public static func recognize(_ image: CGImage) throws -> MediaTextRecognition {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        guard observations.count <= MediaOCRResult.maximumLines else { throw MediaFailure.tooLarge }
        var lines: [MediaTextRecognition.Line] = []
        var textBytes = 0, regionCount = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            try MediaOCRResult(lines: [candidate.string]).validate()
            textBytes += candidate.string.utf8.count + (lines.isEmpty ? 0 : 1)
            guard textBytes <= MediaOCRResult.textBytes else { throw MediaFailure.tooLarge }
            let matches = MediaSensitiveText.matches(in: candidate.string)
            regionCount += matches.count
            guard matches.count <= 128, regionCount <= 4096 else { throw MediaFailure.tooLarge }
            let regions = try matches.map { match -> MediaTextRecognition.Region in
                guard let range = Range(match.range, in: candidate.string),
                      let box = try candidate.boundingBox(for: range)?.boundingBox else { throw MediaFailure.unavailable }
                return .init(kind: match.kind, range: match.range, box: topLeft(box))
            }
            lines.append(.init(text: candidate.string, confidence: candidate.confidence,
                               box: topLeft(observation.boundingBox), regions: regions))
        }
        let result = MediaTextRecognition(lines: lines)
        try result.validate()
        return result
    }
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
