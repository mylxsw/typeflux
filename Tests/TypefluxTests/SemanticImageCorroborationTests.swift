import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Retained screenshot visual and OCR corroboration", .serialized)
struct SemanticImageCorroborationTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let capture = repository.appendingPathComponent(
        "docs/validation/gul-383/optimization/media-isolation/visual-diagnosis/fixed-capture"
    )
    let text = "black text on a white background"
    let corpus = "/gul405-synthetic/corpus"

    func fixture() throws -> (URL, SemanticFileStore) {
        let root = try semanticFixture()
        let url = root.appendingPathComponent("semantic-files.sqlite")
        try FileManager.default.copyItem(at: Self.capture.appendingPathComponent("synthetic.sqlite"), to: url)
        return try (root, SemanticFileStore(url: url))
    }

    func vector() throws -> [Float] {
        try JSONDecoder().decode(
            [Float].self,
            from: Data(contentsOf: Self.capture.appendingPathComponent("query-vector.json"))
        )
    }

    func search(_ store: SemanticFileStore, query: String? = nil, vector: [Float]? = nil) throws -> [AskFileHit] {
        let query = query ?? text
        return try store.search(vector: vector ?? self.vector(), text: query, query: .init(query), type: .all,
                                scope: semanticScope(corpus), limit: 5, cancelled: { false })
    }

    @Test func `retained real vectors select visual evidence before and after reopen`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for current in try [store, SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))] {
            let hits = try search(current)
            #expect(hits.count == 1)
            let hit = try #require(hits.first)
            #expect(hit.evidence?.segmentKind == "image" && hit.evidence?.chunkID == 1)
            #expect(abs(hit.score - 0.381613326) < 0.00001)
            #expect(hit.evidence?.version != nil)
        }
    }

    @Test(arguments: ["image", "image-ocr"])
    func `one modality and its repeated chunks cannot supply independent support`(kind: String) throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("DELETE FROM chunks WHERE segment_kind<>?", [kind])
        // Cross page boundaries and retain a single file: chunk count must not change confidence.
        for _ in 0 ..< 300 {
            try store.sql("""
            INSERT INTO chunks(path,text,vector,modality,segment_kind,provenance,search_script)
            SELECT path,text,vector,modality,segment_kind,provenance,search_script FROM chunks LIMIT 1
            """)
        }
        #expect(try search(store).isEmpty)
    }

    @Test func `duplicate OCR across pages leaves the same visual winner`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0 ..< 300 {
            try store.sql("""
            INSERT INTO chunks(path,text,vector,modality,segment_kind,provenance,search_script)
            SELECT path,text,vector,modality,segment_kind,provenance,search_script FROM chunks WHERE id=2
            """)
        }
        #expect(try search(store).first?.evidence?.chunkID == 1)
    }

    @Test(arguments: ["provenance", "segment_kind", "vector", "version"])
    func `incompatible or malformed OCR cannot corroborate`(field: String) throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        if field == "version" {
            try store.sql("UPDATE files SET version=''")
        } else if field == "vector" {
            try store.execute("UPDATE chunks SET vector=? WHERE id=2", [Data(repeating: 0, count: 768 * 4)])
        } else {
            try store.execute("UPDATE chunks SET \(field)=? WHERE id=2", ["incompatible"])
        }
        #expect(try search(store).isEmpty)
    }

    @Test func `different files cannot lend each other a modality`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.sql("""
        INSERT INTO files(path,modified,bytes,version)
        SELECT '/gul405-synthetic/corpus/second.png',modified,bytes,version FROM files LIMIT 1
        """)
        // Equal sub-threshold raw scores also remove the existing distinct-file margin fallback.
        try store.sql("""
        UPDATE chunks SET path='/gul405-synthetic/corpus/second.png',
            vector=(SELECT vector FROM chunks WHERE id=1) WHERE id=2
        """)
        #expect(try search(store).isEmpty)
    }

    @Test func `OCR exact identifiers and quotes still require actual lexical evidence`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for query in ["ERR-739204", "\"Connection failed\""] {
            #expect(try search(store, query: query).first?.evidence?.segmentKind == "image-ocr")
        }
        for query in ["ERR-739205", "\"Connection succeeded\""] {
            #expect(try search(store, query: query).isEmpty)
        }
        let blocked = try store.search(vector: vector(), text: text, query: .init(text), type: .all,
                                       scope: semanticScope("/elsewhere"), limit: 5, cancelled: { false })
        #expect(blocked.isEmpty)
        #expect(throws: CancellationError.self) {
            try store.search(vector: vector(), text: text, query: .init(text), type: .all,
                             scope: semanticScope(corpus), limit: 5, cancelled: { true })
        }
    }

    @Test func `original correct and incorrect color pairs retain the absolute gate`() throws {
        let folder = Self.repository.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let source = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.MediaCapture.self,
                                              from: Data(contentsOf: folder
                                                  .appendingPathComponent("captured-media.json")))
        let docs = source.documents.filter { $0.kind == "image" }
        let queries = source.queries.filter { $0.group == "image" }
        var count = 0
        for doc in docs {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let store = try SemanticFileStore(url: root.appendingPathComponent("color.sqlite"))
            let path = root.path + "/" + doc.id + ".png"
            let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: "color")
            let generation = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                       input: .init(kind: .image, path: path, time: 0, endTime: 0), vector: doc.vector)
            try #require(try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1))
            for query in queries {
                let hits = try store.search(vector: query.vector, text: query.query,
                                            query: .init(query.query), type: .image, scope: semanticScope(root.path),
                                            limit: 5,
                                            cancelled: { false })
                #expect(!hits.isEmpty == query.expected.contains(doc.id))
                count += 1
            }
        }
        #expect(count == 12)
    }

    // Keep each frozen oracle row and its original group together in one replay.
    // swiftlint:disable:next function_body_length
    @Test func `fixed original text and media oracles retain supported recall in a mixed store`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = Self.repository.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        let original = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.Captured.self,
                                                from: Data(contentsOf: folder
                                                    .appendingPathComponent("raw-quality-vectors.json")))
        let media = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.MediaCapture.self,
                                             from: Data(contentsOf: folder
                                                 .appendingPathComponent("captured-media.json")))
        for (doc, vector) in zip(original.documents, original.vectors) {
            try store.replace(path: corpus + "/" + doc.id + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: doc.text, page: nil)], vectors: [vector])
        }
        for doc in media.documents {
            let path = corpus + "/" + doc.id + (doc.kind == "audio" ? ".wav" : ".png")
            let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: doc.id)
            let generation = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                       input: .init(
                                           kind: doc.kind == "audio" ? .audio : .image,
                                           path: path,
                                           time: 0,
                                           endTime: doc.duration
                                       ),
                                       vector: doc.vector)
            try #require(try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1))
        }
        var rows: [[String: Any]] = []
        var positives: [String: Int] = [:], recalled: [String: Int] = [:], negatives = 0, falsePositives = 0
        func record(id: String, group: String, query: String, expected: [String], vector: [Float]) throws {
            let hits = try search(store, query: query, vector: vector)
            let ids = hits.map { ($0.name as NSString).deletingPathExtension }
            let rank = ids.firstIndex { expected.contains($0) }.map { $0 + 1 }
            rows.append(["id": id, "group": group, "query": query, "expected": expected, "hits": ids,
                         "rank": rank as Any? ?? NSNull()])
            if expected.isEmpty {
                negatives += 1; if !hits.isEmpty {
                    falsePositives += 1
                }
            } else if group != "scanned", group != "media_timestamp" {
                positives[group, default: 0] += 1
                if rank != nil {
                    recalled[group, default: 0] += 1
                }
            }
        }
        for queryCase in original.queries {
            try record(id: queryCase.id, group: queryCase.group, query: queryCase.query, expected: queryCase.expected,
                       vector: #require(original.query_vectors[queryCase.id]))
        }
        for queryCase in media.queries {
            try record(
                id: queryCase.id,
                group: queryCase.group,
                query: queryCase.query,
                expected: queryCase.expected,
                vector: queryCase.vector
            )
        }
        let screenshot = try search(store)
        let fixed = screenshot.first { $0.name == "screen.png" }
        #expect(fixed?.evidence?.segmentKind == "image")
        #expect(rows.count == 306 && negatives == 50)
        #expect(Double(falsePositives) / Double(negatives) <= 0.05)
        for (group, count) in positives {
            #expect(Double(recalled[group] ?? 0) / Double(count) >= 0.85, "\(group)")
        }
        if let out = ProcessInfo.processInfo.environment["TYPEFLUX_CORROBORATION_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: ["rows": rows, "positive_denominators": positives,
                                                        "recalled": recalled, "no_answer_denominator": negatives,
                                                        "false_positives": falsePositives,
                                                        "note": """
                                                        Original scanned/media_timestamp labels retained as known unsupported sources in this fixed-vector corpus;
                                                        excluded only from supported recall, never from raw rows or original denominators.
                                                        """,
                                                        "fixed_hits": screenshot.map { [
                                                            "name": $0.name,
                                                            "kind": $0.evidence?.segmentKind ?? ""
                                                        ] }],
                                       options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("mixed-oracle.json"))
        }
    }

    @Test func `original fifty no answer queries retain their labels and denominators`() throws {
        let (root, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = Self.repository.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        var rows: [[String: Any]] = []
        for name in ["raw-quality-vectors.json", "captured-media.json"] {
            let source = try #require(JSONSerialization
                .jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [String: Any])
            let queries = try #require(source["queries"] as? [[String: Any]])
            for queryCase in queries where (queryCase["expected"] as? [String])?.isEmpty == true {
                let id = try #require(queryCase["id"] as? String), query = try #require(queryCase["query"] as? String)
                let queryVector =
                    try #require(queryCase["vector"] as? [NSNumber] ??
                        (source["query_vectors"] as? [String: [NSNumber]])?[id])
                let hits = try search(store, query: query, vector: queryVector.map(\.floatValue))
                try rows.append([
                    "id": id,
                    "group": #require(queryCase["group"]),
                    "expected": #require(queryCase["expected"]),
                    "hits": hits.map(\.name)
                ])
                #expect(hits.isEmpty, "\(id): \(query)")
            }
        }
        #expect(rows.count == 50)
        if let out = ProcessInfo.processInfo.environment["TYPEFLUX_CORROBORATION_EVIDENCE"] {
            try JSONSerialization.data(withJSONObject: ["rows": rows, "fixed_hits": search(store).map {
                ["name": $0.name, "segment_kind": $0.evidence?.segmentKind ?? "", "score": $0.score] as [String: Any]
            }], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("store-replay.json"))
        }
    }
}

