import Foundation
import SQLite3
@testable import Typeflux
@testable import TypefluxFocusedTests

/// Replay retained real vectors through production Store. Does not perform inference or native UI work.
@main @MainActor
struct AudioReplay {
    static func main() throws {
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = repository.appendingPathComponent("docs/validation/gul-383/optimization/audio-live")
        let scale = out.deletingLastPathComponent().appendingPathComponent("ranking-scale")
        let scratch = repository.appendingPathComponent(".build/audio-live/replay.sqlite")
        try FileManager.default.copyItem(at: out.appendingPathComponent("live-visible-root/final.sqlite"), to: scratch)
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: scratch.path + suffix) }
        }
        let store = try SemanticFileStore(url: scratch)
        let corpus = "/gul405-synthetic/corpus"
        try store.transaction {
            try store.sql("PRAGMA defer_foreign_keys=ON")
            try store.execute("UPDATE files SET path=?", [corpus + "/boundary.wav"])
            try store.execute("UPDATE chunks SET path=?", [corpus + "/boundary.wav"])
            try store.execute("UPDATE jobs SET path=?", [corpus + "/boundary.wav"])
        }
        let query = try JSONDecoder().decode([Float].self, from: Data(contentsOf:
            out.appendingPathComponent("live-visible-root/query-vector.json")))
        func hits(_ text: String, _ vector: [Float]) throws -> [AskFileHit] {
            try store.search(vector: vector, text: text, query: .init(text), type: .all,
                scope: semanticScope(corpus), limit: 5, cancelled: { false })
        }
        func mapped(_ values: [AskFileHit]) -> [[String: Any]] {
            values.map { ["name": $0.name, "kind": $0.evidence?.segmentKind as Any? ?? NSNull(),
                "time": $0.evidence?.time as Any? ?? NSNull(), "score": $0.score] }
        }
        let single = try hits("a tone", query)
        let original = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.Captured.self,
            from: Data(contentsOf: scale.appendingPathComponent("raw-quality-vectors.json")))
        let media = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.MediaCapture.self,
            from: Data(contentsOf: scale.appendingPathComponent("captured-media.json")))
        for (document, vector) in zip(original.documents, original.vectors) {
            try store.replace(path: corpus + "/" + document.id + ".txt", modified: Date(), bytes: 1,
                chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        for document in media.documents {
            let path = corpus + "/" + document.id + (document.kind == "audio" ? ".wav" : ".png")
            let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: document.id)
            let generation = try store.beginMediaJob(path: path, metadata: metadata)
            try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                input: .init(kind: document.kind == "audio" ? .audio : .image,
                    path: path, time: 0, endTime: document.duration), vector: document.vector)
            guard try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1)
            else { throw SemanticFileStore.Failure.database }
        }
        let mixed = try hits("a tone", query)
        var rows: [[String: Any]] = []
        var positive: [String: Int] = [:], recalled: [String: Int] = [:]
        var negative = 0, falsePositive = 0
        func record(_ id: String, _ group: String, _ text: String, _ expected: [String], _ vector: [Float]) throws {
            let found = try hits(text, vector)
            let names = found.map { ($0.name as NSString).deletingPathExtension }
            let rank = names.firstIndex { expected.contains($0) }.map { $0 + 1 }
            rows.append(["id": id, "group": group, "query": text, "expected": expected,
                "hits": names, "rank": rank as Any? ?? NSNull()])
            if expected.isEmpty {
                negative += 1
                if !found.isEmpty { falsePositive += 1 }
            } else if group != "scanned", group != "media_timestamp" {
                positive[group, default: 0] += 1
                if rank != nil { recalled[group, default: 0] += 1 }
            }
        }
        for item in original.queries {
            guard let vector = original.query_vectors[item.id] else { throw SemanticFileStore.Failure.invalidVector }
            try record(item.id, item.group, item.query, item.expected, vector)
        }
        for item in media.queries {
            try record(item.id, item.group, item.query, item.expected, item.vector)
        }
        let reopened = try SemanticFileStore(url: scratch)
        let reopenedHits = try reopened.search(vector: query, text: "a tone", query: .init("a tone"), type: .all,
            scope: semanticScope(corpus), limit: 5, cancelled: { false })
        let result: [String: Any] = ["mode": "Retained real-vector production Store replay; no inference, no metadata or UI claim",
            "single_file": mapped(single), "mixed": mapped(mixed), "mixed_reopened": mapped(reopenedHits),
            "rows": rows, "positive_denominators": positive, "recalled": recalled,
            "no_answer_denominator": negative, "false_positives": falsePositive,
            "note": "All original 306 rows retained. Scanned/media_timestamp sources remain absent here. The tone is a separate boundary diagnostic and is not added to the original denominator."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("offline-replay.json"))
        guard single.isEmpty, mixed.first?.name == "boundary.wav",
              mixed.first?.evidence?.segmentKind == "audio-window", mixed.first?.evidence?.time == 25,
              reopenedHits.first?.name == "boundary.wav", rows.count == 306, negative == 50,
              Double(falsePositive) / Double(negative) <= 0.05,
              positive.allSatisfy({ Double(recalled[$0.key] ?? 0) / Double($0.value) >= 0.85 })
        else { throw SemanticFileStore.Failure.database }
        print("Expected single-file rejection; mixed audio window25; original306/no-answer50 replay passed")
    }
}
