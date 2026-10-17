import CoreGraphics
import Foundation
import TypefluxMediaProtocol
import Vision

/// Runs only in the bounded disposable preview helper, on the exact oriented display raster.
public enum MediaPreviewOCR {
    public static func locate(_ image: CGImage, passage: String, prefix: String = "") throws -> MediaTextGeometry {
        guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(boxes: [])
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        guard candidates.count <= MediaOCRResult.maximumLines else { throw MediaFailure.tooLarge }
        try MediaOCRResult(lines: candidates.map(\.string)).validate()
        let prefix = prefix.isEmpty ? "" : prefix + "\n"
        let text = prefix + candidates.map(\.string).joined(separator: "\n")
        guard let matched = MediaPreviewText.ranges(in: text, passage: passage).first else {
            return .init(boxes: [])
        }
        // Repeated passages do not identify which stored occurrence supplied the hit.
        let remainder = (text as NSString).substring(from: NSMaxRange(matched))
        guard MediaPreviewText.ranges(in: remainder, passage: passage).isEmpty else {
            return .init(boxes: [])
        }
        var offset = prefix.utf16.count, boxes: [CGRect] = []
        for candidate in candidates {
            let line = NSRange(location: offset, length: candidate.string.utf16.count)
            let intersection = NSIntersectionRange(matched, line)
            offset += line.length + 1
            guard intersection.length > 0 else { continue }
            let local = NSRange(location: intersection.location - line.location, length: intersection.length)
            guard let range = Range(local, in: candidate.string),
                  let box = try candidate.boundingBox(for: range)?.boundingBox,
                  MediaTextRecognition.valid(box) else { return .init(boxes: []) }
            boxes.append(box)
            guard boxes.count <= 64 else { throw MediaFailure.tooLarge }
        }
        return .init(boxes: boxes)
    }
}
