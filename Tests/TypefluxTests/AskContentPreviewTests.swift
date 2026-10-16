import AppKit
import CoreText
import PDFKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Content match previews", .serialized, .exclusiveUIState)
@MainActor
struct AskContentPreviewTests {
    @Test func sameFileReloadsForADifferentPageOrPassageButNotForRank() {
        let clock = PreviewTestClock(), loader = PreviewTestLoader()
        let controller = AskFilePreviewController(loader: loader, clock: clock)
        var hit = previewHit("report.pdf")
        hit.evidence = .init(text: "reimbursement", page: 4)
        controller.request(hit); clock.advance(0.12)
        #expect(loader.requests.count == 1)
        loader.completions[0](.init(kind: .pdf, pageCount: 8, pageNumbers: [4]))
        hit.score = 99; controller.request(hit)
        #expect(loader.requests.count == 1)
        hit.evidence = .init(text: "annual expenses", page: 6)
        controller.request(hit); clock.advance(0.12)
        #expect(loader.requests.count == 2)
        loader.completions[0](.init(kind: .pdf, pageCount: 8, pageNumbers: [4]))
        loader.completions[1](.init(kind: .pdf, pageCount: 8, pageNumbers: [6]))
        #expect(controller.state.content?.pageNumbers == [6])
        hit.evidence?.text = "different passage"; controller.request(hit); clock.advance(0.12)
        #expect(loader.requests.count == 3)
        controller.dismissNow()
    }

    @Test func previewCacheSeparatesMatchedPagesAndText() async {
        var generated = 0
        let loader = AskFilePreviewLoader(metadata: { _, _ in .init(fileSize: 20, modified: .distantPast) },
            generate: { hit, kind, _, _ in
                generated += 1
                return .init(kind: kind, pageCount: 8, pageNumbers: [hit.evidence?.page ?? 1])
            })
        var hit = previewHit("report.pdf"), last: AskFilePreviewContent?
        let pixels = CGSize(width: 300, height: 400)
        loader.load(hit, pixels: pixels) { last = $0 }; await AskFilePreviewLoaderTests().settle()
        loader.load(hit, pixels: pixels) { last = $0 }; await AskFilePreviewLoaderTests().settle()
        #expect(generated == 1)
        hit.evidence = .init(text: "matched text", page: 4)
        loader.load(hit, pixels: pixels) { last = $0 }; await AskFilePreviewLoaderTests().settle()
        #expect(generated == 2 && last?.pageNumbers == [4])
        hit.evidence?.page = 6
        loader.load(hit, pixels: pixels) { last = $0 }; await AskFilePreviewLoaderTests().settle()
        #expect(generated == 3 && last?.pageNumbers == [6])
        hit.evidence?.text = "another match"
        loader.load(hit, pixels: pixels) { last = $0 }; await AskFilePreviewLoaderTests().settle()
        #expect(generated == 4)
        loader.cancel()
    }

