import AppKit
import CoreText
import PDFKit
import Testing
@testable import Typeflux
import TypefluxMediaProtocol
import TypefluxMediaRuntime

@Suite("Scanned PDF preview geometry", .exclusiveUIState)
@MainActor
struct SemanticPDFPreviewTests {
    private func draw(_ value: String, in context: CGContext, baseline: CGFloat) {
        context.textPosition = CGPoint(x: 80, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString, 32, nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])), context)
    }

    private func fixture(_ root: URL, rotated: Bool, mixed: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("invoice.pdf")
        var box = CGRect(x: 40, y: 60, width: 800, height: 600)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        draw("Native reimbursement policy", in: pdf, baseline: 450)
        pdf.endPDFPage()
        let bitmap = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        draw("INVOICE", in: bitmap, baseline: 480)
        draw("Invoice number INV-739204", in: bitmap, baseline: 360)
        draw("Payment due after approval", in: bitmap, baseline: 240)
        pdf.beginPDFPage(nil)
        if rotated {
            pdf.translateBy(x: box.midX, y: box.midY); pdf.rotate(by: .pi)
            pdf.translateBy(x: -box.midX, y: -box.midY)
        }
        try pdf.draw(#require(bitmap.makeImage()), in: box)
        if mixed { draw("Native finance header", in: pdf, baseline: 600) }
        pdf.endPDFPage(); pdf.closePDF()
        if rotated {
            let document = try #require(PDFDocument(url: url))
            document.page(at: 1)?.rotation = 180
            try #require(document.write(to: url))
        }
        return url
    }

    @Test(arguments: ["plain", "rotated", "mixed"])
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func `persistent scanned page renders actual geometry and explicit fallbacks`(scenario: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let rotated = scenario == "rotated", mixed = scenario == "mixed"
        let file = try fixture(root, rotated: rotated, mixed: mixed)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(timeout: 15); defer { reader.stop() }
        var status: SemanticFileStore.JobState = .partial
        for _ in 0 ..< 3 where status == .partial {
            status = try SemanticFileIndexer.index(file.path, scope: semanticScope(root.path), store: store,
                                                   reader: reader, encoder: SemanticFixtureEncoder(), media: nil,
                                                   cancelled: { false }, checkpoint: {}, waitForIdle: {})
        }
        #expect(status == .done)
        let hit = try #require(store.lexicalSearch(text: "INV-739204", query: .init("INV-739204"), type: .pdf,
                                                   scope: semanticScope(root.path), limit: 5,
                                                   cancelled: { false }).first)
        #expect(hit.evidence?.page == 2 && hit.evidence?.segmentKind == "pdf-ocr")
        #expect(hit.evidence?.chunkID != nil && hit.evidence?.text.contains("INV-739204") == true)
        let info = try await AskFilePreviewRenderer.metadata(hit, readText: false)
        #expect(info.version == hit.evidence?.version)
        let profiles = ProcessInfo.processInfo.environment["TYPEFLUX_PDF_PREVIEW_EVIDENCE"]
        let worker = MediaWorker(timeout: 3, run: { request, cancelled in
            var request = request
            if let profiles { request.environment["LLVM_PROFILE_FILE"] = profiles + "/helper-%p.profraw" }
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let pixels = CGSize(width: rotated ? 1040 : 720, height: 900)
        var content = try await AskFilePreviewRenderer.generate(hit, kind: .pdf, pixels: pixels,
                                                                info: info, worker: worker)
        content.fileSize = info.fileSize ?? 0
        #expect(content.imageTextLocated == true && content.pageNumbers == [2] && content.pageCount == 2)
        let image = try #require(content.images.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(image.width == Int(pixels.width) && image.height == Int(pixels.width * 0.75))
        let boxes = try MediaPreviewOCR.locate(image, passage: "INV-739204").boxes
        #expect(boxes.count == 1)
        let box = try #require(boxes.first)
        // CGPDF's aspect-fit transform does not upscale a page beyond its point size.
        // The 1040-pixel fixture therefore has centered margins around its 800-point page.
        let rasterSize = CGSize(width: image.width, height: image.height)
        let scale = min(1, min(rasterSize.width / 800, rasterSize.height / 600))
        let invoiceRegion = CGRect(x: (rasterSize.width - 800 * scale) / 2 + 300 * scale,
                                   y: (rasterSize.height - 600 * scale) / 2 + 350 * scale,
                                   width: 230 * scale, height: 50 * scale)
        #expect(invoiceRegion.contains(CGPoint(x: box.midX * rasterSize.width, y: box.midY * rasterSize.height)))
        let document = try #require(PDFDocument(url: file))
        let nativePrefix = document.page(at: 1)?.string ?? ""
        let geometry = try MediaPreviewOCR.locate(image, passage: hit.evidence?.text ?? "", prefix: nativePrefix)
        try verifyRaster(image, boxes: geometry.boxes)
        for variant in ["missing", "wrong-page", "invalid-page", "stale", "unversioned", "ambiguous"] {
            var changed = hit
            if variant == "missing" { changed.evidence?.text = "INV-NOT-PRESENT" }
            if variant == "wrong-page" { changed.evidence?.page = 1 }
            if variant == "invalid-page" { changed.evidence?.page = 99 }
            if variant == "stale" { changed.evidence?.version = "obsolete" }
            if variant == "unversioned" { changed.evidence?.version = nil }
            if variant == "ambiguous" { changed.evidence?.text = "e"; changed.evidence?.page = 1 }
            let fallback = try await AskFilePreviewRenderer.generate(changed, kind: .pdf, pixels: pixels,
                                                                     info: info, worker: worker)
            #expect(fallback.imageTextLocated == false)
            try verifyRaster(#require(fallback.images.first?.cgImage(forProposedRect: nil, context: nil, hints: nil)),
                             boxes: [], highlighted: false)
            if scenario == "plain", variant == "missing" {
                try await snapshot(fallback, hit: changed, prefix: "fallback")
            }
        }
        var native = hit
        native.evidence?.text = "Native reimbursement policy"; native.evidence?.page = 1
        let nativeContent = try await AskFilePreviewRenderer.generate(native, kind: .pdf, pixels: pixels,
                                                                      info: info, worker: worker)
        #expect(nativeContent.imageTextLocated == true && nativeContent.pageNumbers == [1])
        native.evidence?.segmentKind = "pdf-text"
        let legacy = try await AskFilePreviewRenderer.generate(native, kind: .pdf, pixels: pixels,
                                                               info: info, worker: worker)
        #expect(legacy.imageTextLocated == nil)
        let nativeImage = try #require(legacy.images.first?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let nativeBoxes = try MediaPreviewOCR.locate(nativeImage, passage: native.evidence?.text ?? "").boxes
        try verifyRaster(nativeImage, boxes: nativeBoxes)
        if scenario == "plain" { try await snapshot(content, hit: hit, prefix: "pdf") }
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_PDF_PREVIEW_EVIDENCE"] {
            let output = URL(fileURLWithPath: folder), name = scenario
            try Data(contentsOf: file).write(to: output.appendingPathComponent(name + ".pdf"))
            let evidence = try #require(hit.evidence)
            let record: [String: Any] = ["text": evidence.text, "page": evidence.page ?? 0,
                                         "kind": evidence.segmentKind ?? "", "version": evidence.version ?? "",
                                         "chunk": evidence.chunkID ?? 0]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name + "-evidence.json"))
            try JSONEncoder().encode(MediaTextGeometry(boxes: boxes))
                .write(to: output.appendingPathComponent(name + "-boxes.json"))
        }
    }

    private func verifyRaster(_ image: CGImage, boxes: [CGRect], highlighted: Bool = true) throws {
        let pixels = NSBitmapImageRep(cgImage: image)
        var yellow = 0, outside = 0
        for row in 0 ..< pixels.pixelsHigh {
            for column in 0 ..< pixels.pixelsWide {
                let color = try #require(pixels.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.95, color.greenComponent > 0.8, color.blueComponent < 0.85 {
                    yellow += 1
                    let point = CGPoint(x: (CGFloat(column) + 0.5) / CGFloat(image.width),
                                        y: 1 - (CGFloat(row) + 0.5) / CGFloat(image.height))
                    if !boxes.contains(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }) { outside += 1 }
                }
            }
        }
        #expect(highlighted ? yellow > 100 && outside == 0 : yellow == 0)
    }

    @Test func `PDF geometry is bound to one requested page and mixed prefix remains exact`() throws {
        var request = MediaRequest(operation: .previewPDF)
        request.preview = .init(width: 800, height: 600, page: 2, passage: "invoice", locatePDFText: true)
        var result = MediaPreviewResult(rasters: [.init(width: 800, height: 600, page: 2)], pages: 3)
        result.textGeometry = .init(boxes: [])
        try result.validate(for: request)
        for page in [nil, 1, 99] as [Int?] {
            request.preview?.page = page
            #expect(throws: MediaFailure.self) { try result.validate(for: request) }
        }
        request.preview?.page = 2; request.preview?.locatePDFText = nil
        #expect(throws: MediaFailure.self) { try result.validate(for: request) }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(PDFDocument(url: fixture(root, rotated: false)))
        let page = try #require(document.page(at: 1))
        let image = try #require(page.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let text = "INVOICE\nInvoice number INV-739204\nPayment due after approval"
        let located = try MediaPreviewOCR.locate(image, passage: "Native header\n" + text, prefix: "Native header")
        #expect(!located.boxes.isEmpty)
        let missing = try MediaPreviewOCR.locate(image, passage: "Unrelated header\n" + text, prefix: "Native header")
        #expect(missing.boxes.isEmpty)
    }
}
