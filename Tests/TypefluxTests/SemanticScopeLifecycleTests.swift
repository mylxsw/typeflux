import Foundation
import Testing
@testable import Typeflux

private final class ScopeLifecycleModels: SemanticModelHandling, @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, entered = false, failure = false
    private var checks = 0
    var waiting: Bool { condition.withLock { held && entered } }
    var verifications: Int { condition.withLock { checks } }
    func hold() { condition.withLock { held = true; entered = false } }
    func release(failure: Bool = false) { condition.withLock { held = false; self.failure = failure; condition.broadcast() } }
    func verify(_: URL, cancelled: @Sendable () -> Bool) throws {
        condition.lock(); defer { condition.unlock() }
        checks += 1; entered = true
        while held { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
        if failure { throw SemanticFileStore.Failure.invalidVector }
        if cancelled() { throw CancellationError() }
    }
    func install(_: URL, to _: URL, cancelled _: @Sendable () -> Bool) throws { throw URLError(.unsupportedURL) }
    func fetch(progress _: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) { throw URLError(.unsupportedURL) }
}

private final class ScopeLifecycleGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false, entered = false
    func hold() { condition.withLock { held = true; entered = false } }
    var waiting: Bool { condition.withLock { held && entered } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
    func wait() { condition.lock(); defer { condition.unlock() }; entered = true
        while held { _ = condition.wait(until: Date().addingTimeInterval(0.01)) }
    }
}

private final class ScopeLifecycleEncoder: SemanticEmbedding, @unchecked Sendable {
    let gate = ScopeLifecycleGate()
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        gate.wait()
        if cancelled() { throw CancellationError() }
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Semantic original scope lifecycle", .serialized, .exclusiveUIState)
@MainActor
struct SemanticScopeLifecycleTests {
    private func fixture(countGate: ScopeLifecycleGate? = nil) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureReader, SemanticFixtureWatcher, ScopeLifecycleModels, ScopeLifecycleEncoder) {
        let (base, root, reader, original) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: original.source, to: base.modelURL)
        let watcher = SemanticFixtureWatcher(), models = ScopeLifecycleModels(), encoder = ScopeLifecycleEncoder()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in encoder },
            makeQuery: { _, _ in SemanticFixtureQuery() }, countSnapshot: { database in
                countGate?.wait(); return try database.counts()
            })
        return (service, root, reader, watcher, models, encoder)
    }

    private func editScope(_ service: SemanticFileSearchService) {
        var names = service.settings.askLauncherSearchSettings
        names.excludedPaths.append("/synthetic-never-accessed")
        service.settings.askLauncherSearchSettings = names
    }

    @Test func settingsChangedDuringInitialCountCannotVerifyOrStartWatcher() async throws {
        let gate = ScopeLifecycleGate(); gate.hold()
        let (service, root, _, watcher, models, _) = try fixture(countGate: gate)
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { gate.waiting }
        editScope(service)
        gate.release()
        await service.prepareModelIfNeeded() // Joins the original preparation without granting a new start.
        #expect(service.phase == .preparing && models.verifications == 0 && watcher.started.isEmpty)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(models.verifications == 1)
        await service.clear(removeModel: true)
    }

    @Test(arguments: [false, true]) func lateVerificationCannotPublishOrRegisterOldScope(failure: Bool) async throws {
        let (service, root, _, watcher, models, _) = try fixture()
        defer { models.release(); try? FileManager.default.removeItem(at: root) }
        models.hold()
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { models.waiting }
        editScope(service)
        models.release(failure: failure)
        await service.prepareModelIfNeeded()
        #expect(service.phase == .preparing && !service.modelReady && watcher.started.isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func queuedWatcherAfterSettingsEditCannotAcknowledgeOrReconcileOldEvents() async throws {
        let (service, root, reader, watcher, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let reads = reader.directoryReads
        let oldScope = SemanticFilePolicy.scope(names: service.settings.askLauncherSearchSettings, fullDiskAccess: true)
        reader.modified += 1
        watcher.change?([.init(path: reader.path, rescan: false)], UInt64.max - 1)
        editScope(service) // MainActor is still occupied; the queued callback has not entered.
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.phase == .ready && reader.directoryReads == reads)
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let signature = try #require(AskFSEventsWatcher.historySignature(paths: [root.path]))
        #expect(try store.completedEventID(scope: oldScope, volumeSignature: signature) != UInt64.max - 1)
        await service.clear(removeModel: true)
    }

    @Test(arguments: [false, true]) func delayedReconcileAndPauseResumeKeepOriginalSettingsOwnership(paused: Bool) async throws {
        let (service, root, reader, watcher, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let reads = reader.directoryReads
        watcher.change?([.init(path: reader.path, rescan: true)], UInt64.max - 2)
        // Let receiveChanges schedule its delay, then revoke the scope before it fires.
        try await Task.sleep(for: .milliseconds(30))
        if paused { service.pause(true); #expect(service.phase == .paused) }
        editScope(service)
        if paused { service.pause(false) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.phase == (paused ? .paused : .ready) && reader.directoryReads == reads)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        await service.clear(removeModel: true)
    }

    @Test func enteredIndexerCannotCommitLateEventCheckpointOrTerminalState() async throws {
        let (service, root, reader, watcher, _, encoder) = try fixture()
        defer { encoder.gate.release(); try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let scope = SemanticFilePolicy.scope(names: service.settings.askLauncherSearchSettings, fullDiskAccess: true)
        let signature = try #require(AskFSEventsWatcher.historySignature(paths: scope.roots))
        let before = try #require(try store.completedEventID(scope: scope, volumeSignature: signature))
        encoder.gate.hold(); reader.modified += 1
        watcher.change?([.init(path: reader.path, rescan: false)], before + 1)
        try await SemanticFileServiceTests.wait { encoder.gate.waiting }
        editScope(service)
        encoder.gate.release()
        await service.prepareModelIfNeeded()
        #expect(service.phase == .indexing)
        #expect(try store.completedEventID(scope: scope, volumeSignature: signature) == before)
        #expect(try store.counts().files == 1, "already entered index writes are not rolled back")
        await service.clear(removeModel: true)
    }
}
