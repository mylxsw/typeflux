import Foundation
import Testing
@testable import Typeflux

@Suite("Search selection and cancellation")
struct AskSearchSchedulingTests {
    @Test func aStationaryPointerDoesNotReplaceKeyboardSelectionAfterLayout() {
        var pointer = AskSearchPointer(position: .init(x: 10, y: 20))
        let stationary = pointer.moved(to: .init(x: 10, y: 20))
        let moved = pointer.moved(to: .init(x: 10, y: 21))
        let layout = pointer.moved(to: .init(x: 10, y: 21))
        #expect(!stationary && moved && !layout)
    }

    @Test func boundedHeapMatchesFullSortForDifferentOrdersAndLimits() {
        let input = (0..<1000).map { ($0 * 7919) % 101 }
        for limit in [0, 1, 2, 24, 50, 1001] {
            var ascending = AskSearchTopK<Int>(limit: limit, precedes: <)
            var descending = AskSearchTopK<Int>(limit: limit, precedes: >)
            for value in input { ascending.insert(value); descending.insert(value) }
            #expect(ascending.sorted == Array(input.sorted().prefix(limit)))
            #expect(descending.sorted == Array(input.sorted(by: >).prefix(limit)))
            #expect(ascending.items.count <= limit)
        }
    }

    @Test func recentTopKMatchesFullSortAndHonorsRemovalAndType() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries = (0..<1000).map { ("/bench/report-\($0).\($0 % 2 == 0 ? "pdf" : "png")", AskFileRecord.Kind.file,
                                       Double(($0 * 7919) % 31)) }
        var state = AskTestFileIndex.state(entries, now: now)
        state.remove("/bench/report-0.pdf")
        for type in [AskFileType.all, .pdf, .image, .folder] {
            let expected = state.records.indices.filter {
                let record = state.records[$0]
                return !record.isRemoved && record.recordKind != .folder
                    && (type == .all || type.matches(kind: record.recordKind,
                                                     extension: URL(fileURLWithPath: state.path(of: UInt32($0))).pathExtension))
            }.sorted {
                let lhs = state.records[$0].modified, rhs = state.records[$1].modified
                return lhs != rhs ? lhs > rhs : $0 < $1
            }
            let found = state.recent(options: .init(limit: 24, type: type))
            #expect(found.map(\.path) == expected.prefix(24).map { state.path(of: UInt32($0)) })
        }
        #expect(state.recent(options: .init(limit: 0)).isEmpty)
        #expect(state.recent(options: .init(limit: -1)).isEmpty)
    }

    @Test func cancellationIsSharedWithTheParallelScanner() {
        let state = AskTestFileIndex.sample.state
        let token = AskSearchCancellation(), other = AskSearchCancellation()
        #expect(token == token && token != other)
        #expect(!token.isCancelled)
        token.cancel()
        #expect(state.search(.init("invoice"), options: .init(cancellation: token)).isEmpty)
        #expect(state.recent(options: .init(cancellation: token)).isEmpty)
    }

    @Test func chunkPruningKeepsUsagePromotionsAndDeterministicTies() {
        // All candidates tie before usage. The old limit*4 truncation discarded
        // both shorter names and frequently opened entries later in the chunk.
        var state = AskFileIndexState(home: "/bench")
        let directory = state.directory("/bench")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<300 {
            state.add(name: "report-long-name-\(index).pdf", directory: directory, kind: .file, modified: now)
        }
        state.add(name: "report-a.pdf", directory: directory, kind: .file, modified: now)
        let options = AskFileSearchOptions(limit: 1, usage: ["/bench/report-long-name-299.pdf": 10], now: now)
        #expect(state.search(.init("report"), options: options).first?.name == "report-long-name-299.pdf")
        #expect(state.search(.init("report"), options: .init(limit: 1, now: now)).first?.name == "report-a.pdf")
    }

    @Test func applicationPriorityAppliesToTheBestRowAndWeakMatchesStayWithAI() throws {
        let file = AskFileHit(path: "/notes.pdf", name: "notes.pdf", kind: .file, modified: Date(), score: 1.06, match: 1)
        let app = AskAppMatch(entry: AskTestAppIndex.app("Notes"), score: 0.9)
        for mode in [AskLauncherSearchSettings.Mode.mixed, .appsFirst, .filesFirst] {
            var settings = AskLauncherSearchSettings()
            settings.mode = mode
            let result = try #require(AskQuickResults.assemble("note", matches: [app], hits: [file],
                                                              status: nil, settings: settings))
            #expect(result.rows.first == (mode == .filesFirst ? .file(0) : .app(0)))
            let weak = AskAppMatch(entry: app.entry, score: 0.5)
            let fallback = try #require(AskQuickResults.assemble("note", matches: [weak], hits: [file],
                                                                status: nil, settings: settings))
            #expect(fallback.rows.first == (mode == .filesFirst ? .file(0) : .askAI))
            #expect(result.identity(of: .app(0)) == "app:" + app.entry.id)
            #expect(result.identity(of: .file(0)) == "file:/notes.pdf")
        }
    }
    @Test func smallTopKAgreesWithAnUnprunedSearchAcrossChunks() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var state = AskFileIndexState(home: "/bench")
        let root = state.directory("/bench")
        for index in 0..<18_000 {
            state.add(name: "report-\(index).pdf", directory: root, kind: .file,
                      modified: now.addingTimeInterval(-Double(index % 50) * 86400))
        }
        for order in [AskFileSearchOptions.Order.relevance, .recent] {
            let usage = ["/bench/report-17999.pdf": 10, "/missing/report.pdf": 10]
            let all = state.search(.init("report"), options: .init(limit: 20_000, order: order, usage: usage, now: now))
            let top = state.search(.init("report"), options: .init(limit: 7, order: order, usage: usage, now: now))
            #expect(top == Array(all.prefix(7)))
        }
    }

}
