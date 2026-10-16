import Combine
import Foundation
import Testing
@testable import Typeflux

private final class SemanticProgressEncoder: SemanticEmbedding, @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var entered = false
    private var invocations = 0
    private var fail = false
    var waiting: Bool { condition.withLock { entered && held } }
    var calls: Int { condition.withLock { invocations } }
    func release(failure: Bool = false) { condition.withLock { held = false; fail = failure; condition.broadcast() } }
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        condition.lock()
        defer { condition.unlock() }
        invocations += 1; entered = true
        while held, !cancelled() { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        if cancelled() { throw CancellationError() }
        if fail { throw SemanticFileStore.Failure.invalidVector }
        return texts.map { _ in semanticVector() }
    }
}

/// Captures an actual private database snapshot, then delays its return. The
/// second call is the first progress-driven refresh; initial preparation is call one.
private final class SemanticProgressCounts: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var invocations = 0
    private var entered = false
    var calls: Int { condition.withLock { invocations } }
    var waiting: Bool { condition.withLock { entered && held } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
    func read(_ database: SemanticFileStore) throws -> SemanticFileStore.Counts {
        let result = try database.counts()
        condition.lock()
        defer { condition.unlock() }
        invocations += 1
        if invocations == 2 {
            entered = true
            while held { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        }
        return result
    }
}

@Suite("Semantic service progress ownership", .serialized, .exclusiveUIState)
@MainActor
struct SemanticIndexProgressServiceTests {
    private func fixture(countSnapshot: @escaping @Sendable (SemanticFileStore) throws -> SemanticFileStore.Counts = { try $0.counts() }) throws -> (SemanticFileSearchService, URL, SemanticProgressScheduler, SemanticProgressEncoder,
                                      SemanticFixtureReader, SemanticFixtureWatcher) {
        let (original, root, reader, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        let scheduler = SemanticProgressScheduler(), encoder = SemanticProgressEncoder(), watcher = SemanticFixtureWatcher()
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in encoder },
            makeQuery: { _, _ in SemanticFixtureQuery() },
            progressDelivery: SemanticIndexProgressDelivery(schedule: { scheduler.enqueue($0) }), countSnapshot: countSnapshot)
        return (service, root, scheduler, encoder, reader, watcher)
    }

    @Test func completedIndexerCollectsHeldProgressAndQueuedDeliveryCannotResurrectIt() async throws {
        let (service, root, queue, encoder, reader, _) = try fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        #expect(queue.count == 1 && service.indexProgress == nil)
        encoder.release()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(service.files == 1 && service.chunks == 1 && service.indexedCounts.documents == 1)
        #expect(service.currentProcessingPath == nil && service.mediaDownload == nil && service.indexProgress == nil)
        let reads = reader.directoryReads, calls = encoder.calls
        queue.run()
        #expect(service.phase == .ready && service.indexProgress == nil && service.currentProcessingPath == nil)
        #expect(reader.directoryReads == reads && encoder.calls == calls)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        await service.clear(removeModel: true)
        #expect(service.indexedCounts == .init())
    }

    @Test func pausedScopeReceivesTotalsWithoutChangingPhaseOrPublishingNewPath() async throws {
        let (service, root, queue, encoder, _, _) = try fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        service.pause(true)
        queue.run()
        #expect(service.phase == .paused && service.indexProgress?.total == 1)
        #expect(service.currentProcessingPath == nil)
        service.pause(false)
        encoder.release()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        if queue.count > 0 { queue.run() }
        #expect(service.currentProcessingPath == nil && service.files == 1)
        await service.clear(removeModel: true)
    }

    @Test func replacementAndClearDiscardOldCallbacksAndCountsButKeepNewCommittedIndex() async throws {
        let (service, root, queue, encoder, reader, watcher) = try fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        queue.run() // Admit the original count refresh, then retire its source before it can run.
        service.setEnabled(false)
        #expect(service.phase == .off)
        encoder.release()
        reader.text = "replacementzebra policy"
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(service.files == 1 && service.indexedCounts.documents == 1)
        if queue.count > 0 { queue.run() }
        #expect(service.phase == .ready && service.indexProgress == nil)
        #expect(await service.search("replacementzebra", type: .all, limit: 5).map(\.path) == [reader.path])
        let oldWatcher = watcher.change
        await service.clear(removeModel: true)
        oldWatcher?([.init(path: reader.path, rescan: false)], 100)
        if queue.count > 0 { queue.run() }
        await Task.yield()
        #expect(service.phase == .off && service.files == 0 && service.chunks == 0)
        #expect(service.currentProcessingPath == nil && service.indexProgress == nil && service.indexedCounts == .init())
    }

    @Test func failedAttemptSealsPendingSnapshotsAndPreservesFailure() async throws {
        let (service, root, queue, encoder, _, _) = try fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        queue.run()
        #expect(service.currentProcessingPath != nil)
        encoder.release(failure: true)
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        if queue.count > 0 { queue.run() }
        #expect(service.phase == .failed && service.currentProcessingPath == nil && service.mediaDownload == nil)
        #expect(!service.modelReady)
        await service.clear(removeModel: true)
    }
    @Test func oldInFlightCountReadRetainsItsHandleUntilRetirementAndCannotPublishIntoReplacement() async throws {
        let counts = SemanticProgressCounts()
        let (service, root, queue, encoder, _, _) = try fixture(countSnapshot: { try counts.read($0) })
        defer { counts.release(); encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        queue.run()
        try await SemanticFileServiceTests.wait { counts.waiting }
        service.start(force: true)
        encoder.release()
        try await SemanticFileServiceTests.wait { counts.calls >= 3 && encoder.calls >= 2 }
        // The replacement commits while the old refresh is still in flight. Its
        // final publication must join the real read, rather than orphan its handle.
        let committed = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        try await SemanticFileServiceTests.wait { (try? committed.counts().files) == 1 }
        #expect(service.phase == .indexing && counts.waiting)
        if queue.count > 0 { queue.run() }
        #expect(service.files == 1)
        var published: [Int] = []
        let observation = service.$files.sink { published.append($0) }
        counts.release()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        if queue.count > 0 { queue.run() }
        observation.cancel()
        #expect(published.allSatisfy { $0 == 1 }, "the old zero-count snapshot cannot publish even transiently")
        #expect(service.files == 1 && service.indexedCounts.files == 1 && service.chunks == 1)
        await service.clear(removeModel: true)
        #expect(service.files == 0 && service.indexedCounts == .init())
    }

    @Test func settingsEditBeforeNotificationDeliveryRejectsQueuedSourceProgress() async throws {
        let (service, root, queue, encoder, _, _) = try fixture()
        defer { encoder.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { encoder.waiting }
        var names = service.settings.askLauncherSearchSettings
        names.fileRoots = []
        service.settings.askLauncherSearchSettings = names
        queue.run()
        #expect(service.indexProgress == nil && service.currentProcessingPath == nil)
        #expect(service.files == 0 && service.chunks == 0)
        service.setEnabled(false)
        encoder.release()
        await service.clear(removeModel: true)
    }

}
