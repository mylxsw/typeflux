import Accelerate
import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class RankingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[AskFileHit], Error>?
    func set(_ result: Result<[AskFileHit], Error>) {
        lock.withLock { self.result = result }
    }

    func get() -> Result<[AskFileHit], Error>? {
        lock.withLock { result }
    }
}

@Suite("Semantic evidence calibration and immutable pages", .serialized)
struct SemanticSearchRankingTests {
    private func query(_ store: SemanticFileStore, _ root: URL, _ text: String, vector: [Float]? = nil,
                       limit: Int = 5, scope: AskFileScope? = nil) throws -> [AskFileHit] {
        try store.search(vector: vector ?? semanticVector(), text: text, query: .init(text), type: .all,
                         scope: scope ?? semanticScope(root.path), limit: limit, cancelled: { false })
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func `unicode normalization preserves cjk and exact number boundaries`() throws {
        let ranking = SemanticSearchRanking("ＣＡＦÉ TS-９００１")
        #expect(ranking.terms == ["9001", "cafe", "ts"])
        #expect(SemanticSearchRanking.normalize("ガラス café") == "ガラス cafe")
        #expect(SemanticSearchRanking.normalize("café 玻璃") == "cafe 玻璃")
        #expect(!SemanticSearchRanking("\"ガラス\"").evidence("カラス").phrase)
        #expect(ranking.evidence("Cafe\u{301} ts-9001").identifier)
        #expect(!ranking.evidence("café XTS-9001 TS-90010").identifier)
        #expect(SemanticSearchRanking("find (TS-9001), please").evidence("ts-9001").identifier)
        #expect(SemanticSearchRanking("TS-9001").evidence("编号TS-9001报销").identifier)
        let adjacent = SemanticSearchRanking("查找ＴＳ－９００１的报销")
        #expect(adjacent.identifiers == ["ts-9001"])
        #expect(adjacent.evidence("办理 TS-9001 报销").identifier)
        #expect(!adjacent.evidence("办理 TS-90010 报销").identifier)
        #expect(SemanticFilePolicy.searchTerms("项目报销流程").contains("报销"))
        #expect(SemanticSearchRanking("free form question 7").identifiers.isEmpty)
        #expect(!SemanticSearchRanking("9001").identifiers.isEmpty)
        #expect(!SemanticSearchRanking("AB9001").identifiers.isEmpty)
        let photo = SemanticSearchRanking("photo of a sunrise")
        let none = SemanticSearchRanking.Evidence(coverage: 0, phrase: false, identifier: false)
        #expect(photo.preferredModality == .image)
        #expect(try #require(photo.score(cosine: 0.8, evidence: none, modality: .image)) > photo.score(
            cosine: 0.8,
            evidence: none,
            modality: .document
        )!)
        #expect(SemanticSearchRanking("录音里的海浪").preferredModality == .audio)
        #expect(SemanticSearchRanking("video sunrise").preferredModality == .video)
        #expect(SemanticSearchRanking("PDF invoice").preferredModality == .document)
        let phrase = SemanticSearchRanking("\"water tomato\"")
        #expect(phrase.evidence("Water tomato plants").phrase)
        #expect(!phrase.evidence("tomato water").phrase)
        #expect(phrase.score(cosine: 0.99, evidence: phrase.evidence("tomato water"), modality: .document) == nil)
    }

    @Test func `complete terms and identifiers outrank unrelated high cosine`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        for (name, text, vector) in [("partial.txt", "red", semanticVector()),
                                     ("complete.txt", "red green blue TS-9001", semanticVector(1)),
                                     ("near.txt", "TS-90010", semanticVector())] {
            try store.replace(path: root.path + "/" + name, modified: Date(), bytes: 1,
                              chunks: [.init(text: text, page: 2)], vectors: [vector])
        }
        #expect(try query(store, root, "red green blue").first?.name == "complete.txt")
        #expect(try query(store, root, "TS-9001").map(\.name) == ["complete.txt"])
        #expect(try query(store, root, "TS-9002").isEmpty)
        #expect(try query(store, root, "\"green blue\"").map(\.name) == ["complete.txt"])
        #expect(try store.lexicalSearch(text: "red green blue", query: .init("red green blue"), type: .all,
                                        scope: semanticScope(root.path), limit: 5, cancelled: { false })
                .map(\.name) == ["complete.txt"])
    }

    @Test func `absolute gate retains a single exact vector and rejects orthogonal no answer`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: root.path + "/only.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "rainfall", page: nil)], vectors: [semanticVector()])
        #expect(try query(store, root, "precipitation").map(\.name) == ["only.txt"])
        #expect(try query(store, root, "space unicorn", vector: semanticVector(1)).isEmpty)
        let reader = try SemanticVectorReader(url: store.url)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try reader.prepare(cancelled: { checks += 1; return checks == 2 })
        }
        try reader.prepare(cancelled: { false })
        let loaded = reader.loadedPages
        try reader.prepare(cancelled: { false })
        #expect(reader.loadedPages == loaded, "unchanged pages are reused")
        #expect(throws: CancellationError.self) { try reader.prepare(cancelled: { true }) }
        reader.close()
        #expect(throws: SemanticFileStore.Failure.self) { try reader.prepare(cancelled: { false }) }
    }

    @Test func `committed update delete rollback and same ID reuse invalidate pages`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let path = root.path + "/mutable.txt"
        try store.replace(path: path, modified: Date(timeIntervalSince1970: 1), bytes: 1,
                          chunks: [.init(text: "old", page: 1)], vectors: [semanticVector()])
        #expect(try query(store, root, "unseen").first?.evidence?.page == 1)
        try execute(store.url, "BEGIN; UPDATE chunks SET text='rollback'; ROLLBACK;")
        #expect(try query(store, root, "unseen").first?.evidence?.text == "old")
        try store.replace(path: path, modified: Date(timeIntervalSince1970: 2), bytes: 2,
                          chunks: [.init(text: "new", page: 7)], vectors: [semanticVector(1)])
        #expect(try query(store, root, "unseen").isEmpty)
        #expect(try query(store, root, "unseen", vector: semanticVector(1)).first?.evidence?.page == 7)
        try execute(store.url, "UPDATE files SET modified=3,version='revision-three';")
        let hit = try #require(query(store, root, "unseen", vector: semanticVector(1)).first)
        #expect(hit.modified == Date(timeIntervalSince1970: 3) && hit.evidence?.version == "revision-three")
        try store.remove(path)
        #expect(try query(store, root, "unseen", vector: semanticVector(1)).isEmpty)
        try store.replace(path: path, modified: Date(), bytes: 1,
                          chunks: [.init(text: "reused ID", page: 9)], vectors: [semanticVector()])
        #expect(try query(store, root, "unseen").first?.evidence?.page == 9)
        var restricted = semanticScope(root.path); restricted.excludedPaths = [path]
        #expect(try query(store, root, "unseen", scope: restricted).isEmpty)
        #expect(try query(store, root, "unseen").first?.evidence?.page == 9)
        try store.clear()
        #expect(try query(store, root, "unseen").isEmpty)
    }

    @Test func `query readers do not wait for an uncommitted writer or checkpoint`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: root.path + "/note.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "evidence", page: nil)], vectors: [semanticVector()])
        try store.prepareSearch(cancelled: { false })
        var database: OpaquePointer?
        try #require(sqlite3_open(store.url.path, &database) == SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) }
        try #require(sqlite3_exec(database, "BEGIN IMMEDIATE; DELETE FROM files;", nil, nil, nil) == SQLITE_OK)
        // This lock is deliberately held by a different owner than either query connection.
        let finished = DispatchSemaphore(value: 0)
        let result = RankingResult()
        store.lock.lock()
        DispatchQueue.global().async {
            defer { finished.signal() }
            result.set(Result { try query(store, root, "evidence") })
        }
        let status = finished.wait(timeout: .now() + 2)
        store.lock.unlock()
        #expect(status == .success, "a search must not acquire the writer lock")
        if status == .success {
            #expect(try result.get()?.get().count == 1)
        }
    }

    @Test func `legacy normalization rebuild preserves vectors and new empty vectors stay invisible`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let path = root.path + "/legacy.txt"
        try store.replace(path: path, modified: Date(), bytes: 1,
                          chunks: [.init(text: "ＣＡＦÉ", page: 1)], vectors: [semanticVector()])
        try execute(
            store.url,
            "DELETE FROM search_recipe; DELETE FROM lexical; INSERT INTO lexical(rowid,terms) VALUES(1,'legacy');"
        )
        let migrated = try SemanticFileStore(url: store.url)
        #expect(try query(migrated, root, "cafe").first?.name == "legacy.txt")
        #expect(try migrated.counts().chunks == 1)
        try execute(store.url, "UPDATE chunks SET vector=X'';")
        #expect(try query(migrated, root, "unseen").isEmpty)
        #expect(try query(migrated, root, "cafe").count == 1, "pending vectors retain FTS")
    }

    @Test func `ambiguous low similarity refuses answers without breaking a clear semantic match`() {
        let ranking = SemanticSearchRanking("unseen question")
        #expect(!ranking.confident(peak: 0.69, runnerUp: 0.68, completeLexical: false))
        #expect(ranking.confident(peak: 0.70, runnerUp: 0.69, completeLexical: false))
        #expect(!ranking.confident(peak: 0.60, runnerUp: 0.59, completeLexical: false))
        #expect(!ranking.confident(peak: 0.66, runnerUp: 0.65, completeLexical: false))
        #expect(ranking.confident(peak: 0.66, runnerUp: 0.60, completeLexical: false))
        #expect(ranking.confident(peak: 0.60, runnerUp: 0.1, completeLexical: false))
        #expect(ranking.confident(peak: 1, runnerUp: nil, completeLexical: false))
        #expect(!ranking.confident(peak: 0.60, runnerUp: nil, completeLexical: false))
        #expect(ranking.confident(peak: 0.60, runnerUp: 0.59, completeLexical: true))
        #expect(ranking.score(
            cosine: .nan,
            evidence: .init(coverage: 0, phrase: false, identifier: false),
            modality: .document
        ) == nil)
    }

    @Test func `partial lexical overlap never demotes an equally similar passage`() throws {
        let ranking = SemanticSearchRanking("orchard irrigation maintenance")
        let absent = ranking.evidence("Workers inspect the pump"),
            partial = ranking.evidence("Workers inspect irrigation equipment")
        #expect(absent.coverage == 0 && partial.coverage > 0 && partial.coverage < 1)
        let unrelated = try #require(ranking.score(cosine: 0.8, evidence: absent, modality: .document))
        let overlapping = try #require(ranking.score(cosine: 0.8, evidence: partial, modality: .document))
        #expect(overlapping >= unrelated)
        let audio = try #require(ranking.score(cosine: 0.8, evidence: absent, modality: .audio))
        #expect(unrelated == audio, "An ordinary query does not silently prefer a media type")
    }

    @Test func `confidence includes low-scoring files and repeated book chunks do not change the answer`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        var relevant = semanticVector(); relevant[0] = 0.6; relevant[1] = 0.8
        try store.replace(path: root.path + "/answer.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "rainfall", page: nil)], vectors: [relevant])
        try store.replace(path: root.path + "/noise.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "noise", page: nil)], vectors: [semanticVector(2)])
        #expect(try query(store, root, "semantic paraphrase", limit: 1).map(\.name) == ["answer.txt"])
        var book = semanticVector(2); book[0] = 0.5; book[2] = sqrt(0.75)
        try store.replace(path: root.path + "/long-book.txt", modified: Date(), bytes: 1,
                          chunks: (0 ..< 600).map { (page: Int) in .init(text: "noise page \(page)", page: page) },
                          vectors: Array(repeating: book, count: 600))
        #expect(try query(store, root, "semantic paraphrase", limit: 1).map(\.name) == ["answer.txt"])
        let all = try query(store, root, "semantic paraphrase")
        #expect(all.map(\.name) == ["answer.txt", "long-book.txt"])
        #expect(all.last?.evidence?.page == 0, "equal-score chunks retain the lowest-ID passage")
        #expect(try query(store, root, "noise", limit: 1).count == 1, "lexical reranking never leaks more than TopK")
    }

    @Test func `video audio windows use audio calibration and preserve their timestamp`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: root.path + "/a.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "unrelated", page: nil)], vectors: [semanticVector()])
        let path = root.path + "/z.mov", metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: "video")
        let generation = try store.beginMediaJob(path: path, metadata: metadata)
        try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                   input: .init(kind: .audio, path: path, time: 30, endTime: 60),
                                   vector: semanticVector())
        #expect(try store.commitMediaJob(path: path, generation: generation, metadata: metadata, segments: 1))
        let hit = try #require(query(store, root, "audio semantic paraphrase", limit: 1).first)
        #expect(hit.name == "z.mov" && hit.evidence?.time == 30)
    }

    @Test func `database faults and malformed payloads fail closed without stale snapshot publication`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: root.path + "/bad.txt", modified: Date(), bytes: 1,
                          chunks: [.init(text: "data", page: nil)], vectors: [semanticVector()])
        try execute(store.url, "UPDATE chunks SET vector=zeroblob(3072)")
        #expect(try query(store, root, "unseen").isEmpty)
        try execute(store.url, "DROP TABLE vector_pages")
        #expect(throws: SemanticFileStore.Failure.self) { try query(store, root, "unseen") }
        try store.destroy()
        #expect(throws: SemanticFileStore.Failure.self) { try query(store, root, "unseen") }
    }

    @Test func `half precision scores preserve sorting within the documented error bound`() throws {
        var generator: UInt64 = 42
        func random() -> Float {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int64(bitPattern: generator) >> 32) / Float(Int32.max)
        }
        var rows: [[Float]] = []
        for _ in 0 ..< 256 {
            var row = (0 ..< 768).map { _ in random() }
            let norm = sqrt(row.reduce(0.0) { $0 + Double($1) * Double($1) })
            row = row.map { $0 / Float(norm) }; rows.append(row)
        }
        let query = rows[0]
        let floats = rows.flatMap(\.self), count = rows.count * 768
        var compact = [UInt16](repeating: 0, count: count)
        let conversion = floats.withUnsafeBytes { source in
            compact.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                          width: UInt(count), rowBytes: source.count)
                var output = vImage_Buffer(
                    data: target.baseAddress!,
                    height: 1,
                    width: UInt(count),
                    rowBytes: target.count
                )
                return vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
            }
        }
        #expect(conversion == kvImageNoError)
        var scratch: [Float] = []
        let scores = try SemanticVectorReader.scores(compact, vector: query, scratch: &scratch)
        let exact = rows.map { row in zip(row, query).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } }
        #expect(zip(scores, exact).allSatisfy { abs(Double($0) - $1) < 0.0001 })
        #expect(scores.indices.sorted { scores[$0] > scores[$1] }.prefix(5) == exact.indices
            .sorted { exact[$0] > exact[$1] }.prefix(5))
        #expect(try SemanticVectorReader.scores([], vector: query, scratch: &scratch).isEmpty)
        #expect(throws: SemanticFileStore.Failure.self) {
            try SemanticVectorReader.scores([0], vector: query, scratch: &scratch)
        }
    }
}

