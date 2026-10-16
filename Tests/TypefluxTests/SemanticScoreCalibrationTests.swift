import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Calibrated script and modality branches", .serialized)
struct SemanticScoreCalibrationTests {
    @Test func `centering is bounded for tiny groups and repeated chunks contribute once`() {
        var stats = SemanticScoreCalibration()
        #expect(stats.adjustment(.audio, cosine: 0.5) == 0)
        stats.observe(path: "one", bucket: .text, cosine: 0.8)
        #expect(stats.adjustment(.text, cosine: 0.8) == 0)
        stats.observe(path: "two", bucket: .cjkText, cosine: 0.4)
        let original = stats.adjustment(.cjkText, cosine: 0.4)
        #expect(original > 0 && original < 0.1)
        for _ in 0 ..< 10000 {
            stats.observe(path: "two", bucket: .cjkText, cosine: 0.4)
        }
        #expect(stats.adjustment(.cjkText, cosine: 0.4) == original)
        stats.observe(path: "two", bucket: .cjkText, cosine: 0.6)
        #expect(stats.adjustment(.cjkText, cosine: 0.4) < original)
        stats.observe(path: "three", bucket: .image, cosine: .nan)
        #expect(stats.adjustment(.image, cosine: 0.5) == 0)
        #expect(SemanticScoreCalibration.Bucket(modality: .video, embedding: .audio, script: 0) == .audio)
        #expect(SemanticScoreCalibration.Bucket(modality: .video, embedding: .image, script: 0) == .video)
        #expect(SemanticScoreCalibration.Bucket(modality: .image, embedding: nil, script: 0) == .image)
    }

    @Test func `script branches retain cross-language candidates before global TopK`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        func vector(_ cosine: Float) -> [Float] {
            var value = semanticVector(); value[0] = cosine; value[1] = sqrt(1 - cosine * cosine); return value
        }
        func add(_ name: String, _ text: String, _ cosine: Float, copies: Int = 1) throws {
            try store.replace(path: root.path + "/" + name + ".txt", modified: Date(), bytes: 1,
                              chunks: Array(repeating: .init(text: text, page: nil), count: copies),
                              vectors: Array(repeating: vector(cosine), count: copies))
        }
        try add("answer-en", "English passage", 0.9)
        try add("answer-zh", "中文正文", 0.65)
        for index in 0 ..< 20 {
            try add("other-en-\(index)", "ordinary filler", 0.7)
            try add("other-zh-\(index)", "其他内容", 0.2)
        }
        func hits() throws -> [String] {
            try store.search(vector: semanticVector(), text: "semantic paraphrase", query: .init("semantic paraphrase"),
                             type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false }).map(\.name)
        }
        #expect(try hits().contains("answer-en.txt"))
        #expect(try hits().contains("answer-zh.txt"))
        try add("long-book", "普通中文", 0.2, copies: 1200)
        #expect(try hits().contains("answer-zh.txt"))
    }

    @Test func `legacy inserts text changes and recipe migration keep compatible vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: root.path + "/note.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "English body", page: nil)], vectors: [semanticVector()])
        var database: OpaquePointer?
        try #require(sqlite3_open(store.url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func execute(_ sql: String) throws {
            try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        func scripts() throws -> [Int] {
            var row: OpaquePointer?; try #require(sqlite3_prepare_v2(
                database,
                "SELECT search_script FROM chunks ORDER BY id",
                -1,
                &row,
                nil
            ) == SQLITE_OK)
            defer { sqlite3_finalize(row) }
            var result: [Int] = []
            while sqlite3_step(row) == SQLITE_ROW {
                result.append(Int(sqlite3_column_int(row, 0)))
            }
            return result
        }
        try execute("INSERT INTO chunks(path,text,vector) SELECT path,'中文內容',vector FROM chunks LIMIT 1")
        #expect(try scripts() == [0, 1])
        try execute("UPDATE chunks SET text='カラス' WHERE id=1")
        #expect(try scripts() == [1, 1])
        try execute("UPDATE chunks SET search_script=0; UPDATE search_recipe SET value='unicode-v2'")
        let migrated = try SemanticFileStore(url: store.url)
        while try migrated.maintainSearchBatch(cancelled: { false }) {}
        #expect(try scripts() == [1, 1])
        #expect(try migrated.counts().chunks == 2)
        #expect(try migrated.search(vector: semanticVector(), text: "unseen", query: .init("unseen"), type: .all,
                                    scope: semanticScope(root.path), limit: 5, cancelled: { false }).count == 1)
        for (text, expected) in [("a", 0), ("一", 0), ("中文", 1), ("カナ", 1), ("한글", 1)] {
            #expect(SemanticScoreCalibration.script(text) == expected)
        }
    }

    @Test func `BM25 breaks equal coverage ties rather than insertion order`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for (name, text) in [("long", "needle " + String(repeating: "filler ", count: 1000)), ("short", "needle")] {
            try store.replace(path: root.path + "/" + name + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: text, page: nil)], vectors: [semanticVector()])
        }
        let hits = try store.lexicalSearch(text: "needle", query: .init("needle"), type: .all,
                                           scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(hits.map(\.name) == ["short.txt", "long.txt"])
    }
}
