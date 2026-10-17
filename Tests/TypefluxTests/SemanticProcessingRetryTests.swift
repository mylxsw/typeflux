import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Per-file processing recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticProcessingRetryTests {
    @Test func `broken file retries through native reader and keeps other content`() async throws {
        let (original, root, _, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("broken.txt"), good = root.appendingPathComponent("reference.txt")
        try Data([0xFF, 0xFE, 0xFF]).write(to: bad)
        try "referencezebra".write(to: good, atomically: true, encoding: .utf8)
        let indexRoot = root.appendingPathComponent("index-data")
        try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: models.source, to: indexRoot.appendingPathComponent(original.modelURL.lastPathComponent))
        let service = SemanticFileSearchService(settings: original.settings, directory: indexRoot,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: SemanticFixtureWatcher(),
                                                access: { true }, automaticStart: false, budgetEnabled: false,
                                                lowPowerMode: { false }, thermalConstrained: { false }, models: models,
                                                makeReader: { AskFileReader() },
                                                makeEncoder: { _, _ in SemanticFixtureEncoder() },
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        #expect(service.setEnabled(true))
        let deadline = ContinuousClock.now + .seconds(20)
        while service.phase != .ready, service.phase != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(service.phase == .ready, "Native reader phase: \(service.phase); diagnostics: \(String(describing: service.diagnostics))")
        let store = try SemanticFileStore(url: indexRoot.appendingPathComponent("semantic-files.sqlite"))
        let untouched = try #require(try store.job(good.path))
        let failed = try #require(await service.processingPage(.completed, offset: 0)?.items
            .first { $0.path == bad.path })
        #expect(failed.state == "failed" && failed.reason == "unreadable-content")
        #expect(service.canRetryProcessingItem(failed))
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        try await SemanticFileSearchVisualTests.render(SemanticIndexDetailsView(service: service), width: 780,
                                                       name: "processing-retry")
        try await pressRetry(service)
        try await SemanticFileServiceTests.wait { (try? store.job(bad.path)?.attempts) == 1 && service.phase == .ready }
        #expect(try store.job(bad.path)?.reason == "unreadable-content")
        let repeated = try #require(await service.processingPage(.completed, offset: 0)?.items
            .first { $0.path == bad.path })
        try "repairedzebra".write(to: bad, atomically: true, encoding: .utf8)
        #expect(await service.retryProcessingItem(repeated))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(try store.job(bad.path)?.state == .done)
        #expect(try store.job(bad.path)?.reason == nil)
        #expect(try store.job(good.path)?.generation == untouched.generation)
        let hits = await service.search("repairedzebra")
        #expect(hits.contains { $0.path == bad.path })
        #expect(await service.search("referencezebra").contains { $0.path == good.path })
        #expect(try store.processingPage(.pending, offset: 0).total == 0)
        #expect(try !service
            .canRetryProcessingItem(#require(store.processingPage(.completed, offset: 0).items
                    .first { $0.path == good.path })))
        #expect(
            await !(service.retryProcessingItem(repeated)),
            "old selections cannot retry a replacement generation"
        )
        original.settings.semanticFileSearch = .init(enabled: false)
        #expect(!service.canRetryProcessingItem(failed))
        #expect(await !(service.retryProcessingItem(failed)))
        #expect(await service.processingPage(.completed, offset: 0) == nil)
        await service.clear()
    }

    private func pressRetry(_ service: SemanticFileSearchService) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let host = NSHostingView(rootView: SemanticIndexDetailsView(service: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 780, height: 680), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await SettingsBehaviorTestSupport.wait {
            SettingsBehaviorTestSupport.elements(in: host).contains { $0.label == L("semantic.details.retry") }
        }
        try SettingsBehaviorTestSupport.button(L("semantic.details.retry"), in: host).press()
    }

    @Test func `paused retry resumes only its queue and rejects revoked scope`() async throws {
        let (service, root, reader, _) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true)); await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let path = root.path + "/handbook.txt"
        let old = try #require(try store.job(path))
        try store.failJob(path, reason: "encoding-failed")
        let item = try #require(store.processingPage(.completed, offset: 0).items.first)
        service.pause(true)
        #expect(await service.retryProcessingItem(item))
        #expect(service.phase == .paused)
        #expect(try store.job(path)?.reason == "encoding-failed")
        #expect(try store.processingPage(.pending, offset: 0).total == 1)
        _ = try store.prepareDocument(path: path, metadata: .init(fileSize: 20, modified: reader.modified))
        #expect(try store.processingPage(.pending, offset: 0).items.first?.state == "partial")
        try await SemanticFileSearchVisualTests.render(SemanticIndexDetailsView(service: service), width: 780,
                                                       name: "processing-partial")
        service.pause(false)
        try await SemanticFileServiceTests.wait { (try? store.processingPage(.pending, offset: 0).total) == 0 }
        #expect(try store.job(path)?.state == .done && store.job(path)?.generation == old.generation)
        try store.failJob(path, reason: "reader-failed")
        let next = try #require(store.processingPage(.completed, offset: 0).items.first)
        var names = service.settings.askLauncherSearchSettings
        names.excludedPaths = [path]; service.settings.askLauncherSearchSettings = names
        #expect(!service.canRetryProcessingItem(next))
        #expect(await !(service.retryProcessingItem(next)))
        #expect(try store.processingPage(.pending, offset: 0).total == 0)
        await service.clear()
    }

    @Test func `partial queue survives restart and reuses saved vectors`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("partial.txt")
        try "firstblock tailmarker".write(to: path, atomically: true, encoding: .utf8)
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let reader = AskFileReader(); defer { reader.stop() }
        let metadata = try reader.read(.init(
            operation: .content,
            path: path.path,
            scope: semanticScope(root.path),
            readText: false
        ))
        let job = try store.prepareDocument(path: path.path, metadata: metadata)
        #expect(try store.publish([.init(text: "firstblock", page: nil)], next: .init(offset: 11), job: job))
        let work = try store.vectorWork(job)
        #expect(try store.publishVectors([semanticVector()], work: work, job: job))
        try store.failJob(path.path, reason: "reader-failed")
        let item = try #require(store.processingPage(.completed, offset: 0).items.first)
        #expect(item.offset == 11 && item.savedChunks == 1 && item.encodedChunks == 1)
        #expect(try !(store.retryProcessingItem(item, cancelled: { true })))
        #expect(try store.retryProcessingItem(item, cancelled: { false }))
        #expect(try store.retryProcessingItem(item, cancelled: { false }))
        let reopened = try SemanticFileStore(url: store.url)
        #expect(try reopened.processingPage(.pending, offset: 0).total == 1)
        #expect(try reopened.job(path.path)?.reason == "reader-failed")
        let encoder = SemanticFixtureEncoder()
        _ = try SemanticFileIndexer.reconcile(paths: [], scope: semanticScope(root.path), store: reopened,
                                              reader: reader, encoder: encoder, cancelled: { false },
                                              progress: { _ in })
        #expect(try reopened.job(path.path)?.generation == job.generation)
        #expect(try reopened.job(path.path)?.state == .done)
        #expect(encoder.calls == 1, "only the missing tail is encoded")
        #expect(try reopened.processingPage(.completed, offset: 0).items.first?.encodedChunks == 2)
        #expect(try !reopened.retryProcessingItem(item, cancelled: { false }))
    }

    @Test func `media details keep independent durable progress without publishing staging`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let path = root.path + "/video.mov"
        let generation = try store.beginMediaJob(
            path: path,
            metadata: .init(fileSize: 10, modified: Date(), version: "one")
        )
        let other = root.path + "/queued.txt"
        try store.enqueue([(other, .document), (path, .video)])
        try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                   input: .init(kind: .image, path: "fixture", time: 1.5, endTime: 1.5),
                                   vector: semanticVector(),
                                   videoProgress: .init(next: 2, actual: 1.5, reference: Data(count: 1024)))
        try store.saveAudioProgress(path: path, generation: generation, progress: .init(next: 25.0, covered: 30.0))
        let item = try #require(store.processingPage(.pending, offset: 0).items.first { $0.path == path })
        #expect(item.state == "partial" && item.queued && item.canRetry)
        #expect(item.audioCovered == 30)
        #expect(item.videoChecked == 1.5)
        #expect(item.savedMediaSegments == 1)
        let cursor = try store.mediaCursor(path: path, generation: generation)
        #expect(cursor.audioCoveredUntil == 30 && cursor.videoProgress?.actual == 1.5)
        #expect(item.savedChunks == 0 && item.encodedChunks == 0)
        #expect(try store.retryProcessingItem(item, cancelled: { false }))
        #expect(try store.mediaCursor(path: path, generation: generation).videoFrames == 1)
        #expect(try store.nextWork(.document) == other && store.nextWork(.video) == path)
        #expect(try store.processingPage(.pending, offset: 0).total == 2, "other queue entries survive retry")
        #expect(try store.counts().chunks == 0, "staging is not reported as a published index")
        let stale = item
        _ = try store.beginMediaJob(path: path, metadata: .init(fileSize: 11, modified: Date(), version: "two"))
        #expect(try !store.retryProcessingItem(stale, cancelled: { false }))
        #expect(try !store.publish([.init(text: "obsolete", page: nil)], next: nil,
                                   job: .init(
                                       path: path,
                                       version: "one",
                                       generation: generation,
                                       state: .partial,
                                       cursor: .init(),
                                       extracted: false,
                                       attempts: 0
                                   )))
    }

    @Test func `progress and reasons never expose raw errors or claim completion`() {
        let known = ["password-required", "unsupported-document", "permission-denied", "missing-or-unavailable",
                     "metadata-unavailable", "file-missing-or-changed", "media-missing-or-changed", "empty-or-no-text",
                     "empty-or-no-media", "audio-silent", "encoding-failed", "media-encoding-failed", "pdf-ocr-failed",
                     "image-ocr-failed", "image-no-text", "unreadable-content", "reader-failed", "extraction-failed",
                     "media-extraction-failed", "inconsistent-media-segments"]
        for code in known {
            let key = SemanticProcessingPresentation.reasonKey(code)
            #expect(L(key) != key)
        }
        #expect(SemanticProcessingPresentation
            .reasonKey("private error /Users/person") == "semantic.details.reason.unknown")
        var item = SemanticFileStore.ProcessingItem(path: "/fixture/video.mov", state: "partial", priority: .video,
                                                    bytes: nil, modified: nil, processingSeconds: nil, completedAt: nil,
                                                    page: nil, generation: "one")
        #expect(!SemanticProcessingPresentation.progress(item).contains("%"))
        item.savedChunks = 3; item.encodedChunks = 1; item.offset = 12
        item.savedMediaSegments = 2; item.audioCovered = 25; item.videoChecked = 1.5
        #expect(item.canRetry && item.displayState == "partial")
        #expect(!SemanticProcessingPresentation.progress(item).contains("%"))
        item.state = "failed"; item.reason = "password-required"
        #expect(!item.canRetry)
        item.reason = "unsupported-document"; #expect(!item.canRetry)
        item.queued = true; #expect(item.displayState == "pending")
        item.queued = false; item.state = "done"; item.reason = "audio-silent"
        #expect(item.displayState == "skipped")
    }
}
