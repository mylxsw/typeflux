import Foundation
import Testing
@testable import Typeflux

@Suite("Media service scheduling and recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticMediaServiceTests {
    private func fixture(idle: Bool, mediaFailure: Bool = false,
                         idleCheck: (@Sendable () -> Bool)? = nil) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureWatcher, SemanticMediaFixtureReader,
            SemanticFixtureEncoder) {
        let (original, root, _, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = ["image.png", "document.md"]
        let media = SemanticFixtureMediaEncoder(), watcher = SemanticFixtureWatcher()
        let encoder = SemanticFixtureEncoder()
        if mediaFailure { media.before = { _ in throw URLError(.badServerResponse) } }
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false },
            thermalConstrained: { false }, models: models,
            mediaModels: SemanticMediaFixtureModels(source: models.source), idle: idleCheck ?? { idle },
            makeMediaEncoder: { _, _, _ in media }, makeReader: { reader },
            makeEncoder: { _, _ in encoder }, makeQuery: { _, _ in SemanticFixtureQuery() })
        return (service, root, watcher, reader, encoder)
    }

    @Test func documentsStaySearchableWhileMediaWaitsForIdle() async throws {
        let (service, root, _, _, _) = try fixture(idle: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.indexProgress?.waitingForIdle == true }
        #expect(service.isEnabled)
        #expect(service.status().tone == .ready)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.name) == ["document.md"])
        service.pause(true)
        try await SemanticFileServiceTests.wait { service.phase == .paused }
        #expect(!service.isEnabled, "manual pause keeps the existing content-search policy")
        await service.clear(removeModel: true)
    }

    @Test func mediaFailureDoesNotInvalidateTheTextModelOrDocumentIndex() async throws {
        let (service, root, _, _, _) = try fixture(idle: true, mediaFailure: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        #expect(service.mediaFailed && service.modelReady && service.isEnabled)
        #expect(service.status().action == .retry)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.name) == ["document.md"])
        #expect(FileManager.default.fileExists(atPath: service.mediaModelURL.path))
        #expect(service.storage().model > 0)
        await service.clear(removeModel: true)
        #expect(!FileManager.default.fileExists(atPath: service.mediaModelURL.path))
    }

    @Test func idleWaitingDoesNotRetainADiscardedService() async throws {
        var context: (SemanticFileSearchService, URL, SemanticFixtureWatcher,
                      SemanticMediaFixtureReader, SemanticFixtureEncoder)? = try fixture(idle: false)
        let root = try #require(context?.1)
        defer { try? FileManager.default.removeItem(at: root) }
        var service = context?.0
        context = nil
        weak let reference = service
        #expect(service?.setEnabled(true) == true)
        try await SemanticFileServiceTests.wait { reference?.indexProgress?.waitingForIdle == true }
        // Only the worker's weak progress callbacks remain.
        service = nil
        try await SemanticFileServiceTests.wait { reference == nil }
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func changedDocumentWaitsForMediaWithoutRestartingTheHomeScan() async throws {
        let gate = AskSearchCancellation()
        let (service, root, watcher, reader, encoder) = try fixture(idle: false,
            idleCheck: { gate.isCancelled })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.indexProgress?.waitingForIdle == true }
        let crawls = reader.directoryReads
        #expect(encoder.calls == 1)
        service.setForegroundBusy(true)
        #expect(service.phase == .paused)
        service.setForegroundBusy(false)
        #expect(service.phase == .indexing && reader.directoryReads == crawls)
        reader.modifiedByName["document.md"] = reader.modified.addingTimeInterval(1)
        watcher.change?([.init(path: root.path + "/document.md", rescan: false, isDirectory: false)], 1)
        try await Task.sleep(for: .milliseconds(2_250))
        #expect(service.indexProgress?.waitingForIdle == true)
        #expect(reader.directoryReads == crawls && encoder.calls == 1)
        gate.cancel()
        try await SemanticFileServiceTests.wait { encoder.calls == 2 && service.phase == .ready }
        #expect(reader.directoryReads == crawls)
        #expect(service.indexedCounts.images == 1)
        await service.clear(removeModel: true)
    }
}
