import Foundation
import PDFKit
import Vision

/// Called only by the disposable content reader, before application startup.
enum SemanticPDFText {
    static let recipe = "pdf-vision-accurate-auto-2400-image-body-v2"

    static func extract(_ page: PDFPage,
                        recognize: (CGImage) throws -> [String] = recognize) throws -> (text: String, kind: String) {
        let text = page.string ?? ""
        // Native-only pages keep their fast path, including short titles. On image-bearing pages,
        // headers and footers alone cannot prove that the scanned body has a usable text layer.
        if alphanumericCount(text, upTo: 8) == 8,
           !containsImage(page) || hasNativeBody(page) {
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

    private static func alphanumericCount(_ text: String, upTo limit: Int) -> Int {
        text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.prefix(limit).count
    }

    /// A conservative sufficiency test, not a full layout analysis: require 80 native letters/digits
    /// across at least three body lines, excluding the outer 20% at either end of the page.
    private static func hasNativeBody(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .cropBox)
        let body = bounds.insetBy(dx: 0, dy: bounds.height * 0.2)
        let lines = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
        var count = 0, bodyLines = 0
        for line in lines {
            let rect = line.bounds(for: page)
            guard body.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            let letters = alphanumericCount(line.string ?? "", upTo: 80)
            guard letters >= 8 else { continue }
            count += letters; bodyLines += 1
            if count >= 80, bodyLines >= 3 { return true }
        }
        return false
    }

    // Inspect resource dictionaries without decoding image pixels. Form resources are walked
    // iteratively and stream identity breaks cycles. Inline images are outside this subset.
    // swiftlint:disable:next cyclomatic_complexity
    private static func containsImage(_ page: PDFPage) -> Bool {
        guard var dictionary = page.pageRef?.dictionary else { return false }
        let resources = ImageResources()
        var parents: Set<CGPDFDictionaryRef> = []
        while parents.insert(dictionary).inserted {
            var initial: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &initial), let initial {
                resources.pending.append(initial); break
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent), let parent else { break }
            dictionary = parent
        }
        while !resources.found, let next = resources.pending.popLast() {
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(next, "XObject", &objects), let objects else { continue }
            CGPDFDictionaryApplyFunction(objects, { _, object, context in
                guard let context else { return }
                let state = Unmanaged<ImageResources>.fromOpaque(context).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard !state.found, CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      state.visited.insert(stream).inserted,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
                if String(cString: subtype) == "Image" { state.found = true }
                if String(cString: subtype) == "Form" {
                    var nested: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                        state.pending.append(nested)
                    }
                }
            }, Unmanaged.passUnretained(resources).toOpaque())
        }
        return resources.found
    }

    private final class ImageResources {
        var pending: [CGPDFDictionaryRef] = []
        var visited: Set<CGPDFStreamRef> = []
        var found = false
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