extension SemanticSearchRankingTests {
    @Test func `lexical timestamps reject nonfinite negative and integer overflow values`() throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let cases: [(Double, Double?)] = [
            (-1, nil), (.infinity, nil), (.nan, nil), (Double(Int.max), nil), (0, 0), (42.5, 42.5)
        ]
        for (index, value) in cases.enumerated() {
            try store.replace(path: root.path + "/time-\(index).wav", modified: Date(), bytes: 1,
                              chunks: [.init(text: "needle", page: nil, time: value.0)], vectors: [semanticVector()])
        }
        let hits = try store.lexicalSearch(text: "needle", query: .init("needle"), type: .all,
                                           scope: semanticScope(root.path), limit: 10, cancelled: { false })
        #expect(hits.count == cases.count)
        for (index, value) in cases.enumerated() {
            let hit = try #require(hits.first { $0.name == "time-\(index).wav" })
            #expect(hit.evidence?.time == value.1)
        }
    }
}

extension SemanticSearchRankingTests {
    @Test func `format requests exclude incidental content mentions`() {
        for (query, expected) in [
            ("play the recording of thunder", SemanticMediaPriority.audio),
            ("photos of a red train", .image), ("Which video shows the pier?", .video),
            ("from the document about tides", .document), ("请找海浪录音", .audio),
            ("玻璃桥的视频在哪里？", .video)
        ] {
            #expect(SemanticSearchRanking(query).preferredModality == expected)
        }
        for query in ["Does the website publish the recording after the lecture?",
                      "People described a photo while discussing the schedule",
                      "文中提到录音设备在星期五维修"] {
            #expect(SemanticSearchRanking(query).preferredModality == nil)
        }
    }

    @Test func `stronger raw evidence keeps its order across script distributions`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        func add(_ name: String, _ text: String, _ cosine: Float) throws {
            var vector = semanticVector(); vector[0] = cosine; vector[1] = sqrt(1 - cosine * cosine)
            try store.replace(path: root.path + "/" + name + ".txt", modified: Date(), bytes: 1,
                              chunks: [.init(text: text, page: nil)], vectors: [vector])
        }
        try add("strong", "第一段材料", 0.90)
        try add("weak", "Second passage", 0.75)
        for index in 0 ..< 12 {
            try add("filler-\(index)", "其他语料", 0.1)
        }
        #expect(try query(store, root, "unseen description").first?.name == "strong.txt")
        #expect(try query(store, root, "不相同的描述").first?.name == "strong.txt")
    }
}
