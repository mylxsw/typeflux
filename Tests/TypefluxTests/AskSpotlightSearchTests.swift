import Foundation
import Testing
@testable import Typeflux

private final class SpotlightTestQuery: NSMetadataQuery {
    var starts = 0, stops = 0
    var succeeds = true
    var completes = false
    override var resultCount: Int { 0 }
    override func start() -> Bool {
        starts += 1
        if completes { NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: self) }
        return succeeds
    }
    override func stop() { stops += 1 }
    override func disableUpdates() {}
}

@MainActor
private final class SpotlightTestAI: SemanticFileSearching {
    var isEnabled = true
    var requests = 0
    let hits: [AskFileHit]
    init(hits: [AskFileHit]) { self.hits = hits }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] {
        requests += 1
        try? await Task.sleep(for: .milliseconds(80))
        return hits
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct AskSpotlightSearchTests {
    private var settings: AskLauncherSearchSettings {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = ["/Users/test"]
        settings.excludedPaths = ["/Users/test/Library"]
        return settings
    }
    private var scope: AskFileScope { AskFileScope(settings: settings, fullDiskAccess: true) }

    @Test(arguments: ["ch", "cha", "chat", "hello", "中文", "chat ext:pdf", "expense receipts", "项目 说明", "\"quoted\""])
    func typedQueriesStartWithTheRealSpotlightAPI(_ text: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-query-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = settings
        configuration.fileRoots = [root.path]
        let scope = AskFileScope(settings: configuration, fullDiskAccess: true)
        var lookups = 0
        let search = AskSpotlightSearch { predicate, roots, _ in
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = roots
            // A mock or predicate.evaluate(with:) accepts a one-child compound,
            // but the native startQuery call rejects it by throwing an exception.
            let started = query.start()
            defer { query.stop() }
            #expect(started)
            lookups += 1
            return []
        }
        #expect(await search.search(text, type: .all, limit: 1, scope: scope).isEmpty)
        #expect(lookups == 1)
    }

    @Test func systemResultsRespectScopeExclusionsTypesFiltersAndDeduplication() async {
        let search = AskSpotlightSearch { predicate, roots, limit in
            #expect(roots == ["/Users/test"] && limit == 40)
            #expect(predicate.evaluate(with: ["kMDItemTextContent": "Expense process and RECEIPTS"]))
            #expect(!predicate.evaluate(with: ["kMDItemTextContent": "Expense process"]))
            return ["/Users/test/Documents/guide.pdf", "/Users/test/Documents/guide.pdf",
                    "/Users/test/Library/private.pdf", "/Users/test/Documents/node_modules/no.pdf",
                    "/Users/test/Documents/.hidden.pdf", "/Users/other/outside.pdf",
                    "/Users/test/Documents/notes.txt", "/Users/test/Downloads/guide.pdf",
                    "/Users/test/Documents/../Library/private.pdf"].map { .init(path: $0, modified: .distantPast) }
        }
        let hits = await search.search("expense receipts ext:pdf in:documents", type: .pdf, limit: 10, scope: scope)
        #expect(hits.map(\.path) == ["/Users/test/Documents/guide.pdf"])
        #expect(hits.first?.evidence?.segmentKind == "spotlight")
        #expect(hits.first?.match == 0)
    }

    @Test func invalidAndCancelledQueriesNeverStartASystemLookup() async {
        let search = AskSpotlightSearch { _, _, _ in Issue.record("Unexpected system lookup"); return [] }
        #expect(await search.search("", type: .all, limit: 10, scope: scope).isEmpty)
        #expect(await search.search("hello", type: .folder, limit: 10, scope: scope).isEmpty)
        #expect(await search.search("hello", type: .all, limit: 0, scope: scope).isEmpty)
        var noRoots = scope; noRoots.roots = []
        #expect(await search.search("hello", type: .all, limit: 10, scope: noRoots).isEmpty)
        let task = Task { await search.search("hello", type: .all, limit: 10, scope: scope) }
        task.cancel()
        #expect(await task.value.isEmpty)
    }

    @Test func lateSystemTextMatchesKeepExactFilenameResultsEligibleForReturn() {
        let name = AskFileHit(path: "/Users/test/guide.pdf", name: "guide.pdf", kind: .file,
                              modified: .distantPast, score: 1, match: 1)
        var content = name
        content.score = 0.5; content.match = 0
        content.evidence = .init(text: "", segmentKind: "spotlight")
        let combined = SemanticFilePolicy.merge([name], [content], limit: 10)
        #expect(combined == [name])
        #expect(AskQuickResults.bestRow("guide", apps: [], panes: [], files: combined) == .file(0))
        #expect(AskQuickResults.bestRow("guide", apps: [], panes: [], files: [content]) == nil)
        content.evidence = .init(text: "A useful passage", page: 3)
        #expect(SemanticFilePolicy.merge([name], [content], limit: 10).first?.evidence?.page == 3)
    }

    @Test func nativeSessionsStopOnCompletionFailedStartDeadlineAndCancellation() async {
        let predicate = NSPredicate(value: true)
        for mode in 0 ..< 4 {
            let query = SpotlightTestQuery()
            query.succeeds = mode != 0; query.completes = mode == 1
            let session = AskSpotlightSearch.Session(predicate: predicate, roots: ["/tmp"], limit: 10,
                                                     timeout: .milliseconds(30), query: query)
            let task = Task { await session.run() }
            if mode == 3 {
                while query.starts == 0 { await Task.yield() }
                task.cancel()
            }
            #expect(await task.value.isEmpty)
            #expect(query.starts == 1 && query.stops == 1)
        }
    }

    @Test func basicContentSearchWorksWithAIAbsentAndAIEnrichmentPublishesIndependently() async {
        let spotlight = AskSpotlightSearch { _, _, _ in [.init(path: "/Users/test/guide.pdf", modified: .distantPast)] }
        let basic = AskFileContentSearch(spotlight: spotlight, settings: { settings }, enabled: { true },
                                         semantic: { nil }, access: { true })
        #expect(await basic.search("process", type: .all, limit: 10).map(\.path) == ["/Users/test/guide.pdf"])
        let enriched = AskFileHit(path: "/Users/test/guide.pdf", name: "guide.pdf", kind: .file,
                                   modified: .distantPast, score: 0.8, evidence: .init(text: "AI passage", page: 3))
        let ai = SpotlightTestAI(hits: [enriched])
        let service = AskFileContentSearch(spotlight: spotlight, settings: { settings }, enabled: { true },
                                           semantic: { ai }, access: { true })
        var batches: [[AskFileHit]] = []
        let hits = await service.search("process", type: .all, limit: 10) { batches.append($0) }
        #expect(batches.first?.first?.evidence?.segmentKind == "spotlight")
        #expect(hits.count == 1 && hits.first?.evidence?.page == 3 && ai.requests == 1)
        ai.isEnabled = false
        #expect(await service.search("process", type: .all, limit: 10).first?.evidence?.segmentKind == "spotlight")
        #expect(ai.requests == 1)
    }

    @Test func changedSettingsAndDisabledFilesRejectLateContentBatches() async {
        var current = settings, enabled = true
        let spotlight = AskSpotlightSearch { _, _, _ in
            try? await Task.sleep(for: .milliseconds(20))
            current.fileRoots = ["/Users/other"]
            return [.init(path: "/Users/test/guide.pdf", modified: .distantPast)]
        }
        let service = AskFileContentSearch(spotlight: spotlight, settings: { current }, enabled: { enabled },
                                           semantic: { nil }, access: { true })
        var batches = 0
        #expect(await service.search("process", type: .all, limit: 10) { _ in batches += 1 }.isEmpty)
        #expect(batches == 0)
        enabled = false
        #expect(!service.isEnabled)
        #expect(await service.search("process", type: .all, limit: 10).isEmpty)
    }
}
