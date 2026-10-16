import Foundation
import Testing
@testable import Typeflux

private final class WatcherHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UInt64 = 100
    func advance(_ value: UInt64) { lock.withLock { id = value } }
    func snapshot(_: [String]) -> (UInt64, String?) { lock.withLock { (id, "private-fixture-volume") } }
}

private final class WatcherWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, entered = false
    var waiting: Bool { condition.withLock { held && entered } }
    func hold() { condition.withLock { held = true; entered = false } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
    func wait(cancelled: () -> Bool) throws {
        condition.lock(); defer { condition.unlock() }; entered = true
        while held, !cancelled() { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        if cancelled() { throw CancellationError() }
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
    private func fixture() async throws -> (SemanticFileSearchService, URL, SemanticFixtureWatcher,
        SemanticProgressScheduler, WatcherHistory, WatcherReader, WatcherEncoder, SemanticFileStore, AskFileScope) {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let watcher = SemanticFixtureWatcher(), queue = SemanticProgressScheduler(), history = WatcherHistory()
        let scoped = WatcherReader(reader), encoder = WatcherEncoder()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { scoped }, makeEncoder: { _, _ in encoder },
            makeQuery: { _, _ in SemanticFixtureQuery() }, watcherDelivery: SemanticWatcherDelivery(schedule: { queue.enqueue($0) }),
            eventHistory: { history.snapshot($0) })
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let scope = SemanticFilePolicy.scope(names: service.settings.askLauncherSearchSettings, fullDiskAccess: true)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 100)
        return (service, root, watcher, queue, history, scoped, encoder, store, scope)
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

    @Test func overflowRequiresCatchupDiscoveryBeforeItsCheckpointCanAdvance() async throws {
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
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == nil,
                "full catch-up invalidates the old checkpoint rather than acknowledging the overflow")
        reader.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .ready && service.files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-fixture-volume") == 120)
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
}
