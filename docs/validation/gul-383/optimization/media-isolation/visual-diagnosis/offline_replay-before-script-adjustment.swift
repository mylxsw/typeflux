import Foundation
import SQLite3
@testable import Typeflux
@testable import TypefluxFocusedTests

/// Offline replay only. Every input vector comes from the retained real-model artifacts.
@main @MainActor
struct OfflineReplay {
    static func diagnose(_ store: SemanticFileStore, vector: [Float], text: String, corpus: String) throws -> [String: Any] {
        let ranking = SemanticSearchRanking(text)
        let lexical = try SemanticLexicalReader.candidates(database: store.database!, ranking: ranking,
            query: .init(text), type: .all, scope: semanticScope(corpus), limit: 100, cancelled: { false })
        let evidence = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0.evidence) })
        let row = try store.statement("SELECT id,path,vector,modality,segment_kind,provenance,text FROM chunks ORDER BY id")
        defer { sqlite3_finalize(row) }
        var rows: [[String: Any]] = [], maxima: [String: Double] = [:]
        while sqlite3_step(row) == SQLITE_ROW {
            let id = sqlite3_column_int64(row, 0), path = store.string(row, 1)
            let n = Int(sqlite3_column_bytes(row, 2))/4
            guard let raw = sqlite3_column_blob(row, 2), n == 768 else { continue }
            let values = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: n))
            var scratch: [Float] = []
            let score = Double(try SemanticVectorReader.scores(values.map { Float16($0).bitPattern }, vector: vector, scratch: &scratch)[0])
            let e = evidence[id] ?? .init(coverage: 0, phrase: false, identifier: false)
            let modality = SemanticMediaPriority.of(path), isOCR = store.string(row, 4) == "image-ocr"
            let accepted = ranking.score(cosine: score, evidence: e, modality: modality, embedding: isOCR ? nil : .image)
            let allowed = SemanticSearchRanking.allowed(path, query: .init(text), type: .all, scope: semanticScope(corpus))
            let expected = isOCR ? SemanticFileStore.imageRecipe : SemanticFileStore.mediaVectorProvenance(path, kind: .image)
            if allowed { maxima[path] = max(maxima[path] ?? -.infinity, score) }
            rows.append(["id": id, "name": URL(fileURLWithPath: path).lastPathComponent,
                "modality": store.string(row, 3), "segment_kind": store.string(row, 4), "provenance": store.string(row, 5),
                "provenance_matches": store.string(row, 5) == expected, "allowed": allowed,
                "vector_valid": SemanticFileStore.valid(values), "dimensions": n,
                "norm": sqrt(values.reduce(0.0) { $0 + Double($1)*Double($1) }),
                "float32_dot": zip(values, vector).reduce(0.0) { $0 + Double($1.0)*Double($1.1) },
                "scanner_cosine": score, "lexical_coverage": e.coverage,
                "candidate_score": accepted as Any? ?? NSNull()])
        }
        let ordered = maxima.values.sorted(by: >), peak = ordered.first ?? 0
        let runner = ordered.count > 1 ? ordered[1] : nil
        return ["query": text, "query_valid": SemanticFileStore.valid(vector),
            "query_norm": sqrt(vector.reduce(0.0) { $0 + Double($1)*Double($1) }),
            "semantic_floor": ranking.semanticFloor, "absolute_confidence_floor": 0.70,
            "distinct_files": maxima.count, "peak": peak, "runner_up": runner as Any? ?? NSNull(),
            "confident": ranking.confident(peak: peak, runnerUp: runner, completeLexical: lexical.contains { $0.evidence.coverage == 1 }),
            "lexical_candidate_count": lexical.count, "rows": rows]
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = root.appendingPathComponent("docs/validation/gul-383/optimization/media-isolation/visual-diagnosis")
        let old = root.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        func json(_ url: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        }
        func vector(_ value: Any) -> [Float] { (value as! [NSNumber]).map { $0.floatValue } }
        let source = out.appendingPathComponent("fixed-capture/synthetic.sqlite")
        let working = root.appendingPathComponent(".build/visual-diagnosis/offline.sqlite")
        try FileManager.default.copyItem(at: source, to: working)
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: working.path + suffix) } }
        let store = try SemanticFileStore(url: working)
        let corpus = "/gul405-synthetic/corpus"
        let fixedText = "black text on a white background"
        let fixed = try JSONDecoder().decode([Float].self, from: Data(contentsOf: out.appendingPathComponent("fixed-capture/query-vector.json")))
        func hits(_ text: String, _ v: [Float]) throws -> [[String: Any]] {
            try store.search(vector: v, text: text, query: .init(text), type: .all,
                scope: semanticScope(corpus), limit: 5, cancelled: { false }).map {
                    ["name": $0.name, "kind": $0.evidence?.segmentKind as Any? ?? NSNull(), "score": $0.score]
                }
        }
        let original = try json(old.appendingPathComponent("raw-quality-vectors.json"))
        let media = try json(old.appendingPathComponent("captured-media.json"))
        let expectedModel = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
        precondition(original["model_sha256"] as? String == expectedModel && media["model_sha256"] as? String == expectedModel)
        precondition(media["projector_sha256"] as? String == "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
        let oldVectors = original["query_vectors"] as! [String: Any]
        let originalCases = (original["queries"] as! [[String: Any]]).filter { ($0["expected"] as! [String]).isEmpty }
        let mediaCases = (media["queries"] as! [[String: Any]]).filter { ($0["expected"] as! [String]).isEmpty }
        var negatives: [[String: Any]] = []
        for q in originalCases + mediaCases {
            let id = q["id"] as! String, text = q["query"] as! String
            let v = vector(q["vector"] ?? oldVectors[id]!)
            let diagnosis = try diagnose(store, vector: v, text: text, corpus: corpus)
            negatives.append(["id": id, "group": q["group"]!, "query": text,
                "hits": try hits(text, v), "diagnosis": diagnosis])
        }
        let imageDocs = (media["documents"] as! [[String: Any]]).filter { $0["kind"] as? String == "image" }
        let imageCases = (media["queries"] as! [[String: Any]]).filter { $0["group"] as? String == "image" }
        var colorCases: [[String: Any]] = []
        for q in imageCases {
            let v = vector(q["vector"]!), ranking = SemanticSearchRanking(q["query"] as! String)
            for doc in imageDocs {
                var scratch: [Float] = []
                let compact = vector(doc["vector"]!).map { Float16($0).bitPattern }
                let cosine = Double(try SemanticVectorReader.scores(compact, vector: v, scratch: &scratch)[0])
                colorCases.append(["query_id": q["id"]!, "query": q["query"]!, "file": doc["id"]!,
                    "matches_frozen_target": (q["expected"] as! [String]).contains(doc["id"] as! String),
                    "scanner_cosine": cosine,
                    "single_file_confident": ranking.confident(peak: cosine, runnerUp: nil, completeLexical: false)])
            }
        }
        var exact: [[String: Any]] = []
        for text in ["ERR-739204", "ERR-739205", "\"Connection failed\"", "\"Connection succeeded\""] {
            let found = try store.lexicalSearch(text: text, query: .init(text), type: .all, scope: semanticScope(corpus), limit: 5, cancelled: { false })
            exact.append(["query": text, "hits": found.map { ["name": $0.name, "kind": $0.evidence?.segmentKind ?? ""] }])
        }
        let result: [String: Any] = ["mode": "Offline production Store/Float16 scanner replay; no inference or parameter changes",
            "fixed_query": ["hits": try hits(fixedText, fixed), "diagnosis": try diagnose(store, vector: fixed, text: fixedText, corpus: corpus)],
            "existing_no_answer_denominator": negatives.count,
            "existing_no_answer_false_positives": negatives.filter { !($0["hits"] as! [[String: Any]]).isEmpty }.count,
            "no_answer_rows": negatives, "existing_image_color_pairs": colorCases, "exact_lexical_queries": exact]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("offline-replay.json"))
    }
}
