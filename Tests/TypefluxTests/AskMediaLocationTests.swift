import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxMediaRuntime

@MainActor private final class MediaLocationSearch: SemanticFileSearching {
    var isEnabled = true
    let hit: AskFileHit
    init(_ hit: AskFileHit) { self.hit = hit }
    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] { [hit] }
}

@Suite("Media time actions and native open capability", .exclusiveUIState)
@MainActor
struct AskMediaLocationTests {
    private func indexedHit(_ root: URL) throws -> AskFileHit {
        let url = root.appendingPathComponent("short-scene.mov")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/validation/gul-383/optimization/video-frames/short-scene.mov")
        try FileManager.default.copyItem(at: source, to: url)
        let reader = AskFileReader(); defer { reader.stop() }
        let info = try reader.read(.init(operation: .content, path: url.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let gen = try store.beginMediaJob(path: url.path, metadata: info)
        // Reuse the known blue-frame identity/time established by PR638's real decode tests.
        try store.saveMediaSegment(path: url.path, generation: gen, ordinal: 0,
            input: .init(kind: .image, path: "fixture", time: 1.5, endTime: 1.5), vector: semanticVector())
        #expect(try store.commitMediaJob(path: url.path, generation: gen, metadata: info, segments: 1))
        let reopened = try SemanticFileStore(url: store.url)
        return try #require(reopened.search(vector: semanticVector(), text: "video", query: .init("video"),
            type: .all, scope: semanticScope(root.path), limit: 5, cancelled: { false }).first)
    }

    @Test func `native keys preserve the persisted media time through both entry actions`() async throws {
        let root = try semanticFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = try indexedHit(root)
        #expect(hit.evidence?.time == 1.5 && hit.evidence?.version != nil && hit.evidence?.chunkID != nil)
        for files in [false, true] {
            for specifiedApplication in [false, true] {
                try await exerciseLauncher(hit, root: root, files: files, specifiedApplication: specifiedApplication)
            }
        }
    }

    private func exerciseLauncher(_ hit: AskFileHit, root: URL, files: Bool, specifiedApplication: Bool) async throws {
        var looked: [AskFileHit] = [], previewed: [AskFileHit] = [], notices: [String] = [], opened: [URL] = []
        var applications: [URL] = []
        let service = MediaLocationSearch(hit)
        let launcher = try await AskQuickResultsInteractionTests.Launcher(
            text: (files ? "f " : "") + "video",
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
        #expect(looked == [hit] && notices.last == L("ask.quick.file.media.quickLook"))
        let count = previewed.count
        try await launcher.press(124) // Right opens the selected file's actions.
        try await launcher.press(125) // View Match Location.
        try await launcher.press(36)
        #expect(previewed.count > count && previewed.last == hit && launcher.dismissed == 0)
        if specifiedApplication { try await launcher.press(36, .option) }
        try await launcher.press(36)
        #expect(applications.count == (specifiedApplication ? 1 : 0))
        #expect(opened == [hit.url] && launcher.dismissed == 1)
        #expect(notices.last == L("ask.quick.file.media.open"))
    }

    @Test func nativePreviewChecksTimeVersionAndFallbackInBothAppearances() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let hit = try indexedHit(root)
        let info = try await AskFilePreviewRenderer.metadata(hit, readText: false)
        let worker = MediaWorker(timeout: 3)
        let content = try await AskFilePreviewRenderer.generate(
            hit, kind: .video, pixels: CGSize(width: 400, height: 400), info: info, worker: worker)
        #expect(content.startTime == 1.5 && content.images.count == 1)
        for version in [nil, "obsolete"] as [String?] {
            var stale = hit; stale.evidence?.version = version
            let fallback = try await AskFilePreviewRenderer.generate(
                stale, kind: .video, pixels: CGSize(width: 400, height: 400), info: info, worker: worker)
            #expect(fallback.startTime == 0)
        }
        for time in [-1, Double.nan, Double.infinity, 99] {
            var invalid = hit; invalid.evidence?.time = time
            _ = AskFileSearchPlugin.item(invalid) // Invalid timestamps cannot trap while listing actions.
            let fallback = try await AskFilePreviewRenderer.generate(
                invalid, kind: .video, pixels: CGSize(width: 400, height: 400), info: info, worker: worker)
            #expect(fallback.startTime == 0)
        }
        var wrongKind = hit; wrongKind.evidence?.segmentKind = "pdf-ocr"
        #expect(wrongKind.mediaPreviewTime(version: info.version) == nil)
        #expect(hit.mediaPreviewTime(version: nil) == nil)
        try await snapshot(content, hit: hit)
    }

