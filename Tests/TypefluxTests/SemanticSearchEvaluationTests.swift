import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic query oracle", .serialized)
struct SemanticSearchEvaluationTests {
    struct Fixture: Decodable {
        struct Document: Decodable { var id: String; var kind: String; var text: String }
        struct Query: Decodable {
            var id: String; var group: String; var query: String; var expected: [String]; var anchor: String?
        }

        var documents: [Document]
        var queries: [Query]
    }

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.repository
                .appendingPathComponent("docs/validation/gul-383/optimization/queries.json")))
    }

    @Test func `labels have source anchors and unsupported groups remain in the denominator`() throws {
        let fixture = try fixture(), documents = Dictionary(uniqueKeysWithValues: fixture.documents.map { ($0.id, $0) })
        #expect(fixture.queries.count >= 200 && Set(fixture.queries.map(\.id)).count == fixture.queries.count)
        for query in fixture.queries {
            #expect(query.expected.allSatisfy { documents[$0]?.text.contains(query.anchor ?? "") == true })
            #expect(query.expected.isEmpty == (query.group == "no_answer"))
        }
        #expect(Set(fixture.queries.map(\.group)).count == 8)
        #expect(fixture.queries.filter { ["long_tail", "scanned", "media_timestamp"].contains($0.group) }.count == 75)
    }

    @Test func `evaluate with real model when explicitly requested`() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_EVAL_MODEL"] else { return }
        let fixture = try fixture(), root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("eval.sqlite"))
        let worker = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: URL(fileURLWithPath: model))
        defer { worker.stop() }
        for document in fixture.documents where document.kind == "text" {
            let vector = try worker
                .embed(["title: \(document.id).txt | text: " + document.text], cancelled: { false })[0]
            try store.replace(path: root.path + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        // This text-only harness inserts 50 real model vectors. Known long-tail/OCR gaps and unmeasured media
        // fixtures remain absent and count as failures; this is not a claim that the product lacks media embeddings.
        var rows: [[String: Any]] = []
        let lifecycle = AskSearchCancellation()
        for query in fixture.queries {
            let vector = try await worker.query(query.query, lifecycle: lifecycle)
            let hits = try store.search(vector: vector, text: query.query, query: .init(query.query), type: .all,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }.map { $0 + 1 }
            rows.append(["id": query.id, "group": query.group, "rank": rank as Any? ?? NSNull(),
                         "hits": ids, "answerable": !query.expected.isEmpty])
        }
        let report: [String: Any] = ["model_sha256": SemanticModel.sha256, "queries": fixture.queries.count,
                                     "indexed_documents": 50, "rows": rows,
                                     "missing_or_unmeasured_baseline_fixtures": 75,
                                     "note": "Synthetic single-source regression oracle, not representative relevance quality. Only 50 text fixtures are indexed; long-tail/OCR gaps and unmeasured media remain failures in the full denominator. Production Store and real helper; no UI."]
        let output = Self.repository.appendingPathComponent("docs/validation/gul-383/optimization/evaluation.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
