import Foundation
import Testing
@testable import Typeflux

private final class WatcherHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UInt64 = 100
    func advance(_ value: UInt64) { lock.withLock { id = value } }
    func snapshot(_: [String]) -> (UInt64, String?) { lock.withLock { (id, "private-fixture-volume") } }
}

private final class WatcherPolicyInputs: @unchecked Sendable {
    static let interval: TimeInterval = 3 * 60 * 60
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000_000)
    private var pluggedIn = false
    var now: Date { lock.withLock { time } }
    var externalPower: Bool { lock.withLock { pluggedIn } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func plugIn(_ value: Bool) { lock.withLock { pluggedIn = value } }
}

private final class WatcherWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, entered = false, failure = false
    var waiting: Bool { condition.withLock { held && entered } }
    func hold() { condition.withLock { held = true; entered = false } }
    func release(failure: Bool = false) { condition.withLock { held = false; self.failure = failure; condition.broadcast() } }
    func wait(cancelled: () -> Bool) throws {
        condition.lock(); defer { condition.unlock() }; entered = true
        while held, !cancelled() { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        if cancelled() { throw CancellationError() }
        if failure { throw AskFileReadError.unavailable }
    }
}

private final class WatcherReader: AskFileReading, @unchecked Sendable {
    let base: SemanticFixtureReader, gate = WatcherWorkGate()
    init(_ base: SemanticFixtureReader) { self.base = base }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if request.operation == .directory { try gate.wait(cancelled: isCancelled) }
        return try base.read(request, isCancelled: isCancelled)
    }
}