    // swiftlint:disable:next function_body_length
    @Test func audioPreviewAndBothActionRoutesKeepTimeAndRevokeOwnership() async throws {
        let fixture = try AskTestFixture(); defer { fixture.model.resetSession() }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recording.wav")
        let samples = (0 ..< 32000).map { Float(sin(Double($0) * 0.17) * 0.1) }
        try samples.withUnsafeBytes { try SemanticMediaExtractor.wave(Data($0), to: file) }
        let reader = AskFileReader(); defer { reader.stop() }
        let info = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let hit = AskFileHit(path: file.path, name: file.lastPathComponent, kind: .file,
            modified: try #require(info.modified),
            score: 1, evidence: .init(text: "", time: 1, version: info.version, chunkID: 42,
                                    segmentKind: "audio-window"))
        let content = try await AskFilePreviewRenderer.generate(hit, kind: .audio,
            pixels: CGSize(width: 400, height: 400), info: info, worker: MediaWorker(timeout: 3))
        #expect(content.startTime == 1 && content.waveform.count == 80)
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
        var settings = fixture.model.launcherSearchSettings
        settings.fileRoots = [root.path]; settings.excludedPaths = []
        fixture.model.modelLibrary.settings.askLauncherSearchSettings = settings
        fixture.model.fileExists = { _ in true }
        var opened: [URL] = [], looked: [AskFileHit] = [], notices: [String] = []
        fixture.model.openURL = { opened.append($0) }
        fixture.model.openFileWith = { url, _ in opened.append(url) }
        fixture.model.quickLookFile = { looked.append($0) }
        fixture.model.passiveNotice = { notices.append($0) }
        #expect(fixture.model.performQuickFileAction(.viewMatch, hit) == .preview(hit))
        #expect(fixture.model.performQuickFileAction(.open, hit) == .close)
        #expect(fixture.model.performQuickFileAction(.openIn(URL(fileURLWithPath: "/Applications/Player.app")), hit)
            == .close)
        #expect(fixture.model.performQuickFileAction(.quickLook, hit) == .stay)
        #expect(opened == [file, file] && looked == [hit])
        #expect(notices == [L("ask.quick.file.media.open"), L("ask.quick.file.media.open"),
                            L("ask.quick.file.media.quickLook")])
        let service = MediaLocationSearch(hit)
        fixture.model.plugins.replacePlugins([AskFileSearchPlugin(index: { AskTestFileIndex() }, settings: { .init() },
            semantic: { service })])
        fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
        fixture.model.plugins.update(text: "recording", selection: nil, language: .english, runWhenPlanned: true)
        try await fixture.wait { fixture.model.selectedPluginFile == hit }
        let actions = try #require(fixture.model.plugins.output?.selected?.actions)
        let view = try #require(actions.first { $0.kind == .fileAction(.viewMatch, hit) })
        #expect(fixture.model.performPluginFileAction(view) == .preview(hit))
        var stale = hit; stale.evidence?.time = 0
        #expect(fixture.model.performPluginFileAction(.init(kind: .fileAction(.viewMatch, stale),
            title: "", symbol: ""))
            == nil)
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: false)
        #expect(fixture.model.performPluginFileAction(view) == .stay)
        fixture.model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
        settings.fileRoots = []; fixture.model.modelLibrary.settings.askLauncherSearchSettings = settings
        #expect(fixture.model.performQuickFileAction(.quickLook, hit) == .stay && looked == [hit])
        fixture.model.plugins.deactivate()
        #expect(fixture.model.performPluginFileAction(view) == nil)
    }

    @Test func embeddedAudioMatchBeyondVideoTrackUsesExistingAudioPreview() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/validation/gul-383/optimization/video-frames/longer-audio.mov")
        let file = root.appendingPathComponent("longer-audio.mov")
        try FileManager.default.copyItem(at: source, to: file)
        let reader = AskFileReader(); defer { reader.stop() }
        let info = try reader.read(.init(operation: .content, path: file.path,
            scope: semanticScope(root.path), readText: false), isCancelled: { false })
        let hit = AskFileHit(path: file.path, name: file.lastPathComponent, kind: .file,
            modified: try #require(info.modified),
            score: 1, evidence: .init(text: "", time: 7, version: info.version, segmentKind: "audio-window"))
        let content = try await AskFilePreviewRenderer.generate(hit, kind: .video,
            pixels: CGSize(width: 400, height: 400), info: info, worker: MediaWorker(timeout: 3))
        #expect(content.kind == .audio && content.startTime == 7 && content.waveform.count == 80)
        var invalid = hit; invalid.evidence?.segmentKind = "video-frame"
        let fallback = try await AskFilePreviewRenderer.generate(invalid, kind: .video,
            pixels: CGSize(width: 400, height: 400), info: info, worker: MediaWorker(timeout: 3))
        #expect(fallback.kind == .video && fallback.startTime == 0)
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
            #expect(try !MediaPreviewOCR.locate(footer, passage: "match location").boxes.isEmpty)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_GUL405_EVIDENCE"] {
                let name = appearance == .aqua ? "media-capability-light.png" : "media-capability-dark.png"
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}
