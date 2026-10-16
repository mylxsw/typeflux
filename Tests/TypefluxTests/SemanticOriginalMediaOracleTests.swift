import Foundation
import Testing
@testable import Typeflux

@Suite("Original oracle with actual supported media inputs", .serialized)
struct SemanticOriginalMediaOracleTests {
    @Test func `retain original denominators while filling supported media fixtures when requested`() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let assets = env["TYPEFLUX_ORIGINAL_CORPUS"], let model = env["TYPEFLUX_ORIGINAL_MODEL"],
              let projector = env["TYPEFLUX_ORIGINAL_PROJECTOR"],
              let helper = env["TYPEFLUX_ORIGINAL_HELPER"] else { return }
        let root = try semanticFixture(), corpus = root.appendingPathComponent("corpus")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: assets),
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.copyItem(at: file, to: corpus.appendingPathComponent(file.lastPathComponent))
        }
        let fixture = try SemanticSearchEvaluationTests().fixture()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let modelURL = URL(fileURLWithPath: model), helperURL = URL(fileURLWithPath: helper)
        try SemanticModel.verify(modelURL)
        try SemanticModel.verify(
            URL(fileURLWithPath: projector),
            bytes: SemanticMediaModel.bytes,
            sha256: SemanticMediaModel.sha256
        )
        let cpuSources = env["TYPEFLUX_ORIGINAL_CPU"] == "1"
        let encoder = SemanticEmbeddingWorker(helper: helperURL, model: modelURL, indexing: cpuSources)
        let media = SemanticEmbeddingWorker(
            helper: helperURL,
            model: modelURL,
            indexing: cpuSources,
            projector: URL(fileURLWithPath: projector),
            timeout: 120,
            startupTimeout: 180
        )
        defer { encoder.release(); media.release() }
        let reader = AskFileReader(), scope = semanticScope(corpus.path)
        let indexingStarted = ProcessInfo.processInfo.systemUptime
        let result = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
                                                 media: media, cancelled: { false }, progress: { _ in })
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexingStarted
        encoder.release(); media.release()
        let queryEncoder = SemanticEmbeddingWorker(helper: helperURL, model: modelURL)
        defer { queryEncoder.release() }
        var rows: [[String: Any]] = []
        let lifecycle = AskSearchCancellation()
        for query in fixture.queries {
            let vector = try await queryEncoder.query(query.query, lifecycle: lifecycle)
            let hits = try store.search(vector: vector, text: query.query, query: .init(query.query), type: .all,
                                        scope: scope, limit: 5, cancelled: { false })
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { query.expected.contains($0) }
            var location = false
            if let rank {
                let expected = fixture.documents.first { $0.id == ids[rank] }
                if expected?.kind == "video" {
                    let original = try JSONSerialization
                        .jsonObject(with: Data(contentsOf: SemanticSearchEvaluationTests.repository
                                .appendingPathComponent(
                                    "docs/validation/gul-383/optimization/queries.json"
                                ))) as? [String: Any]
                    let source = (original?["documents"] as? [[String: Any]])?
                        .first { $0["id"] as? String == ids[rank] }
                    if let anchor = source?["time"] as? Double, let time = hits[rank].evidence?.time {
                        location = time <= anchor && anchor < time + 30
                    }
                } else {
                    location = true
                }
            }
            rows.append(["id": query.id, "group": query.group, "expected": query.expected, "hits": ids,
                         "rank": rank.map { $0 + 1 } as Any? ?? NSNull(), "location_correct": location,
                         "hit_times": hits.map { $0.evidence?.time as Any? ?? NSNull() }])
        }
        let report: [String: Any] = try [
            "rows": rows,
            "indexing_seconds": indexSeconds,
            "files_processed": result.files,
            "skipped": result.skipped,
            "chunks": store.counts().chunks,
            "source_backend": cpuSources ? "cpu-one-thread" : "gpu",
            "query_backend": "gpu",
            "scope": "Real native extraction, actual MOV/PCM speech and pinned embeddings through the production indexer/store. Controlled unpaced encoder to isolate quality; not production background resource or UI evidence. Original 175-positive denominator retained, including 25 unsupported scanned PDF failures. Timestamp correctness means the original speech start lies within the returned 30-second window."
        ]
        let label = env["TYPEFLUX_SEMANTIC_LABEL"] ?? "after"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: SemanticSearchEvaluationTests.repository
                .appendingPathComponent(
                    "docs/validation/gul-383/optimization/ranking-scale/rework-original-\(label).json"
                ))
    }
}
