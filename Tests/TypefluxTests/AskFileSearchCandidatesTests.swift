import Foundation
import Testing
@testable import Typeflux

@Suite("File search candidate reuse")
struct AskFileSearchCandidatesTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fixture() -> AskFileIndexState {
        var entries: [(String, AskFileRecord.Kind, Double)] = (0..<200).map {
            ("/bench/bbbb-\($0).pdf", .file, 100)
        }
        entries += [("/bench/合同.pdf", .file, 1), ("/bench/Typeflux.swift", .file, 2),
                    ("/bench/report-a.pdf", .file, 5), ("/bench/report-z.pdf", .file, 1),
                    ("/bench/report.png", .file, 0), ("/bench/report/plan.md", .file, 3)]
        return AskTestFileIndex.state(entries, home: "/bench", now: now)
    }

    private func pool() -> AskFileSearchCandidates { .init(minimumEntries: 0) }

    @Test func extendingQueriesKeepsNewPinyinAndFuzzyHits() {
        let state = fixture(), cache = pool()
        for sequence in [["h", "ht", "hetong"], ["tp", "tpl"], ["re", "rep", "report"]] {
            cache.invalidate(revision: 0)
            for text in sequence {
                let query = AskSearchQuery(text), options = AskFileSearchOptions(limit: 24, now: now)
                #expect(state.search(query, options: options, candidates: cache) == state.search(query, options: options))
                #expect(cache.lookup(mask: query.mask, includesPaths: false, recordCount: state.records.count, revision: 0) != nil)
            }
        }
        #expect(!state.search(.init("h"), options: .init(now: now)).contains { $0.name == "合同.pdf" })
        #expect(state.search(.init("ht"), options: .init(now: now)).contains { $0.name == "合同.pdf" })
        #expect(!state.search(.init("tp"), options: .init(now: now)).contains { $0.name == "Typeflux.swift" })
        #expect(state.search(.init("tpl"), options: .init(now: now)).contains { $0.name == "Typeflux.swift" })
    }

    @Test func filteringAndRankingAlwaysRunAgainAcrossTheWholePool() {
        let state = fixture(), cache = pool()
        _ = state.search(.init("report .png"), options: .init(limit: 1, type: .image, now: now), candidates: cache)
        for text in ["report", "report .pdf", "report in:bench"] {
            for type in [AskFileType.all, .pdf, .image, .folder] {
                for order in [AskFileSearchOptions.Order.relevance, .recent] {
                    for fuzzy in [false, true] {
                        let query = AskSearchQuery(text)
                        let options = AskFileSearchOptions(limit: 24, fuzzy: fuzzy, type: type, order: order,
                                                           usage: ["/bench/report-a.pdf": 10], now: now.addingTimeInterval(86400))
                        #expect(state.search(query, options: options, candidates: cache) == state.search(query, options: options))
                    }
                }
            }
        }
        #expect(state.search(.init("report"), options: .init(limit: 24, now: now), candidates: cache).count > 1)
        #expect(state.search(.init("report"), options: .init(limit: 1, type: .pdf, usage: ["/bench/report-a.pdf": 10], now: now),
                             candidates: cache).first?.name == "report-a.pdf")
    }

    @Test func editingWordsAndSwitchingToPathMatchingFallsBackSafely() {
        let state = fixture(), cache = pool()
        for text in ["rep", "rep plan", "report plan", "plan", "r", "re", "xyzzy", "xyzzyy", "ht"] {
            let query = AskSearchQuery(text), options = AskFileSearchOptions(limit: 24, now: now)
            #expect(state.search(query, options: options, candidates: cache) == state.search(query, options: options))
        }
        #expect(state.search(.init("rep plan"), options: .init(now: now), candidates: cache).contains { $0.name == "plan.md" })
        #expect(state.search(.init(""), options: .init(), candidates: cache).isEmpty)
        #expect(state.search(.init("report"), options: .init(limit: 0), candidates: cache).isEmpty)
    }

    @Test func poolsRequireTheSameSnapshotAndMatchingMaskDomain() throws {
        let cache = pool()
        let collector = try #require(cache.collector(mask: 3, recordCount: 80, chunks: 2))
        // Concurrent workers may finish out of order, but record order stays stable.
        collector.insert([50, 51], chunk: 1, exceeded: false)
        collector.insert([1, 2], chunk: 0, exceeded: false)
        cache.store(collector, mask: 3, includesPaths: false, recordCount: 80, revision: 0)
        #expect(cache.lookup(mask: 7, includesPaths: false, recordCount: 80, revision: 0) == [1, 2, 50, 51])
        #expect(cache.lookup(mask: 1, includesPaths: false, recordCount: 80, revision: 0) == nil)
        #expect(cache.lookup(mask: 3, includesPaths: true, recordCount: 80, revision: 0) == nil)
        #expect(cache.lookup(mask: 3, includesPaths: false, recordCount: 81, revision: 0) == nil)
        #expect(cache.lookup(mask: 3, includesPaths: false, recordCount: 80, revision: 1) == nil)
        cache.invalidate(revision: 1)
        cache.store(collector, mask: 3, includesPaths: false, recordCount: 80, revision: 0)
        #expect(cache.lookup(mask: 3, includesPaths: false, recordCount: 80, revision: 1) == nil)
        cache.store(collector, mask: 3, includesPaths: false, recordCount: 80, revision: 1)
        #expect(cache.lookup(mask: 3, includesPaths: false, recordCount: 80, revision: 1) != nil)
    }

    @Test func broadPoolsAndSmallIndexesDoNotRetainCandidates() throws {
        #expect(AskFileSearchCandidates().collector(mask: 1, recordCount: 100, chunks: 1) == nil)
        #expect(pool().collector(mask: 0, recordCount: 80, chunks: 1) == nil)
        #expect(pool().collector(mask: 1, recordCount: 7, chunks: 1) == nil)
        #expect(AskFileSearchCandidates(maximumCandidates: 0, minimumEntries: 0)
            .collector(mask: 1, recordCount: 80, chunks: 1) == nil)
        let cache = AskFileSearchCandidates(maximumCandidates: 2, minimumEntries: 0)
        let collector = try #require(cache.collector(mask: 1, recordCount: 80, chunks: 3))
        collector.insert([1, 2], chunk: 0, exceeded: false)
        collector.insert([3], chunk: 1, exceeded: false)
        collector.insert([4], chunk: 2, exceeded: false)
        #expect(!collector.isCollecting && collector.indices == nil)
        cache.store(collector, mask: 1, includesPaths: false, recordCount: 80, revision: 0)
        #expect(cache.lookup(mask: 1, includesPaths: false, recordCount: 80, revision: 0) == nil)
        let exceeded = try #require(cache.collector(mask: 1, recordCount: 80, chunks: 1))
        exceeded.insert([], chunk: 0, exceeded: true)
        #expect(exceeded.indices == nil)
        let state = fixture(), broad = pool()
        _ = state.search(.init("b"), options: .init(now: now), candidates: broad)
        #expect(broad.lookup(mask: AskSearchQuery("b").mask, includesPaths: false,
                            recordCount: state.records.count, revision: 0) == nil)
    }

    @Test func cancellationAndSnapshotReplacementCannotPoisonTheCache() {
        var state = fixture()
        let cache = pool(), token = AskSearchCancellation(), query = AskSearchQuery("report")
        token.cancel()
        #expect(state.search(query, options: .init(cancellation: token), candidates: cache).isEmpty)
        #expect(cache.lookup(mask: query.mask, includesPaths: false, recordCount: state.records.count, revision: 0) == nil)
        _ = state.search(query, options: .init(now: now), candidates: cache)
        state.remove("/bench/report-a.pdf")
        let root = state.directory("/bench")
        state.add(name: "report-new.pdf", directory: root, kind: .file, modified: now)
        state = state.compacted()
        cache.invalidate(revision: 1)
        let actual = state.search(query, options: .init(now: now), candidates: cache, revision: 1)
        #expect(actual == state.search(query, options: .init(now: now)))
        #expect(actual.contains { $0.name == "report-new.pdf" })
        #expect(!actual.contains { $0.name == "report-a.pdf" })
    }

    @Test func parallelChunksPreserveResultsAndCandidateOrder() {
        var state = AskFileIndexState(home: "/bench")
        let root = state.directory("/bench"), cache = pool()
        for index in 0..<70_000 {
            let name = index % 1000 == 0 ? "report-\(index).pdf" : "bbbb-\(index).pdf"
            state.add(name: name, directory: root, kind: .file, modified: now)
        }
        for text in ["re", "rep", "report"] {
            let query = AskSearchQuery(text), options = AskFileSearchOptions(limit: 24, now: now)
            #expect(state.search(query, options: options, candidates: cache) == state.search(query, options: options))
            let indices = cache.lookup(mask: query.mask, includesPaths: false, recordCount: state.records.count, revision: 0)
            #expect(indices?.count == 70 && indices == indices?.sorted())
        }
    }
}
