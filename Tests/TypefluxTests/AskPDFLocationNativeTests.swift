import AppKit
import CoreText
import ImageIO
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxMediaRuntime

@MainActor private final class PDFNativeSearch: SemanticFileSearching {
    var isEnabled = true
    let hit: AskFileHit
    init(_ hit: AskFileHit) { self.hit = hit }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] { [hit] }
}

@Suite("PDF native open capability", .exclusiveUIState)
@MainActor
struct AskPDFLocationNativeTests {
    private func indexedHit(_ root: URL) throws -> AskFileHit {
        let url = root.appendingPathComponent("invoice.pdf")
        var box = CGRect(x: 0, y: 0, width: 500, height: 500)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["First page", "Invoice INV-739204 approved", "Last page"] {
            pdf.beginPDFPage(nil)
            pdf.textPosition = CGPoint(x: 30, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            ])), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(timeout: 10)
        defer { reader.stop() }
        var state: SemanticFileStore.JobState = .partial
        for _ in 0 ..< 4 where state == .partial {
            state = try SemanticFileIndexer.index(url.path, scope: semanticScope(root.path), store: store,
                                                 reader: reader, encoder: SemanticFixtureEncoder(), media: nil,
                                                 cancelled: { false }, checkpoint: {}, waitForIdle: {})
        }
        #expect(state == .done)
        return try #require(store.lexicalSearch(text: "INV-739204", query: .init("INV-739204"), type: .pdf,
                                               scope: semanticScope(root.path), limit: 5, cancelled: { false }).first)
    }

    @Test func `native keys preserve the persisted PDF hit through both entry actions`() async throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = try indexedHit(root)
        #expect(hit.evidence?.page == 2 && hit.evidence?.version != nil && hit.evidence?.chunkID != nil)
        for files in [false, true] {
            for specifiedApplication in [false, true] {
                try await exerciseLauncher(hit, root: root, files: files, specifiedApplication: specifiedApplication)
            }
        }
    }

    private func exerciseLauncher(_ hit: AskFileHit, root: URL, files: Bool, specifiedApplication: Bool) async throws {
        var looked: [AskFileHit] = [], previewed: [AskFileHit] = [], notices: [String] = [], opened: [URL] = []
        var applications: [URL] = []
        let service = PDFNativeSearch(hit)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: (files ? "f " : "") + "INV-739204",
            onFilePreview: { hit, _, _ in if let hit { previewed.append(hit) } },
            prepare: { model in
                model.semanticSearch = service
                model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
                var settings = model.launcherSearchSettings
                settings.fileRoots = [root.path]; settings.excludedPaths = []
                model.modelLibrary.settings.askLauncherSearchSettings = settings
                model.fileExists = { FileManager.default.fileExists(atPath: $0) }
                model.quickLookFile = { looked.append($0) }
                model.passiveNotice = { notices.append($0) }
                model.openURL = { opened.append($0) }
                model.openFileWith = { file, app in opened.append(file); applications.append(app) }
            }
        )
        defer { launcher.close() }
        try await SettingsBehaviorTestSupport.wait {
            if files { return launcher.fixture.model.selectedPluginFile == hit }
            return launcher.fixture.model.quickSearch.results?.files == [hit]
        }
        if !files {
            #expect(launcher.fixture.model.quickSearch.results?.best == nil)
            try await launcher.press(125) // Content-only matches require explicit selection.
        }
        try await launcher.press(16, .command) // Command-Y.
        #expect(looked == [hit] && notices.last == L("ask.quick.file.pdf.quickLook"))
        let count = previewed.count
        try await launcher.press(124) // Right opens the selected file's actions.
        try await launcher.press(125) // View Match Location.
        try await launcher.press(36)
        #expect(previewed.count > count && previewed.last == hit && launcher.dismissed == 0)
        if specifiedApplication { try await launcher.press(36, .option) }
        try await launcher.press(36)
        #expect(applications.count == (specifiedApplication ? 1 : 0))
        #expect(opened == [hit.url] && launcher.dismissed == 1)
        #expect(notices.last == L("ask.quick.file.pdf.open"))
    }

    @Test func `native PDF preview drops obsolete pages and renders the capability in both appearances`() async throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = try indexedHit(root)
        let info = try await AskFilePreviewRenderer.metadata(hit, readText: false)
        let worker = MediaWorker(timeout: 3)
        let content = try await AskFilePreviewRenderer.generate(
            hit, kind: .pdf, pixels: CGSize(width: 500, height: 500), info: info, worker: worker
        )
        #expect(content.pageNumbers == [2])
        for version in [nil, "obsolete"] as [String?] {
            var stale = hit
            stale.evidence?.version = version
            let fallback = try await AskFilePreviewRenderer.generate(
                stale, kind: .pdf, pixels: CGSize(width: 500, height: 500), info: info, worker: worker
            )
            #expect(fallback.pageNumbers == [1, 2, 3])
        }
        for page in [0, 99] {
            var invalid = hit
            invalid.evidence?.page = page
            let fallback = try await AskFilePreviewRenderer.generate(
                invalid, kind: .pdf, pixels: CGSize(width: 500, height: 500), info: info, worker: worker
            )
            #expect(fallback.pageNumbers == [1, 2, 3])
        }
        try await snapshot(content, hit: hit)
    }

    private func snapshot(_ content: AskFilePreviewContent, hit: AskFileHit) async throws {
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(language) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let state = AskFilePreviewState()
            state.hit = hit; state.content = content; state.detail = content.detail
            let host = NSHostingView(rootView: AskFilePreviewView(state: state)
                .frame(width: 400, height: 540)
                .environment(\.interfaceStyle, .classic)
                .environment(\.colorScheme, appearance == .aqua ? .light : .dark))
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 540),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            window.appearance?.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let footer = try #require(image.cropping(to: CGRect(x: 0, y: 478, width: 400, height: 40)))
            #expect(try !MediaPreviewOCR.locate(footer, passage: "Check the match location here").boxes.isEmpty)
            #expect(try !MediaPreviewOCR.locate(image, passage: "INV-739204").boxes.isEmpty)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_PDF_ACTION_EVIDENCE"] {
                let name = appearance == .aqua ? "capability-light.png" : "capability-dark.png"
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}