private final class WatcherEncoder: SemanticEmbedding, @unchecked Sendable {
    let gate = WatcherWorkGate()
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        try gate.wait(cancelled: cancelled)
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Semantic watcher checkpoint ownership", .serialized, .exclusiveUIState)
@MainActor
struct SemanticWatcherServiceTests {
    @Test func ignoredArtifactStormDoesNotWakeIndexingAndRestartUsesTheJournalReceipt() async throws {
        let (service, root, watcher, queue, history, reader, _, store, scope) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        service.pause(true)
        for event in 101...200 {
            watcher.change?([.init(path: root.path + "/semantic-files.sqlite-wal", rescan: false,
                                   isDirectory: false)], UInt64(event))
        }
        #expect(queue.count == 0, "Owned writes must not schedule UI work or another index transaction")
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        reader.base.modified += 1
        watcher.change?([.init(path: reader.base.path, rescan: false)], 201)
        queue.run()
        history.advance(220)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .paused && watcher.since == 201 }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100,
                "A persisted watcher receipt must not falsely claim extraction has finished")
        service.pause(false)
        try await SemanticFileServiceTests.wait {
            service.phase == .ready && (try? store.completedEventID(scope: scope,
                volumeSignature: "private-fixture-volume")) == 201
        }
        #expect(service.files == 1)
        await service.clear(removeModel: true)
    }

    private func fixture(policy: WatcherPolicyInputs? = nil) async throws -> (SemanticFileSearchService, URL, SemanticFixtureWatcher,
        SemanticProgressScheduler, WatcherHistory, WatcherReader, WatcherEncoder, SemanticFileStore, AskFileScope) {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let watcher = SemanticFixtureWatcher(), queue = SemanticProgressScheduler(), history = WatcherHistory()
        let scoped = WatcherReader(reader), encoder = WatcherEncoder()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            externalPower: { policy?.externalPower ?? true }, batchInterval: policy == nil ? 0 : WatcherPolicyInputs.interval,
            now: { policy?.now ?? .now },
            models: models, makeReader: { scoped }, makeEncoder: { _, _ in encoder },
            makeQuery: { _, _ in SemanticFixtureQuery() }, watcherDelivery: SemanticWatcherDelivery(schedule: { queue.enqueue($0) }),
            eventHistory: { history.snapshot($0) })
        #expect(service.setEnabled(true))
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let scope = SemanticFilePolicy.scope(names: service.settings.askLauncherSearchSettings, fullDiskAccess: true)
        if policy != nil {
            try await SemanticFileServiceTests.wait { service.phase == .paused }
            return (service, root, watcher, queue, history, scoped, encoder, store, scope)
        }
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        return (service, root, watcher, queue, history, scoped, encoder, store, scope)
    }

    @Test func timedBatchesSurviveRestartAndRequireExternalPower() async throws {
        let policy = WatcherPolicyInputs()
        let (service, root, watcher, queue, history, reader, encoder, store, _) = try await fixture(policy: policy)
        defer { encoder.gate.release(); try? FileManager.default.removeItem(at: root) }
        func updatePower(_ pluggedIn: Bool) {
            policy.plugIn(pluggedIn)
            // Force a pause-state refresh without relying on the host Mac's power source.
            service.setForegroundBusy(true)
            service.setForegroundBusy(false)
        }
        #expect(try store.runDiagnostics() == nil)
        updatePower(true)
        try await SemanticFileServiceTests.wait { service.phase == .ready && service.files == 1 }
        let firstRun = try store.runDiagnostics()
        let first = try #require(firstRun)

        reader.base.modified += 1
        history.advance(101)
        watcher.change?([.init(path: reader.base.path, rescan: false)], 101)
        queue.run()
        try await SemanticFileServiceTests.wait {
            (try? store.lock.withLock { try store.count("automatic_index_schedule") }) == 1
        }
        policy.advance(WatcherPolicyInputs.interval - 60)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready && watcher.since == 101 }
        #expect(try store.runDiagnostics()?.id == first.id)

        updatePower(false)
        policy.advance(60)
        #expect(service.phase == .paused)
        #expect(try store.runDiagnostics()?.id == first.id)
        encoder.gate.hold()
        updatePower(true)
        try await SemanticFileServiceTests.wait { encoder.gate.waiting }
        let secondRun = try store.runDiagnostics()
        let second = try #require(secondRun)
        #expect(second.started == policy.now)
        let latePath = root.appendingPathComponent("late.txt").path
        history.advance(102)
        watcher.change?([.init(path: latePath, rescan: false)], 102)
        queue.run()
        updatePower(false)
        #expect(service.phase == .paused)
        updatePower(true)
        encoder.gate.release()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let journal = try SemanticIndexEvents(url: root.appendingPathComponent("index-events.sqlite"))
        #expect(try journal.pending(), "A later revision belongs to the next window")
        #expect(try store.runDiagnostics()?.id == second.id)

        policy.advance(WatcherPolicyInputs.interval)
        updatePower(true)
        try await SemanticFileServiceTests.wait {
            service.phase == .ready && (try? store.runDiagnostics()?.id) != second.id
        }
        #expect(try !journal.pending())
        await service.shutdown()
    }

    @Test func heldConsumerDoesNotAcknowledgeUntilTargetedWorkActuallyFinishes() async throws {
        let (service, root, watcher, queue, _, reader, encoder, store, scope) = try await fixture()
        defer { encoder.gate.release(); try? FileManager.default.removeItem(at: root) }
        encoder.gate.hold(); reader.base.modified += 1
        for _ in 0..<1_000 { watcher.change?([.init(path: reader.base.path, rescan: false)], 101) }
        #expect(queue.count == 1 && service.phase == .ready)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        queue.run()
        try await SemanticFileServiceTests.wait { encoder.gate.waiting }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        encoder.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .ready && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 101)
        await service.clear(removeModel: true)
    }

    @Test func overflowRequiresDurableSubtreeDiscoveryBeforeItsCheckpointCanAdvance() async throws {
        let (service, root, watcher, queue, history, reader, _, store, scope) = try await fixture()
        defer { reader.gate.release(); try? FileManager.default.removeItem(at: root) }
        reader.gate.hold(); history.advance(120)
        let changes = (0...SemanticFileChangePlan.handoffPaths).map {
            AskFileChange(path: root.path + "/changed-\($0).md", rescan: false)
        }
        watcher.change?(changes, 110)
        #expect(queue.count == 1 && service.phase == .ready)
        queue.run()
        try await SemanticFileServiceTests.wait { reader.gate.waiting }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100,
                "the prior receipt stays unchanged until durable subtree catch-up finishes")
        reader.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .ready && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 110)
        await service.clear(removeModel: true)
    }

    @Test func replacementAndClearDiscardOldReceiptsButCurrentEmptyReceiptCanCommit() async throws {
        let (service, root, watcher, queue, _, reader, _, store, scope) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = watcher.change
        old?([.init(path: reader.base.path, rescan: false)], 999)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        old?([], 1_000)
        queue.run()
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        watcher.change?([], 102)
        queue.run()
        try await SemanticFileServiceTests.wait {
            (try? store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume")) == 102
        }
        let current = watcher.change
        current?([.init(path: reader.base.path, rescan: false)], 103)
        await service.clear(removeModel: true)
        queue.run(); current?([], 104)
        #expect(queue.count == 0 && service.phase == .off && service.files == 0)
    }

    @Test func settingsEditBeforeDeliveryCannotAdoptReceiptOrPlan() async throws {
        let (service, root, watcher, queue, _, reader, _, store, scope) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        watcher.change?([.init(path: reader.base.path, rescan: false)], 105)
        service.settings.askQuickFileSearchEnabled = false
        queue.run()
        try await Task.sleep(for: .milliseconds(250))
        #expect(service.phase == .ready)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        await service.clear(removeModel: true)
    }
    @Test func pausedServiceBoundsCombinedFileAndDirectoryIntentsAcrossDeliveries() async throws {
        let (service, root, watcher, queue, history, reader, _, store, scope) = try await fixture()
        defer { reader.gate.release(); try? FileManager.default.removeItem(at: root) }
        service.pause(true)
        for batch in 0..<6 {
            var changes = (0..<100).map {
                AskFileChange(path: root.path + "/pending-\(batch)-\($0).md", rescan: false)
            }
            changes.append(.init(path: root.path + "/directory-\(batch)", rescan: false,
                                 isDirectory: true, structureChanged: true))
            watcher.change?(changes, UInt64(101 + batch)); queue.run()
        }
        #expect(service.phase == .paused && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        history.advance(120); reader.gate.hold()
        service.pause(false)
        try await SemanticFileServiceTests.wait { reader.gate.waiting }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        reader.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .ready && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 106)
        await service.clear(removeModel: true)
    }

    @Test func priorityOverflowKeepsDeletionCatchupAndReceiptAfterEnteredWork() async throws {
        let (service, root, watcher, queue, history, reader, encoder, store, scope) = try await fixture()
        defer { reader.gate.release(); encoder.gate.release(); try? FileManager.default.removeItem(at: root) }
        let deleted = root.path + "/deleted.md"
        try store.replace(path: deleted, modified: reader.base.modified, bytes: 10,
                          chunks: [.init(text: "previously committed", page: nil)], vectors: [semanticVector()])
        encoder.gate.hold(); reader.base.modified += 1
        watcher.change?([.init(path: reader.base.path, rescan: false)], 101); queue.run()
        try await SemanticFileServiceTests.wait { encoder.gate.waiting }
        for batch in 0..<6 {
            let changes = (0..<100).map {
                AskFileChange(path: root.path + "/priority-\(batch)-\($0).md", rescan: false)
            } + [.init(path: deleted, rescan: false)]
            watcher.change?(changes, UInt64(102 + batch)); queue.run()
        }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        history.advance(120); reader.gate.hold(); encoder.gate.release()
        // The existing priority scan runs within the active indexer, not a producer restart.
        try await SemanticFileServiceTests.wait { reader.gate.waiting }
        #expect(service.phase == .indexing)
        reader.gate.release()
        try await SemanticFileServiceTests.wait {
            service.phase == .ready && (try? store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume")) == 107
        }
        #expect(try store.counts().files == 1)
        #expect(try !store.unchanged(path: deleted, modified: reader.base.modified - 1, bytes: 10))
        await service.clear(removeModel: true)
    }

    @Test func failedAttemptRestoresBoundedObligationsWithoutAutomaticRetry() async throws {
        let (service, root, watcher, queue, history, reader, encoder, store, scope) = try await fixture()
        defer { reader.gate.release(); encoder.gate.release(); try? FileManager.default.removeItem(at: root) }
        reader.base.modified += 1
        encoder.gate.hold()
        let original = (0..<300).map { AskFileChange(path: root.path + "/original-\($0).md", rescan: false) }
        watcher.change?(original, 110); queue.run()
        try await SemanticFileServiceTests.wait { encoder.gate.waiting }
        let later = (0..<300).map { AskFileChange(path: root.path + "/later-\($0).md", rescan: false) }
        watcher.change?(later, 111); queue.run()
        encoder.gate.release(failure: true)
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        history.advance(140); reader.gate.hold(); encoder.gate.release()
        // A fresh event is the existing explicit reconciliation trigger, not a health retry.
        watcher.change?([], 130); queue.run()
        try await SemanticFileServiceTests.wait { reader.gate.waiting }
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        reader.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .ready && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 130)
        await service.clear(removeModel: true)
    }

}
