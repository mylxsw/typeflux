import Foundation
import ImageIO
import Vision
import TypefluxMediaProtocol

public enum MediaOCRDecoder {
    public static func decode(_ request: MediaRequest, directory: URL,
                              recognize: (CGImage) throws -> [String] = recognize) throws -> MediaResponse {
        try request.validate()
        guard request.operation == .clipboardOCR else { throw MediaFailure.invalidProtocol }
        let input = try FileHandle(forReadingFrom: directory.appendingPathComponent("input"))
        defer { try? input.close() }
        let data = try input.read(upToCount: MediaOCRResult.inputBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= MediaOCRResult.inputBytes else { throw MediaFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?, MediaWorkflowFormat(rawValue: type) != nil,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width <= 16_000_000 / height
        else { throw MediaFailure.unreadable }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw MediaFailure.unreadable }
        var response = MediaResponse(id: request.id)
        response.ocr = MediaOCRResult(lines: try recognize(image))
        try response.validate(for: request)
        return response
    }
    public static func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        guard observations.count <= MediaOCRResult.maximumLines else { throw MediaFailure.tooLarge }
        let result = MediaOCRResult(lines: observations.compactMap { $0.topCandidates(1).first?.string })
        try result.validate()
        return result.lines
    }
}
