import Foundation
import Testing
@testable import Typeflux

actor SemanticDelayedSearch: SemanticFileSearching {
    var calls = 0
    let hits: [AskFileHit]
    nonisolated let enabled: Bool
    @MainActor var isEnabled: Bool { enabled }
    init(hits: [AskFileHit], enabled: Bool = true) {
        self.hits = hits
        self.enabled = enabled
    }

    func search(_: String, type _: AskFileType, limit: Int) async -> [AskFileHit] {
        calls += 1
        try? await Task.sleep(for: .milliseconds(150))
        return Array(hits.prefix(limit))
    }
}

@Suite("Semantic launcher integration", .serialized, .exclusiveUIState)
@MainActor
struct SemanticHybridSearchTests {
    let hit = AskFileHit(path: "/work/guide.pdf", name: "guide.pdf", kind: .file,
                         modified: Date(timeIntervalSince1970: 1), score: 0.7,
                         evidence: .init(text: "Reimbursement requests use the expense form", page: 3))

    @Test func disabledFeatureKeepsLegacyLongQueryAndPluginBehavior() async throws {
        let semantic = SemanticDelayedSearch(hits: [hit], enabled: false)
        let session = AskQuickSearchSession(), files = AskTestFileIndex()
        defer { session.cancel() }
        let text = "How should I submit a reimbursement request for my project?"
        session.update(text: text, chinese: false, calculator: false, sources: .init(files: files, semantic: semantic))
        #expect(!session.isSearching); #expect(session.results == nil)
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { semantic })
        let request = AskPluginRequest(text: "query", origin: .argument, keyword: AskFileSearchPlugin.keywords[0],
                                       options: [:], interfaceLanguage: .english)
        var progressCalls = 0
        _ = try await plugin.run(request, plan: await plugin.plan(request), progress: { _ in progressCalls += 1 })
        #expect(progressCalls == 0); #expect(await semantic.calls == 0)
    }

    @Test func filenameResultsRemainAvailableBeforeAndDuringPausedIndexing() async throws {
        let (service, root, _, _) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AskTestFileIndex([("/work/report.md", .file, 0)])
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { service })
        let request = AskPluginRequest(text: "report", origin: .argument,
                                       keyword: AskFileSearchPlugin.keywords[0], options: [:],
                                       interfaceLanguage: .english)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        for phase in [SemanticFileSearchService.Phase.modelRequired, .paused] {
            if phase == .paused {
                await service.prepareModelIfNeeded()
                try await SemanticFileServiceTests.wait { service.phase == .ready }
                service.pause(true)
                try await SemanticFileServiceTests.wait { service.phase == .paused }
            }
            #expect(service.isEnabled == (phase == .paused))
            let output = try await plugin.run(request, plan: plugin.plan(request), progress: { _ in })
            #expect(output.items.first?.title == "report.md")
            let session = AskQuickSearchSession()
            session.update(text: "report", chinese: false, calculator: false,
                           sources: .init(files: files, semantic: service))
            try await SemanticFileServiceTests.wait { !session.isSearching }
            #expect(session.results?.files.first?.name == "report.md")
            session.cancel()
        }
        await service.clear(removeModel: true)
    }

    @Test func `long natural query and late cancellation`() async throws {
        let semantic = SemanticDelayedSearch(hits: [hit]), session = AskQuickSearchSession()
        let files = AskTestFileIndex()
        let text = "How should I submit a reimbursement request for my project?"
        session.update(text: text, chinese: false, calculator: false, sources: .init(files: files, semantic: semantic))
        try await SemanticFileServiceTests.wait { !session.isSearching }
        #expect(session.results?.files == [hit]); #expect(session.results?.best == nil)
        #expect(session.results?.highlightedRow == .file(0))
        session.update(
            text: "reimbursement",
            chinese: false,
            calculator: false,
            sources: .init(files: files, semantic: semantic)
        )
        session.update(text: "", chinese: false, calculator: false, sources: .init(files: files, semantic: semantic))
        try await Task.sleep(for: .milliseconds(180))
        #expect(session.results == nil, "a late result must not repopulate cleared input")
        session.setVisible(false)
        session.update(text: text, chinese: false, calculator: false, sources: .init(files: files, semantic: semantic))
        #expect(session.results == nil)
        session.cancel()
    }

    @Test func `names publish first and keep choice when content arrives`() async throws {
        let files = AskTestFileIndex([("/work/reimbursement.md", .file, 0)])
        let semantic = SemanticDelayedSearch(hits: [hit]), session = AskQuickSearchSession()
        defer { session.cancel() }
        session.update(
            text: "reimbursement",
            chinese: false,
            calculator: false,
            sources: .init(files: files, semantic: semantic)
        )
        try await SemanticFileServiceTests.wait { session.results?.files.isEmpty == false }
        #expect(session.results?.files.first?.name == "reimbursement.md")
        #expect(session.isSearching, "names do not wait for the slower embedding worker")
        session.results?.highlight(0)
        let initial = try #require(session.results)
        let selected = try #require(initial.file(at: initial.highlightedRow)?.path)
        let best = session.results?.best
        try await SemanticFileServiceTests.wait { !session.isSearching }
        #expect(session.results?.files.count == 2)
        let final = try #require(session.results)
        #expect(final.file(at: final.highlightedRow)?.path == selected)
        #expect(session.results?.best == best, "content scores must not change the filename Return rule")
    }

    @Test func chosenFolderSurvivesTheSeparateFolderDisplayLimit() async throws {
        let names = [
            AskFileHit(path: "/work/a", name: "a", kind: .folder, modified: Date(), score: 1.4, match: 0.4),
            AskFileHit(path: "/work/b", name: "b", kind: .folder, modified: Date(), score: 1.3, match: 0.4),
            AskFileHit(path: "/work/f.txt", name: "f.txt", kind: .file, modified: Date(), score: 1.2, match: 0.4),
            AskFileHit(path: "/work/chosen", name: "chosen", kind: .folder, modified: Date(), score: 1.1, match: 0.4),
            AskFileHit(path: "/work/strong", name: "strong", kind: .folder, modified: Date(), score: 1.0, match: 0.99)
        ]
        let files = AskControlledSearchIndex(), session = AskQuickSearchSession()
        let semantic = SemanticDelayedSearch(hits: [hit])
        files.fileSearch = { _ in names }
        defer { session.cancel() }
        session.update(text: "guide", chinese: false, calculator: false, sources: .init(files: files, semantic: semantic))
        try await SemanticFileServiceTests.wait { session.results?.files.contains(where: { $0.path == "/work/chosen" }) == true }
        let initial = try #require(session.results)
        let row = try #require(initial.rows.firstIndex { initial.file(at: $0)?.path == "/work/chosen" })
        session.results?.highlight(row)
        try await SemanticFileServiceTests.wait { !session.isSearching }
        let final = try #require(session.results)
        #expect(final.file(at: final.highlightedRow)?.path == "/work/chosen")
    }

    @Test func `fusion deduplicates and preserves original name score`() {
        var name = hit; name.evidence = nil; name.score = 1.08; name.match = 0.99
        let merged = SemanticFilePolicy.merge([name], [hit], limit: 10)
        #expect(merged.count == 1 && merged.first?.evidence == hit.evidence); #expect(merged.first?.score == 1.08)
        #expect(SemanticFilePolicy.merge([name], [hit], limit: 0).isEmpty)
        #expect(AskQuickResults.bestRow("guide", apps: [], panes: [], files: [hit]) == nil)
        #expect(AskQuickResults.bestRow("guide", apps: [], panes: [], files: [name, hit]) == .file(0))
        var weak = name
        weak.score = 0.5; weak.match = 0.4
        let others = (0..<4).map { index in
            AskFileHit(path: "/work/\(index).txt", name: "\(index).txt", kind: .file, modified: Date(), score: 0.6)
        }
        let promoted = SemanticFilePolicy.merge(others + [weak], [hit], limit: 10)
        #expect(promoted.first { $0.path == weak.path }?.score == weak.score,
                "a semantic duplicate must preserve even a weak filename hit beyond the initial three rows")
        let folders = (0..<6).map { index in
            AskFileHit(path: "/work/folder\(index)", name: "folder\(index)", kind: .folder, modified: Date(),
                       score: 1.5 - Double(index) * 0.1, match: index < 3 ? 0.5 : 0.99)
        }
        let fused = SemanticFilePolicy.merge(folders, [hit], limit: 20)
        #expect(AskQuickResults.assemble("guide", matches: [], hits: fused, status: nil, settings: .init())?.best == nil,
                "content must not promote a folder over the previous highest-scoring filename hits")
    }

    @Test func `file plugin publishes names then content with actions`() async throws {
        let semantic = SemanticDelayedSearch(hits: [hit])
        let files = AskTestFileIndex([("/work/reimbursement.md", .file, 0)])
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { semantic })
        let request = AskPluginRequest(
            text: "reimbursement",
            origin: .argument,
            keyword: AskFileSearchPlugin.keywords[0],
            options: [:],
            interfaceLanguage: .english
        )
        var partials: [AskPluginOutput] = []
        let output = try await plugin.run(request, plan: plugin.plan(request), progress: { partials.append($0) })
        #expect(partials.first?.items.map(\.title) == ["reimbursement.md"])
        #expect(partials.first?.selected?.title == "reimbursement.md")
        #expect(output.items.map(\.title) == ["reimbursement.md", "guide.pdf"])
        #expect(output.items[1].subtitle.contains("3"))
        #expect(output.items[1].badge == L("semantic.result"))
        #expect(output.items[1].excerpt == "Reimbursement requests use the expense form")
        #expect(output.items[0].badge == nil && output.items[0].excerpt == nil)
        #expect(output.items[1].actions.contains {
            if case .reveal = $0.kind {
                true
            } else {
                false
            }
        })
        let folderRequest = AskPluginRequest(
            text: "reimbursement",
            origin: .argument,
            keyword: AskFileSearchPlugin.keywords[0],
            options: [AskFileSearchPlugin.typeOption: "folder"],
            interfaceLanguage: .english
        )
        _ = try await plugin.run(folderRequest, plan: plugin.plan(folderRequest), progress: { _ in })
        #expect(await semantic.calls == 1)
        let off = AskFileSearchPlugin(index: { nil }, settings: { .init() }, semantic: { semantic })
        _ = try await off.run(request, plan: off.plan(request), progress: { _ in })
        #expect(await semantic.calls == 1)
    }

    @Test func `content matches leave breathing room and preserve preview evidence`() throws {
        #expect(AskFileSearchPlugin.passage("  Line one\n\n  line\ttwo ") == "Line one line two")
        #expect(AskFileSearchPlugin.passage("请在 15 个工作日内提交申请，\n并附上发票") == "请在 15 个工作日内提交申请，并附上发票")
        #expect(AskFileSearchPlugin.passage("见附件\nPDF") == "见附件 PDF")
        var paged = hit
        paged.evidence?.page = nil
        let item = AskFileSearchPlugin.item(paged)
        #expect(item.subtitle == "/work" && item.excerpt == hit.evidence?.text)
        #expect(!AskPluginItemRow.showsExcerpt(item))
        #expect(AskQuickResultsView.contentFileHeight > AskQuickResultsView.fileHeight)
        #expect(AskPluginResultsView.itemHeight(item) == 54)
        #expect(AskTheme.launcherResultDetailSize == 10.5)
        #expect(AskPluginItemRow.showsExcerpt(AskPluginItem(id: "description", title: "Other", excerpt: "Details")))
        let plain = AskPluginItem(id: "a", title: "a")
        #expect(AskPluginResultsView.itemsHeight([plain, plain]) == AskPluginResultsView.itemsHeight(2))
        #expect(AskPluginResultsView.itemsHeight([plain, item]) == AskPluginResultsView.itemHeight
            + AskPluginResultsView.contentItemHeight + AskPluginResultsView.itemSpacing)
        let many = Array(repeating: item, count: AskPluginResultsView.maximumVisibleItems + 3)
        #expect(AskPluginResultsView.itemsHeight(many) == CGFloat(AskPluginResultsView.maximumVisibleItems)
            * AskPluginResultsView.contentItemHeight
            + CGFloat(AskPluginResultsView.maximumVisibleItems - 1) * AskPluginResultsView.itemSpacing)

        var name = hit; name.evidence = nil; name.path = "/work/guide-name.pdf"
        let results = try #require(AskQuickResults.assemble("guide", matches: [], hits: [name, hit], status: nil,
                                                            settings: .init()))
        let rows = results.listRows.filter { results.file(at: $0) != nil }
        let heights = rows.map { AskQuickResultsView.rowHeight($0, in: results) }
        #expect(heights.sorted() == [AskQuickResultsView.fileHeight, AskQuickResultsView.contentFileHeight])
        #expect(AskQuickResultsView.rowHeight(rows[0]) == AskQuickResultsView.fileHeight)
    }
}

