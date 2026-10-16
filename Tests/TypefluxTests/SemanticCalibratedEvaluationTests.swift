// Nested capture DTOs mirror the frozen JSON fixture schema.
import Foundation
import Testing
@testable import Typeflux

@Suite("Frozen semantic ranking quality", .serialized)
struct SemanticCalibratedEvaluationTests {
    struct Captured: Decodable {
        var documents: [SemanticSearchEvaluationTests.Fixture.Document]
        var queries: [SemanticSearchEvaluationTests.Fixture.Query]
        var vectors: [[Float]]
        // Keep the frozen capture key verbatim.
        // swiftlint:disable:next identifier_name
        var query_vectors: [String: [Float]]
    }

    struct Holdout: Decodable { var queries: [SemanticSearchEvaluationTests.Fixture.Query] }

    @Test func `fixed oracle labels include both translation directions and a separate new query holdout`() throws {
        let folder = SemanticSearchEvaluationTests.repository
            .appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let holdout = try JSONDecoder().decode(
            Holdout.self,
            from: Data(contentsOf: folder.appendingPathComponent("holdout-queries.json"))
        )
        let captured = try JSONDecoder().decode(
            Captured.self,
            from: Data(contentsOf: folder.appendingPathComponent("raw-quality-vectors.json"))
        )
        #expect(holdout.queries.count == 200 && captured.queries.count == 200)
        #expect(Set(holdout.queries.map(\.id)).count == 200)
        let documents = Dictionary(uniqueKeysWithValues: captured.documents.map { ($0.id, $0.text) })
        for query in holdout.queries {
            #expect(query.expected.allSatisfy { documents[$0]?.contains(query.anchor ?? "") == true })
        }
        #expect(holdout.queries.filter { $0.group == "english_to_chinese" }.count == 25)
        #expect(holdout.queries.filter { $0.group == "chinese_to_english" }.count == 25)
    }

    @Test func `production ranker replays every captured real vector without hidden fixture omissions`() throws {
        let folder = SemanticSearchEvaluationTests.repository
            .appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let captured = try JSONDecoder().decode(
            Captured.self,
            from: Data(contentsOf: folder.appendingPathComponent("raw-quality-vectors.json"))
        )
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for (document, vector) in zip(captured.documents, captured.vectors) {
            try store.replace(path: root.path + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        var rows: [[String: Any]] = []
        for query in captured.queries {
            let hits = try store.search(vector: #require(captured.query_vectors[query.id]), text: query.query,
                                        query: .init(query.query), type: .all, scope: semanticScope(root.path),
                                        limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }.map { $0 + 1 }
            rows.append(["id": query.id, "group": query.group, "rank": rank as Any? ?? NSNull(), "hits": ids])
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows, "queries": captured.queries.count,
                                                    "indexed_documents": captured.documents.count,
                                                    "model_sha256": SemanticModel.sha256,
                                                    "scope": """
                                                    Production SQLite migration, Float16 pages and ranking over captured real model vectors. No model execution, file extraction, permissions or UI in this replay.
                                                    """] as [
                                       String: Any
                                   ],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("production-oracle-replay.json"))
    }

    @Test func `new wording holdout uses a freshly loaded real model when requested`() throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_HOLDOUT_MODEL"] else { return }
        let folder = SemanticSearchEvaluationTests.repository
            .appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let captured = try JSONDecoder().decode(
            Captured.self,
            from: Data(contentsOf: folder.appendingPathComponent("raw-quality-vectors.json"))
        )
        let holdout = try JSONDecoder().decode(
            Holdout.self,
            from: Data(contentsOf: folder.appendingPathComponent("holdout-queries.json"))
        )
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let encoder = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: URL(fileURLWithPath: model))
        defer { encoder.stop() }
        for document in captured.documents {
            let vector = try encoder
                .embed(["title: \(document.id).txt | text: " + document.text], cancelled: { false })[0]
            try store.replace(path: root.path + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        var rows: [[String: Any]] = []
        for query in holdout.queries {
            // Independent request for every ID, including duplicate wording for bilingual labels.
            let vector = try encoder.embed(["task: search result | query: " + query.query], cancelled: { false })[0]
            let hits = try store.search(vector: vector, text: query.query, query: .init(query.query), type: .all,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }.map { $0 + 1 }
            rows.append(["id": query.id, "group": query.group, "rank": rank as Any? ?? NSNull(), "hits": ids])
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows, "queries": holdout.queries.count,
                                                    "indexed_documents": captured.documents.count,
                                                    "model_sha256": SemanticModel.sha256,
                                                    "scope": """
                                                    New wording holdout; fresh real model embeddings and production store/ranker. Shared source facts. No extraction or UI in this quality harness.
                                                    """] as [
                                       String: Any
                                   ],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("production-holdout.json"))
    }

    struct MediaCapture: Decodable {
        // swiftlint:disable:next nesting
        struct Document: Decodable {
            var id: String; var kind: String; var text: String; var vector: [Float]; var duration: Double
        }

        // swiftlint:disable:next nesting
        struct Query: Decodable {
            var id: String; var group: String; var query: String; var expected: [String]; var vector: [Float]
        }

