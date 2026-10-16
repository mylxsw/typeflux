import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import Typeflux

private final class OCRReader: AskFileReading {
    var reads: [Int] = []
    var after: (() -> Void)?
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() {
            throw CancellationError()
        }
        let result = AskFileWorkerCommand.handle(request)
        if request.readText {
            reads.append(request.cursor?.page ?? 0)
            after?()
        }
        return result
    }
}

@Suite("Scanned PDF content and compatible upgrade", .serialized)
// swiftlint:disable:next type_body_length
struct SemanticPDFOCRTests {
    private func draw(_ text: String, in context: CGContext, y position: CGFloat) {
        context.textPosition = CGPoint(x: 30, y: position)
        let value = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString,
                28,
                nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }

    private func fixture(_ root: URL, nativeBody: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("invoice.pdf")
        var box = CGRect(x: 0, y: 0, width: 800, height: 600)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        draw("Project reimbursement handbook", in: pdf, y: 400)
        pdf.endPDFPage()
        let bitmap = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(box)
        draw("INVOICE", in: bitmap, y: 460)
        draw("Invoice number INV-739204", in: bitmap, y: 360)
        draw("Payment due after approval", in: bitmap, y: 260)
        pdf.beginPDFPage(nil)
        try pdf.draw(#require(bitmap.makeImage()), in: box)
        // A realistic native header must not prevent recognition of the raster body.
        draw("Typeflux Finance Department - Monthly Accounts", in: pdf, y: 550)
        draw("2", in: pdf, y: 40)
        if nativeBody {
            draw("Native reimbursement policy and approval", in: pdf, y: 420)
            draw("Submit complete receipts with the request", in: pdf, y: 330)
            draw("Finance reviews all payment information", in: pdf, y: 240)
        }
        pdf.endPDFPage(); pdf.closePDF()
        return url
    }

    private func index(_ file: URL, root: URL, store: SemanticFileStore, reader: AskFileReading,
                       encoder: SemanticEmbedding, cancelled: () -> Bool = { false }) throws -> SemanticFileStore
        .JobState {
        try SemanticFileIndexer.index(file.path, scope: semanticScope(root.path), store: store, reader: reader,
                                      encoder: encoder, media: nil, cancelled: cancelled, checkpoint: {},
                                      waitForIdle: {})
    }

    @Test func `real OCR runs in the reader and preserves page location across reader restart`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), document = try #require(PDFDocument(url: file))
        // PDFKit may expose system Live Text; the fixture draws the invoice body only into a bitmap.
        #expect(document.pageCount == 2)
        let scope = semanticScope(root.path), first = AskFileReader(timeout: 15)
        let native = try first.read(.init(operation: .content, path: file.path, scope: scope))
        #expect(native.pages?.first?.segmentKind == "pdf-text")
        #expect(native.nextCursor == .init(page: 1))
        first.stop()
        let restarted = AskFileReader(timeout: 15)
        defer { restarted.stop() }
        let scan = try restarted.read(.init(
            operation: .content,
            path: file.path,
            scope: scope,
            cursor: native.nextCursor
        ))
        #expect(scan.error == nil)
        #expect(scan.pages?.first?.text.hasPrefix("Typeflux Finance Department") == true)
        #expect(scan.pages?.first?.text.contains("INV-739204") == true)
        #expect(scan.pages?.first?.segmentKind == "pdf-ocr")
        #expect(scan.pages?.first?.page == 2 && scan.pages?.first?.offset == 0)
        #expect(scan.nextCursor == nil && scan.version == native.version)
        if let destination = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] {
            let folder = URL(fileURLWithPath: destination)
            try Data(contentsOf: file).write(to: folder.appendingPathComponent("synthetic-invoice.pdf"))
            let result: [String: Any] = ["text": scan.pages?.first?.text ?? "", "page": 2,
                                        "segment_kind": "pdf-ocr", "reader_restarted": true,
                                        "version_matches": scan.version == native.version]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("native-ocr-result.json"))
        }
        let finished = try restarted.read(.init(
            operation: .content,
            path: file.path,
            scope: scope,
            cursor: .init(page: 2)
        ))
        #expect(finished.pages == [])
    }

    @Test(arguments: [SemanticFileStore.documentProvenance,
                      SemanticFileStore.documentProvenance + ";pdf-vision-accurate-auto-2400-sparse8-v1"])
    // swiftlint:disable:next function_body_length
    func `PDF upgrade queues finished jobs reuses native vectors and resumes at scanned page`(oldRecipe: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), url = root.appendingPathComponent("index.sqlite")
        let metadata = AskFileWorkerCommand.handle(.init(operation: .content, path: file.path,
                                                         scope: semanticScope(root.path), readText: false))
        let native = AskFileWorkerCommand.handle(.init(
            operation: .content,
            path: file.path,
            scope: semanticScope(root.path)
        ))
        var store = try SemanticFileStore(url: url)
        let old = try store.prepareDocument(path: file.path, metadata: metadata)
        let oldChunks = try SemanticChunk.make(#require(native.pages))
            + [SemanticChunk(text: "obsoletelegacychunk", page: 99, startOffset: 0, endOffset: 19)]
        try store.publish(oldChunks, next: nil, job: old)
        let work = try store.vectorWork(old), id = try #require(work.first?.id)
        try store.publishVectors(work.map { _ in semanticVector() }, work: work, job: old)
        #expect(try store.finishDocument(old) == .done)
        try store.lock.withLock {
            try store.execute(
                "UPDATE jobs SET recipe=? WHERE path=?",
                [oldRecipe, file.path]
            )
            try store.execute(
                "UPDATE chunks SET provenance=? WHERE path=?",
                [oldRecipe, file.path]
            )
        }
        store = try SemanticFileStore(url: url)
        #expect(try store.nextWork(.document) == file.path, "completed discovery cannot hide the upgrade")
        try store.beginRun(reason: .startup, configuration: "synthetic-pdf-upgrade")
        let reader = OCRReader(), encoder = SemanticFixtureEncoder()
        #expect(try index(file, root: root, store: store, reader: reader, encoder: encoder) == .partial)
        #expect(encoder.calls == 0 && reader.reads == [0], "unchanged text is adopted without encoding")
        #expect(try store.runDiagnostics()?.counters["ftsChunks"] == 0)
        #expect(try store.runDiagnostics()?.counters["vectorReusedSegments"] == 1)
        #expect(try store.job(file.path)?.cursor == .init(page: 1))
        store = try SemanticFileStore(url: url)
        let resumed = OCRReader()
        #expect(try index(file, root: root, store: store, reader: resumed, encoder: encoder) == .done)
        #expect(resumed.reads == [1] && encoder.calls == 1)
        let hits = try store.lexicalSearch(text: "INV-739204", query: .init("INV-739204"), type: .pdf,
                                           scope: semanticScope(root.path), limit: 5, cancelled: { false })
        let evidence = try #require(hits.first?.evidence)
        #expect(evidence.text.contains("INV-739204") && evidence.page == 2)
        #expect(evidence.segmentKind == "pdf-ocr" && evidence.chunkID != nil)
        #expect(evidence.startOffset == 0 && evidence.endOffset != nil)
        #expect(try store.job(file.path)?.version == SemanticFileStore.version(metadata))
        let nativeHits = try store.lexicalSearch(text: "reimbursement", query: .init("reimbursement"), type: .pdf,
                                                 scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(nativeHits.first?.evidence?.chunkID == id)
        #expect(try store.lexicalSearch(text: "obsoletelegacychunk", query: .init("obsoletelegacychunk"), type: .pdf,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false }).isEmpty)
        let reads = resumed.reads
        #expect(try index(file, root: root, store: store, reader: resumed, encoder: encoder) == .done)
        #expect(encoder.calls == 1 && resumed.reads == reads, "unchanged upgraded PDFs do no extraction or encoding")
        try store.completeWork(file.path, more: false)
        #expect(try SemanticFileStore(url: url).nextWork(.document) == nil)
    }

    @Test func `encrypted PDFs fail with a durable password reason`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), locked = root.appendingPathComponent("locked.pdf")
        let document = try #require(PDFDocument(url: file))
        try #require(document.write(
            to: locked,
            withOptions: [.ownerPasswordOption: "synthetic-owner", .userPasswordOption: "synthetic-reader"]
        ))
        #expect(PDFDocument(url: locked)?.isLocked == true)
        let response = AskFileWorkerCommand.handle(.init(
            operation: .content,
            path: locked.path,
            scope: semanticScope(root.path)
        ))
        #expect(response.error == EAUTH)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        #expect(try index(locked, root: root, store: store, reader: OCRReader(), encoder: SemanticFixtureEncoder()) ==
            .skipped)
        #expect(try store.job(locked.path)?.reason == "password-required")
    }

    @Test func `PDF recipes leave text profiles unchanged and changed files cannot reuse old vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(SemanticFileStore.documentRecipe(root.path + "/a.txt") == SemanticFileStore.documentProvenance)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite")), path = root.path + "/a.PDF"
        let old = try store.prepareDocument(path: path, metadata: .init(fileSize: 10, modified: Date(), version: "old"))
        try store.publish([.init(text: "previous body", page: 1, startOffset: 0, endOffset: 13)], next: nil, job: old)
        try store.lock.withLock { try store.execute(
            "UPDATE jobs SET recipe=? WHERE path=?",
            [SemanticFileStore.documentProvenance, path]
        ) }
        let fresh = try store.prepareDocument(
            path: path,
            metadata: .init(fileSize: 10, modified: Date(), version: "new")
        )
        #expect(fresh.generation != old.generation && fresh.recipe.contains(SemanticPDFText.recipe))
        #expect(try store.counts().chunks == 0)
        #expect(try !store.publish([.init(text: "stale body", page: 1)], next: nil, job: old))
    }

    @Test func `cancellation after OCR cannot commit and permission withdrawal clears published content`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root), store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = OCRReader(), encoder = SemanticFixtureEncoder(), token = AskSearchCancellation()
        #expect(try index(file, root: root, store: store, reader: reader, encoder: encoder) == .partial)
        reader.after = { token.cancel() }
        #expect(throws: CancellationError.self) {
            try index(
                file,
                root: root,
                store: store,
                reader: reader,
                encoder: encoder,
                cancelled: { token.isCancelled }
            )
        }
        #expect(try store.job(file.path)?.cursor == .init(page: 1))
        #expect(encoder.calls == 1)
        reader.after = nil
        #expect(try index(file, root: root, store: store, reader: reader, encoder: encoder) == .done)
        var scope = semanticScope(root.path); scope.excludedPaths = [file.path]
        #expect(try SemanticFileIndexer.index(
            file.path,
            scope: scope,
            store: store,
            reader: reader,
            encoder: encoder,
            media: nil,
            cancelled: { false },
            checkpoint: {},
            waitForIdle: {}
        ) == .skipped)
        #expect(try store.counts().chunks == 0)
    }

    @Test func `text layers skip OCR sparse layers retain native text and recognition failures escape`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(PDFDocument(url: fixture(root)))
        let native = try SemanticPDFText.extract(#require(document.page(at: 0)), recognize: { _ in
            Issue.record("A healthy text layer must not invoke Vision"); return []
        })
        #expect(native.kind == "pdf-text")
        let page = try #require(document.page(at: 1))
        let sparse = try SemanticPDFText.extract(page, recognize: { image in
            #expect(image.width <= 2400 && image.height <= 2400)
            return ["INV-739204"]
        })
        #expect(sparse.kind == "pdf-ocr" && sparse.text.contains("2") && sparse.text.contains("INV-739204"))
        #expect(throws: AskFileReadError.self) {
            try SemanticPDFText.extract(page, recognize: { _ in throw AskFileReadError.unavailable })
        }
        let blank = PDFPage()
        let empty = try SemanticPDFText.extract(blank, recognize: { _ in [] })
        #expect(empty.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func `healthy native body over an image keeps original text without invoking OCR`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(PDFDocument(url: fixture(root, nativeBody: true)))
        let page = try #require(document.page(at: 1))
        let native = try SemanticPDFText.extract(page, recognize: { _ in
            Issue.record("Sufficient native body text must keep the fast path"); return []
        })
        #expect(native.kind == "pdf-text" && native.text == page.string)
    }

    // swiftlint:disable line_length
    @Test(arguments: [false, true])
    func `nested form image resources cannot be hidden by a native header`(inherited: Bool) throws {
        // A minimal PDF with a Form XObject containing another Form and a raster image.
        // The cycle is an unused resource, so resource traversal must terminate without rendering it.
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let content = "BT /F1 14 Tf 20 570 Td (Long native finance department header) Tj ET /Outer Do"
        func stream(_ dictionary: String, _ body: String) -> String {
            "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        let resources = "/Resources << /Font << /F1 4 0 R >> /XObject << /Outer 6 0 R >> >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] \(inherited ? resources : "") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 600] \(inherited ? "" : resources) /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream("", content),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 800 600] /Resources << /XObject << /Inner 7 0 R >> >>", "/Inner Do"),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 800 600] /Resources << /XObject << /Image 8 0 R /Cycle 6 0 R >> >>", "q 800 0 0 400 0 100 cm /Image Do Q"),
            stream("/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", "ff>")
        ]
        var data = "%PDF-1.4\n", offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.utf8.count); data += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = data.utf8.count
        data += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { data += String(format: "%010d 00000 n \n", offset) }
        data += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let document = try #require(PDFDocument(data: Data(data.utf8)))
        let page = try #require(document.page(at: 0))
        let result = try SemanticPDFText.extract(page, recognize: { _ in ["FORM-INVOICE-48291"] })
        #expect(result.kind == "pdf-ocr" && result.text.contains("FORM-INVOICE-48291"))
        #expect(result.text.hasPrefix("Long native finance department header"))
    }

    // swiftlint:enable line_length

    @Test(arguments: [EAUTH, EIO, EILSEQ])
    func `fixed extraction failures persist and retry without leaking content`(error: Int32) throws {
        final class FailedReader: AskFileReading {
            var error: Int32?
            func read(_ request: AskFileReadRequest, isCancelled _: () -> Bool) throws -> AskFileReadResponse {
                request.readText ? .init(error: error, fileSize: 10, modified: Date(timeIntervalSince1970: 1),
                                         pages: error == nil ? [.init(text: "Recovered invoice body", page: 1)] : nil)
                    : .init(fileSize: 10, modified: Date(timeIntervalSince1970: 1))
            }
        }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("broken.pdf"),
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = FailedReader(), encoder = SemanticFixtureEncoder(); reader.error = error
        #expect(try index(file, root: root, store: store, reader: reader, encoder: encoder) == .skipped)
        #expect(try store.job(file.path)?.state == .failed)
        #expect(try store.job(file.path)?
            .reason == (error == EAUTH ? "password-required" : error == EIO ? "pdf-ocr-failed" : "unreadable-content"))
        reader.error = nil
        #expect(try index(file, root: root, store: store, reader: reader, encoder: encoder) == .done)
        #expect(try store.job(file.path)?.attempts == 1)
    }
}
