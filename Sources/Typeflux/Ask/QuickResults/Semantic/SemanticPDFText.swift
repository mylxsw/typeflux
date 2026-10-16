import Foundation
import PDFKit
import Vision

/// Called only by the disposable content reader, before application startup.
enum SemanticPDFText {
    static let recipe = "pdf-vision-accurate-auto-2400-sparse8-v1"

    static func extract(_ page: PDFPage,
                        recognize: (CGImage) throws -> [String] = recognize) throws -> (text: String, kind: String) {
        let text = page.string ?? ""
        // Keep healthy text layers unchanged. A page number alone must not hide a scanned body.
        guard text.unicodeScalars.lazy.filter({ CharacterSet.alphanumerics.contains($0) }).prefix(8).count < 8 else {
            return (text, "pdf-text")
        }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw AskFileReadError.unavailable
        }
        let scale = 2400 / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard let image = page.thumbnail(of: size, for: .cropBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AskFileReadError.unavailable }
        let recognized = try recognize(image).joined(separator: "\n")
        // Retain sparse native text (for example an invoice footer) alongside the recognized body.
        return (text.isEmpty ? recognized : text + "\n" + recognized, "pdf-ocr")
    }

    static func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