extension SemanticHybridSearchTests {
    @Test(arguments: [false, true])
    func validatedContentSelectsTheFirstResultWhileNamesArePending(requireApps: Bool) async throws {
        let gate = DispatchSemaphore(value: 0)
        let files = AskControlledSearchIndex(), apps = AskControlledSearchIndex()
        files.fileSearch = { _ in
            _ = gate.wait(timeout: .now() + 5)
            return [AskQuickSearchSessionTests.file]
        }
        let semantic = SemanticDelayedSearch(hits: [hit])
        let session = AskQuickSearchSession(publicationGrace: .seconds(5))
        session.fileDebounce = .zero
        defer { gate.signal(); session.cancel() }
        session.update(text: "guide", chinese: false, calculator: false,
                       sources: .init(apps: requireApps ? apps : nil, files: files, semantic: semantic))
        try await SemanticFileServiceTests.wait { session.results?.files.contains(hit) == true }
        #expect(session.isSearching, "validated body results must not wait for the blocked filename worker")
        #expect(session.results?.best == nil)
        #expect(session.results?.highlightedRow == .file(0))
        gate.signal()
        try await SemanticFileServiceTests.wait { !session.isSearching }
        #expect(session.results?.files == [AskQuickSearchSessionTests.file, hit])
        #expect(session.results?.best == .file(0), "only the filename match earns best-match status")
    }
}