    @Test func pdfMatchUsesTheActualPageAndDrawsHighlights() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Expense policy.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let writer = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 1 ... 6 {
            writer.beginPDFPage(nil); writer.textPosition = CGPoint(x: 30, y: 380)
            let text = index == 4 ? "Project reimbursement policy" : "Page \(index): unrelated material"
            let line = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, 16, nil
                )
            ])
            CTLineDraw(CTLineCreateWithAttributedString(line), writer); writer.endPDFPage()
        }
        writer.closePDF()
        let pixels = CGSize(width: 500, height: 600)
        let matched = try AskFilePreviewPDF.render(url, pixels: pixels,
            evidence: .init(text: "Project reimbursement policy", page: 4), cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3))
        let plain = try AskFilePreviewPDF.render(url, pixels: pixels,
            evidence: .init(text: "", page: 4), cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3))
        #expect(matched.numbers == [4] && matched.pages == 6 && matched.images.count == 1)
        let highlightedData = try #require(matched.images[0].dataProvider?.data) as Data
        let plainData = try #require(plain.images[0].dataProvider?.data) as Data
        #expect(highlightedData != plainData)
        #expect(try AskFilePreviewPDF.render(url, pixels: pixels, evidence: nil,
            cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3)).numbers == [1, 2, 3])
        #expect(try AskFilePreviewPDF.render(url, pixels: pixels, evidence: .init(text: "absent", page: 99),
            cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3)).numbers == [1, 2, 3])
        #expect(throws: (any Error).self) {
            try AskFilePreviewPDF.render(url, pixels: .zero, evidence: nil, cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3))
        }
        let cancelled = AskSearchCancellation(); cancelled.cancel()
        #expect(throws: (any Error).self) {
            try AskFilePreviewPDF.render(url, pixels: pixels, evidence: nil, cancellation: cancelled, worker: MediaWorker(timeout: 3))
        }
        #expect(throws: (any Error).self) {
            try AskFilePreviewPDF.render(root, pixels: pixels, evidence: nil, cancellation: AskSearchCancellation(), worker: MediaWorker(timeout: 3))
        }
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let state = AskFilePreviewState()
        var hit = previewHit("Expense policy.pdf"); hit.path = url.path
        hit.evidence = .init(text: "Project reimbursement policy", page: 4); state.hit = hit
        state.content = .init(kind: .pdf, images: matched.images.map { NSImage(cgImage: $0, size: .zero) },
                              pageCount: 6, pageNumbers: [4], fileSize: 4096)
        state.detail = state.content?.detail
        // Native glass is composited outside cacheDisplay; use the app's opaque classic appearance.
        try await SemanticFileSearchVisualTests.render(AskFilePreviewView(state: state)
            .environment(\.interfaceStyle, .classic).frame(width: 360, height: 600),
            width: 360, name: "pdf-match")
    }

    @Test func whitespaceNormalizationKeepsUnicodePDFOffsets() {
        let text = "😀 项目\n报销　流程"
        let range = AskFilePreviewPDF.ranges(in: text, passage: "项目 报销流程")
        #expect(range.count == 1)
        #expect(range.first.map { (text as NSString).substring(with: $0) } == "项目\n报销　流程")
        #expect(AskFilePreviewPDF.ranges(in: "Café", passage: "CAFE") == [NSRange(location: 0, length: 4)])
        #expect(AskFilePreviewPDF.ranges(in: text, passage: "missing").isEmpty)
        #expect(AskFilePreviewPDF.ranges(in: text, passage: " \n").isEmpty)
    }

    @Test func mediaPreviewStartsAtTheMatchedSegment() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("recording.wav")
        let samples = [Float](repeating: 0.5, count: 31 * 16000)
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: audio) }
        var hit = previewHit("recording.wav"); hit.path = audio.path
        hit.evidence = .init(text: "", page: nil, time: 30)
        let content = try await AskFilePreviewRenderer.generate(hit, kind: .audio,
            pixels: CGSize(width: 300, height: 200), info: .init(), worker: MediaWorker(timeout: 3))
        #expect(content.startTime == 30 && content.duration == 31)
        #expect(content.waveform.contains { $0 > 0 })
        let movie = root.appendingPathComponent("clip.mov")
        try await semanticTestMovie(movie)
        hit.path = movie.path; hit.evidence?.time = 1
        let frame = try await AskFilePreviewRenderer.generate(hit, kind: .video,
            pixels: CGSize(width: 300, height: 200), info: .init(), worker: MediaWorker(timeout: 3))
        #expect(frame.startTime == 1 && frame.images.count == 1)
    }

    @Test func contentSearchProgressIsAQuietNonSelectableRow() async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let hit = previewHit("Expense policy.pdf")
        var results = try #require(AskQuickResults.assemble("policy", matches: [], hits: [hit], status: nil,
                                                          settings: .init()))
        let rows = results.rows, height = AskQuickResultsView.height(for: results)
        results.searchingContent = true
        #expect(results.rows == rows)
        #expect(AskQuickResultsView.height(for: results) == height + 30)
        try await SemanticFileSearchVisualTests.render(AskQuickResultsView(results: results, question: "policy",
            thumbnails: false, onRun: { _, _ in }, onHighlight: { _ in }), width: 680, name: "content-search-pending")
    }
}