private final class RetainedScreenshotQuery: SemanticQueryEmbedding, @unchecked Sendable {
    let vector: [Float]
    init(_ vector: [Float]) {
        self.vector = vector
    }

    func query(_: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        if lifecycle.isCancelled {
            throw CancellationError()
        }
        return vector
    }

    func stop() {}
}

private final class RetainedScreenshotMetadata: AskFileReading, @unchecked Sendable {
    let modified: Date
    let version: String
    let lock = NSLock()
    var mode = 0
    init(modified: Date, version: String) {
        self.modified = modified; self.version = version
    }

    func setMode(_ mode: Int) {
        lock.withLock { self.mode = mode }
    }

    func read(_: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if isCancelled() {
            throw CancellationError()
        }
        let mode = lock.withLock { self.mode }
        if mode == 1 {
            return .init(error: EACCES)
        }
        return .init(fileSize: 32816, modified: modified, version: mode == 2 ? "changed" : version)
    }
}

@Suite("Retained screenshot service publication", .serialized, .exclusiveUIState)
@MainActor
struct SemanticImageCorroborationServiceTests {
    @Test func `service publishes visual then rejects changed version and revoked metadata access`() async throws {
        let (base, root, _, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("semantic-files.sqlite")
        try FileManager.default.copyItem(
            at: SemanticImageCorroborationTests.capture.appendingPathComponent("synthetic.sqlite"),
            to: copy
        )
        let store = try SemanticFileStore(url: copy)
        let row = try store.statement("SELECT modified,version FROM files LIMIT 1")
        guard sqlite3_step(row) == SQLITE_ROW else {
            sqlite3_finalize(row); throw SemanticFileStore.Failure.database
        }
        let reader = RetainedScreenshotMetadata(modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 0)),
                                                version: store.string(row, 1))
        sqlite3_finalize(row)
        var names = base.settings.askLauncherSearchSettings
        names.fileRoots = ["/gul405-synthetic/corpus"]; names.excludedPaths = []
        base.settings.askLauncherSearchSettings = names
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let query = try RetainedScreenshotQuery(SemanticImageCorroborationTests().vector())
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: SemanticFixtureWatcher(),
                                                access: { true }, automaticStart: false, lowPowerMode: { false },
                                                thermalConstrained: { false },
                                                models: models, makeReader: { reader }, makeQuery: { _, _ in query })
        service.pause(true)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .paused && service.modelReady }
        let text = SemanticImageCorroborationTests().text
        let hits = await service.search(text, type: .image, limit: 5)
        #expect(hits.count == 1 && hits.first?.evidence?.segmentKind == "image")
        reader.setMode(2)
        #expect(await service.search(text, type: .image, limit: 5).isEmpty)
        reader.setMode(1)
        #expect(await service.search(text, type: .image, limit: 5).isEmpty)
        if let out = ProcessInfo.processInfo.environment["TYPEFLUX_CORROBORATION_EVIDENCE"] {
            try JSONSerialization.data(
                withJSONObject: [
                    "mode": "Retained real-vector service replay; mocked query and metadata; no inference or UI",
                    "fixed_visual_hits": hits.map { $0.evidence?.segmentKind ?? "" },
                    "changed_version_hits": 0,
                    "revoked_access_hits": 0
                ],
                options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: URL(fileURLWithPath: out).appendingPathComponent("service-replay.json"))
        }
        await service.clear(removeModel: true)
    }
}
