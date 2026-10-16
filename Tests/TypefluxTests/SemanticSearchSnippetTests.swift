import Foundation
import Testing
@testable import Typeflux
import TypefluxMediaProtocol

@Suite("Matching passage evidence")
struct SemanticSearchSnippetTests {
    @Test func `snippets prefer identifiers and phrases and retain bounded Unicode context`() {
        #expect(SemanticSearchSnippet.make("short text", ranking: .init("missing")) == "short text")
        let prefix = String(repeating: "ordinary notes ", count: 35)
        for (body, query, expected) in [
            ("INV-739204 approved", "invoice INV-739204", "INV-739204"),
            ("ＴＳ-９００１ failure", "TS-9001", "ＴＳ-９００１"),
            ("项目报销流程已确认", "报销流程", "报销流程"),
            ("CAFÉ approvals", "cafe", "CAFÉ"),
            ("final approved invoice", "\"approved invoice\"", "approved invoice")
        ] {
            let snippet = SemanticSearchSnippet.make(prefix + body, ranking: .init(query))
            #expect(snippet.contains(expected) && snippet.count <= 180)
            #expect(!MediaPreviewText.ranges(in: prefix + body, passage: snippet).isEmpty)
        }
        let fallback = SemanticSearchSnippet.make(prefix, ranking: .init("unmatched"))
        #expect(fallback == String(prefix.prefix(180)))
        let head = SemanticSearchSnippet.make("needle " + prefix, ranking: .init("needle"))
        #expect(head.hasPrefix("needle") && head.count <= 180)
        let exact = SemanticSearchSnippet.make("INV-7392040 unrelated " + prefix + "true INV-739204 approved",
                                               ranking: .init("INV-739204"))
        #expect(exact.contains("true INV-739204 approved") && !exact.contains("INV-7392040"))
    }

    @Test func `lexical and vector channels preserve chunk identity and full offsets around a late match`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path + "/scan.pdf",
            store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let text = String(repeating: "项目说明 ", count: 80) + "INV-739204 final approval"
        let job = try store.prepareDocument(path: path, metadata: .init(fileSize: 10, modified: Date(), version: "v1"))
        try store.publish(
            [.init(text: text, page: 4, startOffset: 100, endOffset: 1100, segmentKind: "pdf-ocr")],
            next: nil,
            job: job
        )
        let work = try store.vectorWork(job)
        try store.publishVectors(work.map { _ in semanticVector() }, work: work, job: job)
        #expect(try store.finishDocument(job) == .done)
        let scope = semanticScope(root.path), query = AskSearchQuery("INV-739204")
        let lexical = try store.lexicalSearch(
            text: query.text,
            query: query,
            type: .all,
            scope: scope,
            limit: 5,
            cancelled: { false }
        )
        let vector = try store.search(
            vector: semanticVector(),
            text: query.text,
            query: query,
            type: .all,
            scope: scope,
            limit: 5,
            cancelled: { false }
        )
        let first = try #require(lexical.first?.evidence), second = try #require(vector.first?.evidence)
        #expect(first == second)
        #expect(first.text.contains("INV-739204") && first.text.count <= 180)
        #expect(first.chunkID == work.first?.id && first.page == 4 && first.segmentKind == "pdf-ocr")
        #expect(first.startOffset == 100 && first.endOffset == 1100 && first.version == "v1")
        let names = [AskFileHit(path: path, name: "scan.pdf", kind: .file, modified: Date(), score: 1)]
        #expect(SemanticFilePolicy.merge(names, lexical, limit: 5).first?.evidence == first)
    }
}
