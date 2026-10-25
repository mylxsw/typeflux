import AppKit
import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

actor SemanticGatedSearch: SemanticFileSearching {
    let hits: [AskFileHit]
    let delay: Duration
    init(hits: [AskFileHit], delay: Duration = .milliseconds(500)) { self.hits = hits; self.delay = delay }
    func search(_: String, type _: AskFileType, limit: Int) async -> [AskFileHit] {
        try? await Task.sleep(for: delay)
        return Array(hits.prefix(limit))
    }
}

@Suite("Content search without progress rows", .serialized, .exclusiveUIState)
@MainActor
struct SemanticContentSearchProgressTests {
    @Test func mixedSearchKeepsTheChosenNameWhileContentArrives() async throws {
        let files = AskTestFileIndex([("/work/report.md", .file, 0)])
        let hit = AskFileHit(path: "/work/guide.pdf", name: "guide.pdf", kind: .file,
                             modified: Date(), score: 0.7, evidence: .init(text: "report details", page: 4))
        let session = AskQuickSearchSession(), content = SemanticGatedSearch(hits: [hit])
        defer { session.cancel() }
        session.update(text: "report", chinese: false, calculator: false,
                       sources: .init(files: files, semantic: content))
        try await AskQuickSearchSessionTests.wait {
            session.results?.searchingContent == true && !session.results!.files.isEmpty
        }
        let row = try #require(session.results?.rows.firstIndex(of: .file(0)))
        session.results?.highlight(row)
        let selected = session.results?.file(at: session.results!.highlightedRow)?.path
        try await AskQuickSearchSessionTests.wait { !session.isSearching }
        #expect(session.results?.searchingContent == false)
        #expect(session.results?.file(at: session.results!.highlightedRow)?.path == selected)
        #expect(session.results?.files.contains { $0.path == hit.path } == true)
        session.setVisible(false)
        #expect(session.results == nil)
    }

    @Test func fileModeShowsResultsWithoutProgressAndPreservesSelection() async throws {
        let files = AskTestFileIndex([("/work/report-a.md", .file, 0), ("/work/report-b.pdf", .file, 1)])
        let hit = AskFileHit(path: "/work/report-b.pdf", name: "report-b.pdf", kind: .file,
                             modified: Date(), score: 0.7, evidence: .init(text: "matching paragraph", page: 4))
        let semantic = SemanticGatedSearch(hits: [hit])
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { semantic })
        let session = AskPluginSession(plugins: [plugin]) { AskFileSearchPlugin.keywords }
        let context = try #require(CGContext(data: nil, width: 56, height: 56, bitsPerComponent: 8,
                                             bytesPerRow: 224, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.makeImage())
        let iconCache = AskLauncherIconCache(decode: { _ in
            .init(images: [pixels], numbers: [], pages: 0)
        })
        session.launcherIconCache = iconCache
        defer { _ = session.deactivate() }
        session.enter(AskFileSearchPlugin.keywords[0])
        session.update(text: "report", selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { session.partial?.items.count == 2 }
        let firstFile = try #require(session.partial?.items.first?.fileHit)
        try await AskQuickSearchSessionTests.wait {
            iconCache.cached(.init(kind: .file, value: firstFile.path), revision: firstFile.modified) != nil
        }
        #expect(session.partial?.items.map(\.title) == ["report-a.md", "report-b.pdf"])
        #expect(session.selectItem(1))
        #expect(session.partial?.selected?.fileHit?.path == hit.path)
        #expect(session.moveSelection(-1)); #expect(session.moveSelection(1))
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(session.output?.selected?.id == hit.path)
        #expect(session.output?.selected?.fileHit?.evidence?.page == 4)
    }

    @Test func emptyNamesShowContentSearchThenNoResults() async throws {
        let files = AskTestFileIndex([])
        let content = SemanticGatedSearch(hits: [], delay: .milliseconds(150))
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { content })
        let session = AskPluginSession(plugins: [plugin]) { AskFileSearchPlugin.keywords }
        defer { _ = session.deactivate() }
        session.enter(AskFileSearchPlugin.keywords[0])
        session.update(text: "missing", selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { session.partial != nil }
        #expect(session.partial?.items.first?.title == L("ask.plugin.files.content.searching"))
        #expect(session.partial?.selected == nil)
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(session.output?.items.first?.title == L("ask.plugin.files.none"))
        #expect(!session.isRunning)
    }

    @Test func slowContentStopsWaitingAndKeepsFilenameResults() async throws {
        let files = AskTestFileIndex([("/work/report.md", .file, 0)])
        let content = SemanticGatedSearch(hits: [], delay: .seconds(30))
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { content },
                                         contentTimeout: .milliseconds(100))
        let session = AskPluginSession(plugins: [plugin]) { AskFileSearchPlugin.keywords }
        defer { _ = session.deactivate() }
        session.enter(AskFileSearchPlugin.keywords[0])
        session.update(text: "report", selection: nil, language: .english)
        try await AskQuickSearchSessionTests.wait { session.output != nil }
        #expect(!session.isRunning)
        #expect(session.output?.items.first?.fileHit?.name == "report.md")
        #expect(session.output?.note == L("ask.plugin.files.content.timeout"))
    }

    @Test func mediaProgressAndFailureCopyKeepDocumentAvailabilityClear() {
        let download = SemanticFileSearchStatus.of(.init(phase: .indexing, enabled: true, filesEnabled: true,
            modelReady: true, mediaDownload: 0.5))
        #expect(download.progress == .mediaDownload(0.5))
        var summary = SemanticFileIndexer.Summary(); summary.waitingForIdle = true; summary.priority = .image
        let waiting = SemanticFileSearchStatus.of(.init(phase: .indexing, enabled: true, filesEnabled: true,
            modelReady: true, indexProgress: summary))
        #expect(waiting.tone == .ready && waiting.progress == nil)
        let failed = SemanticFileSearchStatus.of(.init(phase: .failed, enabled: true, filesEnabled: true,
            modelReady: true, mediaFailed: true))
        #expect(failed.action == .retry)
        #expect(!SemanticFilePolicy.searchTerms("项目报销流程").contains("项"))
        #expect(SemanticFilePolicy.searchTerms("how to find reimbursement").contains("reimbursement"))
    }
}
