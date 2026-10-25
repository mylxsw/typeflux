import Foundation
import Testing
@testable import Typeflux

@Suite("Media service scheduling and recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticMediaServiceTests {
    @Test(arguments: [false, true])
    func backgroundShutdownCancelsMediaWaitingForIdle(paused: Bool) async throws {
        let (service, root, watcher, _, _) = try fixture(idle: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.indexProgress?.waitingForIdle == true }
        try #require(service.indexProgress?.waitingForIdle == true)
        service.pause(paused)
        let names = AskFileIndex(configuration: { (false, .init()) },
                                 snapshotURL: root.appendingPathComponent("names.bin"), defaults: service.settings.defaults)
        let runtime = FeatureBackgroundRuntime(names: names, content: service)
        do {
            _ = try await runtime.handle(.init(destination: .background, action: "shutdown"))
        } catch {
            await service.shutdown()
            throw error
        }
        #expect(service.phase == .off && !service.isEnabled)
        #expect(watcher.started.isEmpty)
        #expect(!service.readers.indexing.isOccupied && !service.readers.priority.isOccupied)
        #expect(service.settings.semanticFileSearch.enabled)
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("semantic-files.sqlite").path))
        service.start(force: true)
        #expect(service.phase == .off, "Late settings callbacks cannot restart a retired service")
        _ = try await runtime.handle(.init(destination: .background, action: "shutdown"))
    }

    private func fixture(idle: Bool, mediaFailure: Bool = false,
                         idleCheck: (@Sendable () -> Bool)? = nil,
                         mediaBefore: ((SemanticMediaInput) throws -> Void)? = nil) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureWatcher, SemanticMediaFixtureReader,
            SemanticFixtureEncoder) {
        let (original, root, _, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = ["image.png", "document.md"]
        let media = SemanticFixtureMediaEncoder(), watcher = SemanticFixtureWatcher()
        let encoder = SemanticFixtureEncoder()
        media.before = mediaBefore
        if mediaFailure {
            media.before = { _ in throw URLError(.badServerResponse) }
        }
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: watcher,
                                                access: { true }, automaticStart: false, lowPowerMode: { false },
                                                thermalConstrained: { false }, models: models,
                                                mediaModels: SemanticMediaFixtureModels(source: models.source),
                                                idle: idleCheck ?? { idle },
                                                makeMediaEncoder: { _, _, _ in media }, makeReader: { reader },
                                                makeEncoder: { _, _ in encoder },
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        return (service, root, watcher, reader, encoder)
    }

    @Test func diagnosticsUpdateDuringASingleLongMediaInference() async throws {
        let entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let (service, root, _, _, _) = try fixture(idle: true, mediaBefore: { _ in
            entered.cancel(); _ = release.wait(timeout: .now() + 8)
        })
        defer { release.signal(); try? FileManager.default.removeItem(at: root) }
        do {
            #expect(service.setEnabled(true))
            try await SemanticFileServiceTests.wait { entered.isCancelled }
            try await SemanticFileServiceTests.wait {
                service.diagnostics?.stage == .encoding && service.diagnostics?.counters["encodingRequests"] == 2
            }
            #expect(service.diagnostics?.counters["vectorsInferred"] == 1)
            release.signal()
            try await SemanticFileServiceTests.wait { service.phase == .ready }
            await service.clear(removeModel: true)
        } catch { release.signal(); await service.clear(removeModel: true); throw error }
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
        #expect(service.isEnabled, "manual pause affects indexing only")
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

    @Test func `changed document preempts media without restarting the home scan`() async throws {
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
        try await Task.sleep(for: .milliseconds(2250))
        #expect(service.indexProgress?.waitingForIdle == true)
        #expect(reader.directoryReads == crawls && encoder.calls == 2)
        #expect(await service.search("reimbursement", type: .all, limit: 5).first?.modified == reader
            .modifiedByName["document.md"])
        gate.cancel()
        try await SemanticFileServiceTests.wait { encoder.calls == 2 && service.phase == .ready }
        #expect(reader.directoryReads == crawls)
        #expect(service.indexedCounts.images == 1)
        await service.clear(removeModel: true)
    }
}
