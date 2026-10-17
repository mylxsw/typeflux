import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Typeflux

@MainActor private final class PDFActionSearch: SemanticFileSearching {
    var isEnabled = true
    let hit: AskFileHit
    init(_ hit: AskFileHit) { self.hit = hit }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] { [hit] }
}

@Suite("PDF location action routes", .exclusiveUIState)
@MainActor
struct AskPDFLocationActionTests {
    @Test func `persistent PDF hit reaches both open routes with the same page and version`() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invoice.pdf")
        var rect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &rect, nil))
        for value in ["Unrelated first page", "Invoice INV-739204 approved"] {
            pdf.beginPDFPage(nil); pdf.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString,
                                                                                             20, nil)
            ])), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(timeout: 10); defer { reader.stop() }
        var state: SemanticFileStore.JobState = .partial
        for _ in 0 ..< 4 where state == .partial {
            state = try SemanticFileIndexer.index(url.path, scope: semanticScope(root.path), store: store,
                                                  reader: reader, encoder: SemanticFixtureEncoder(), media: nil,
                                                  cancelled: { false }, checkpoint: {}, waitForIdle: {})
        }
        #expect(state == .done)
        let hit = try #require(store.lexicalSearch(text: "INV-739204", query: .init("INV-739204"), type: .pdf,
                                                   scope: semanticScope(root.path), limit: 5, cancelled: { false })
                                                   .first)
        #expect(hit.evidence?.page == 2 && hit.evidence?.version != nil && hit.evidence?.chunkID != nil)
        let (fixture, _) = try makeFixture(); defer { fixture.model.resetSession() }
        var settings = fixture.model.launcherSearchSettings; settings.fileRoots = [root.path]
        fixture.model.modelLibrary.settings.askLauncherSearchSettings = settings
        fixture.model.openURL = { #expect($0 == url && $0.fragment == nil) }
        fixture.model.passiveNotice = { #expect($0 == L("ask.quick.file.pdf.open")) }
        #expect(fixture.model.performQuickFileAction(.viewMatch, hit) == .preview(hit))
        #expect(fixture.model.performQuickFileAction(.open, hit) == .close)
        let service = PDFActionSearch(hit)
        fixture.model.plugins.replacePlugins([AskFileSearchPlugin(index: { AskTestFileIndex() }, settings: { .init() },
                                                                  semantic: { service })])
        fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
        fixture.model.plugins.update(text: "INV-739204", selection: nil, language: .english, runWhenPlanned: true)
        try await fixture.wait { fixture.model.plugins.output?.selected?.fileHit == hit }
        let action = try #require(fixture.model.plugins.output?.action(for: .enter))
        #expect(action.kind == .fileAction(.open, hit))
        #expect(fixture.model.performPluginAction(action) == .close)
        if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_PDF_ACTION_EVIDENCE"] {
            try FileManager.default.copyItem(at: url,
                                             to: URL(fileURLWithPath: folder).appendingPathComponent("invoice.pdf"))
        }
    }

    private func makeFixture() throws -> (AskTestFixture, AskFileHit) {
        let fixture = try AskTestFixture()
        var settings = fixture.model.launcherSearchSettings
        settings.fileRoots = [fixture.root.path]; settings.excludedPaths = []
        fixture.model.modelLibrary.settings.askLauncherSearchSettings = settings
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
        fixture.model.fileExists = { _ in true }
        let hit = AskFileHit(path: fixture.root.appendingPathComponent("invoice.pdf").path, name: "invoice.pdf",
                             kind: .file, modified: Date(), score: 1,
                             evidence: .init(text: "INV-739204", page: 2, version: "stored-version", chunkID: 42,
                                             segmentKind: "pdf-ocr"))
        return (fixture, hit)
    }

    @Test func `mixed actions preserve evidence and safely fall back without claiming a page jump`() throws {
        let (fixture, hit) = try makeFixture(); defer { fixture.model.resetSession() }
        var opened: [URL] = [], applications: [URL] = [], previews: [AskFileHit] = [], notices: [String] = []
        fixture.model.openURL = { opened.append($0) }
        fixture.model.openFileWith = { url, app in opened.append(url); applications.append(app) }
        fixture.model.quickLookFile = { previews.append($0) }
        fixture.model.passiveNotice = { notices.append($0) }
        let app = URL(fileURLWithPath: "/System/Applications/Preview.app")
        #expect(AskQuickActionPanel.make(for: .file(hit))?.actions.contains(.viewMatch) == true)
        #expect(AskQuickAction.viewMatch.title == L("ask.quick.action.viewMatch"))
        #expect(AskQuickAction.viewMatch.symbol == "text.viewfinder" && AskQuickAction.viewMatch.shortcut == nil)
        #expect(fixture.model.performQuickFileAction(.viewMatch, hit) == .preview(hit))
        #expect(fixture.model.performQuickFileAction(.quickLook, hit) == .stay)
        #expect(previews == [hit])
        #expect(fixture.model.performQuickFileAction(.open, hit) == .close)
        #expect(fixture.model.performQuickFileAction(.openIn(app), hit) == .close)
        #expect(opened == [hit.url, hit.url] && applications == [app])
        #expect(notices == [
            L("ask.quick.file.pdf.quickLook"),
            L("ask.quick.file.pdf.open"),
            L("ask.quick.file.pdf.open")
        ])
        for page in [0, -1, Int.max] {
            var invalid = hit; invalid.evidence?.page = page; invalid.evidence?.version = nil
            #expect(fixture.model.performQuickFileAction(.open, invalid) == .close)
            #expect(notices.last == L("ask.quick.file.pdf.open"))
        }
        var ordinary = hit; ordinary.evidence = nil
        let count = notices.count
        #expect(fixture.model.performQuickFileAction(.open, ordinary) == .close)
        #expect(fixture.model.performQuickFileAction(.viewMatch, ordinary) == .stay)
        #expect(notices.count == count)
        #expect(AskQuickActionPanel.make(for: .file(ordinary))?.actions.contains(.viewMatch) == false)
        fixture.model.fileExists = { _ in false }
        #expect(fixture.model.performQuickFileAction(.viewMatch, hit) == .stay)
    }

    @Test func `file plugin actions own the current hit and revoke stale or unauthorized selections`() async throws {
        let (fixture, hit) = try makeFixture(); defer { fixture.model.resetSession() }
        var opened: [URL] = [], notices: [String] = [], looked: [AskFileHit] = []
        fixture.model.openURL = { opened.append($0) }; fixture.model.passiveNotice = { notices.append($0) }
        fixture.model.quickLookFile = { looked.append($0) }
        let service = PDFActionSearch(hit)
        let plugin = AskFileSearchPlugin(index: { AskTestFileIndex() }, settings: { .init() }, semantic: { service })
        fixture.model.plugins.replacePlugins([plugin])
        func load() async throws {
            fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
            fixture.model.plugins.update(text: "INV-739204", selection: nil, language: .english, runWhenPlanned: true)
            try await fixture.wait { fixture.model.plugins.output?.selected?.fileHit == hit }
        }
        try await load()
        let actions = try #require(fixture.model.plugins.output?.selected?.actions)
        let view = try #require(actions.first { $0.kind == .fileAction(.viewMatch, hit) })
        let open = try #require(actions.first { $0.kind == .fileAction(.open, hit) })
        let quickLook = try #require(actions.first { $0.kind == .fileAction(.quickLook, hit) })
        #expect(fixture.model.performPluginFileAction(view) == .preview(hit))
        #expect(fixture.model.performPluginAction(quickLook) == .stay && looked == [hit])
        var stale = hit; stale.evidence?.page = 99
        #expect(fixture.model
            .performPluginFileAction(.init(kind: .fileAction(.open, stale), title: "", symbol: "")) == nil)
        #expect(fixture.model.performPluginAction(open) == .close && opened == [hit.url])
        try await load()
        fixture.model.openFileInApplication = { _, _ in false }
        #expect(fixture.model.performPluginAction(.init(kind: .openIn(hit.url, application: "missing.reader"),
                                                        title: "", symbol: "")) == .close)
        #expect(opened == [hit.url, hit.url] && notices.last == L("ask.quick.file.pdf.open"))
        try await load()
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: false)
        #expect(fixture.model.performPluginFileAction(view) == .stay)
        #expect(fixture.model.performQuickFileAction(.open, hit) == .stay)
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
        var settings = fixture.model.launcherSearchSettings; settings.fileRoots = []
        fixture.model.modelLibrary.settings.askLauncherSearchSettings = settings
        #expect(fixture.model.performQuickFileAction(.quickLook, hit) == .stay && looked == [hit])
        fixture.model.plugins.deactivate()
        #expect(fixture.model.performPluginFileAction(open) == nil && fixture.model.selectedPluginFile == nil)
    }
}