        var documents: [Document]
        var queries: [Query]
    }

    @Test func `real media vectors compete with text in the production ranker`() throws {
        let folder = SemanticSearchEvaluationTests.repository
            .appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let captured = try JSONDecoder().decode(
            Captured.self,
            from: Data(contentsOf: folder.appendingPathComponent("raw-quality-vectors.json"))
        )
        let media = try JSONDecoder().decode(
            MediaCapture.self,
            from: Data(contentsOf: folder.appendingPathComponent("captured-media.json"))
        )
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for (document, vector) in zip(captured.documents, captured.vectors) {
            try store.replace(path: root.path + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        for document in media.documents {
            let path = root.path + "/" + document.id + (document.kind == "audio" ? ".wav" : ".png")
            let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: document.id)
            let generation = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                       input: .init(kind: document.kind == "audio" ? .audio : .image,
                                                    path: path, time: 0, endTime: document.duration),
                                       vector: document.vector)
            #expect(try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1))
        }
        var rows: [[String: Any]] = []
        for query in media.queries {
            let hits = try store.search(vector: query.vector, text: query.query, query: .init(query.query), type: .all,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }.map { $0 + 1 }
            let location = hits.first { query.expected.contains(($0.name as NSString).deletingPathExtension) }?
                .evidence?.time
            rows.append(["id": query.id, "group": query.group, "rank": rank as Any? ?? NSNull(), "hits": ids,
                         "location_correct": location == 0])
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows, "queries": media.queries.count,
                                                    "text_documents": captured.documents.count,
                                                    "media_documents": media.documents.count,
                                                    "model_sha256": SemanticModel.sha256,
                                                    "projector_sha256": SemanticMediaModel.sha256,
                                                    "scope": """
                                                    Real captured image/audio/text vectors through production staging/provenance, Float16 snapshot and ranking. Each source clip has one labelled segment starting at zero. File extraction/permissions/UI are not measured in this replay.
                                                    """] as [
                                       String: Any
                                   ],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("production-media.json"))
    }

    @Test(arguments: ["final-holdout", "unseen-query"])
    // Save every row before checking the gates.
    // swiftlint:disable:next function_body_length
    func `frozen mixed corpus clears relevance and rejection gates`(fixture: String) throws {
        let folder = SemanticSearchEvaluationTests.repository
            .appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let media = try JSONDecoder().decode(
            MediaCapture.self,
            from: Data(contentsOf: folder.appendingPathComponent("\(fixture)-vectors.json"))
        )
        #expect(media.documents.count == 100 && media.queries.count == 200)
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for document in media.documents {
            if document.kind == "text" {
                try store.replace(path: root.path + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                                  chunks: [.init(text: document.text, page: nil)], vectors: [document.vector])
            } else {
                let path = root.path + "/" + document.id + (document.kind == "audio" ? ".wav" : ".png")
                let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: document.id)
                let generation = try store.beginMediaJob(path: path, metadata: metadata)
                try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                           input: .init(
                                               kind: document.kind == "audio" ? .audio : .image,
                                               path: path,
                                               time: 0,
                                               endTime: document.duration
                                           ), vector: document.vector)
                #expect(try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1))
            }
        }
        var rows: [[String: Any]] = []
        // Keep each group denominator beside its two outcome counters.
        // swiftlint:disable:next large_tuple
        var groups: [String: (count: Int, correct: Int, falsePositive: Int)] = [:]
        for query in media.queries {
            let hits = try store.search(vector: query.vector, text: query.query, query: .init(query.query), type: .all,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }.map { $0 + 1 }
            var group = groups[query.group] ?? (0, 0, 0)
            group.count += 1; group.correct += rank == nil ? 0 : 1
            group.falsePositive += query.expected.isEmpty && !hits.isEmpty ? 1 : 0
            groups[query.group] = group
            rows.append(["id": query.id, "group": query.group, "rank": rank as Any? ?? NSNull(), "hits": ids,
                         "expected": query.expected])
        }
        // Save every row before asserting a gate; a failing evaluation must remain reviewable.
        try JSONSerialization.data(withJSONObject: ["rows": rows, "queries": media.queries.count,
                                                    "indexed_documents": media.documents.count,
                                                    "model_sha256": SemanticModel.sha256,
                                                    "projector_sha256": SemanticMediaModel.sha256,
                                                    "scope": """
                                                    Frozen 100-source mixed corpus: 50 text documents, 25 generated speech clips, 25 colour/shape images. final-holdout queries are a retained regression after the initial failed evaluation; unseen-query is new wording on those fixed source facts, frozen after the initial failed evaluation and evaluated only after development-only corrections. Real captured model vectors and production media staging/ranker. No extraction/permission/UI latency claim.
                                                    """] as [
                                       String: Any
                                   ],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("production-\(fixture).json"))
        for (name, group) in groups {
            #expect(group.count == 25)
            if name == "no_answer" {
                #expect(Double(group.falsePositive) / Double(group.count) <= 0.05, "No-answer false-positive gate")
            } else {
                #expect(Double(group.correct) / Double(group.count) >= 0.85, "Recall@5 gate for \(name)")
            }
        }
    }
}
