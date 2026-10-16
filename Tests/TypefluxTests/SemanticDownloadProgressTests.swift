import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded semantic model download progress", .serialized, .exclusiveUIState)
@MainActor
struct SemanticDownloadProgressTests {
    @Test func floodReplacementAndTerminalSealKeepOneScheduledSlot() async {
        let queue = SemanticProgressScheduler(), mailbox = SemanticDownloadProgressDelivery(schedule: { queue.enqueue($0) })
        let old = SemanticDownloadProgressDelivery.Source()
        var values: [Double] = []
        mailbox.begin(old) { values.append($0) }
        await Task.detached { for index in 0..<100_000 { mailbox.offer(Double(index), from: old) } }.value
        #expect(queue.count == 1 && values.isEmpty)
        queue.run()
        #expect(values == [99_999])
        mailbox.offer(1, from: old)
        var next = old
        for _ in 0..<1_000 {
            mailbox.invalidate()
            next = SemanticDownloadProgressDelivery.Source()
            mailbox.begin(next) { values.append($0) }
            mailbox.offer(0.25, from: next)
        }
        mailbox.offer(777, from: old)
        #expect(queue.count == 1)
        queue.run()
        #expect(values == [99_999, 0.25])
        mailbox.offer(1, from: next)
        mailbox.invalidate()
        queue.run()
        mailbox.offer(999, from: next)
        #expect(queue.count == 0 && values == [99_999, 0.25])
    }

    @Test func offerDuringSinkSchedulesOneSuccessorAndInvalidationSealsIt() {
        let queue = SemanticProgressScheduler(), mailbox = SemanticDownloadProgressDelivery(schedule: { queue.enqueue($0) })
        let source = SemanticDownloadProgressDelivery.Source()
        var values: [Double] = []
        mailbox.begin(source) { value in
            values.append(value)
            if values.count == 1 {
                for value in 1...100 { mailbox.offer(Double(value), from: source) }
            } else { mailbox.invalidate() }
        }
        mailbox.offer(0, from: source)
        queue.run(); #expect(queue.count == 1)
        queue.run(); #expect(queue.count == 0 && values == [0, 100])
    }
}

/// Intentionally ignores task cancellation and retains the old producer callback.
/// Every response is a private placeholder; no network or real model is used.
private final class HeldSemanticDownload: SemanticModelHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), any Error>?
    private var callback: (@Sendable (Int64) -> Void)?
    private var fetchCount = 0, installCount = 0
    let source: URL
    init(source: URL) { self.source = source }
    var fetches: Int { lock.withLock { fetchCount } }
    var installs: Int { lock.withLock { installCount } }
    func verify(_: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }
    func install(_ temporary: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try verify(temporary, cancelled: cancelled)
        lock.withLock { installCount += 1 }
        try FileManager.default.copyItem(at: temporary, to: target)
    }
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation; callback = progress; fetchCount += 1 }
        }
    }
    var producer: (@Sendable (Int64) -> Void)? { lock.withLock { callback } }
    func emit(_ bytes: Int64) { producer?(bytes) }
    func complete(status: Int = 200) throws {
        let temporary = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: temporary)
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending!.resume(returning: (temporary, HTTPURLResponse(url: SemanticModel.url, statusCode: status,
                                                              httpVersion: nil, headerFields: nil)!))
    }
}

@Suite("Semantic download attempt ownership", .serialized, .exclusiveUIState)
@MainActor
struct SemanticDownloadServiceTests {
    private func fixture(beginDownload: Bool = true) async throws -> (SemanticFileSearchService, URL, HeldSemanticDownload, SemanticProgressScheduler) {
        let (base, root, reader, original) = try SemanticFileServiceTests().fixture()
        let models = HeldSemanticDownload(source: original.source), queue = SemanticProgressScheduler()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() },
            downloadProgress: SemanticDownloadProgressDelivery(schedule: { queue.enqueue($0) }))
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        if beginDownload {
            service.downloadModel()
            try await SemanticFileServiceTests.wait { models.fetches == 1 }
        }
        return (service, root, models, queue)
    }

    @Test func cancelledPreparationCannotStartDownloadButFreshExplicitConsentCan() async throws {
        let (service, root, models, _) = try await fixture(beginDownload: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let cancelled = Task { await service.prepareModelIfNeeded() }
        cancelled.cancel()
        await cancelled.value
        #expect(service.phase == .modelRequired && models.fetches == 0)
        await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { models.fetches == 1 }
        try models.complete()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        await service.clear(removeModel: true)
    }

    @Test func waitingPreparationCannotCarryDownloadConsentIntoReplacement() async throws {
        let (service, root, models, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        service.start(force: true)
        let entered = AskSearchCancellation()
        let preparing = Task { entered.cancel(); await service.prepareModelIfNeeded() }
        try await SemanticFileServiceTests.wait { entered.isCancelled }
        service.start(force: true)
        try models.complete()
        await preparing.value
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        #expect(models.fetches == 1 && models.installs == 0)
        await service.clear()
    }

    @Test func successfulConsumerPublishesLatestFractionAndSealsBeforeReady() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await Task.detached { for index in 0..<100_000 { models.emit(Int64(index)) } }.value
        models.emit(SemanticModel.bytes / 2)
        #expect(queue.count == 1 && models.installs == 0)
        queue.run()
        #expect(service.phase == .downloading(0.5))
        models.emit(SemanticModel.bytes * 2)
        queue.run(); #expect(service.phase == .downloading(1))
        models.emit(-100)
        queue.run(); #expect(service.phase == .downloading(0))
        models.emit(SemanticModel.bytes)
        try models.complete()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        queue.run()
        models.emit(1)
        #expect(queue.count == 0 && service.phase == .ready && service.files == 1)
        #expect(models.fetches == 1 && models.installs == 1)
        await service.clear(removeModel: true)
    }

    @Test func cancelRevokesImmediatelyButPhysicalSlotAndAdmissionRemainUntilFetchReturns() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldProducer = models.producer
        models.emit(SemanticModel.bytes)
        service.cancelDownload()
        queue.run()
        models.emit(1)
        #expect(queue.count == 0 && service.phase == .downloading(0))
        service.downloadModel()
        #expect(models.fetches == 1)
        #expect(throws: AskFileReadError.self) { try service.embeddingOwners.mutation(.model) }
        try models.complete()
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        #expect(models.installs == 0 && !FileManager.default.fileExists(atPath: service.modelURL.path))
        service.downloadModel()
        try await SemanticFileServiceTests.wait { models.fetches == 2 }
        oldProducer?(SemanticModel.bytes)
        #expect(queue.count == 0 && service.phase == .downloading(0))
        try models.complete()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(models.installs == 1)
        await service.clear(removeModel: true)
    }

    @Test func replacementStartWaitsOldFetchWithoutOldInstallOrCompletionPublishing() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        models.emit(SemanticModel.bytes)
        service.start(force: true)
        #expect(service.phase == .preparing)
        queue.run(); #expect(service.phase == .preparing)
        try models.complete(status: 503)
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        #expect(models.installs == 0 && models.fetches == 1)
        models.emit(1); #expect(queue.count == 0)
        await service.clear()
    }

    @Test func disableThenEnableRetainsNewLifecycleAndAllowsOnlyExplicitFreshDownload() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        models.emit(1)
        #expect(service.setEnabled(false) && service.phase == .off)
        queue.run(); #expect(service.phase == .off)
        #expect(service.setEnabled(true))
        #expect(service.phase == .preparing)
        try models.complete()
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        #expect(models.installs == 0 && models.fetches == 1)
        await service.clear()
    }

    @Test func settingsEditBeforeNotificationFencesProgressAndInstall() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        models.emit(SemanticModel.bytes)
        service.settings.askQuickFileSearchEnabled = false
        queue.run(); #expect(service.phase == .downloading(0))
        try models.complete()
        try await service.embeddingOwners.waitUntilIdle()
        #expect(models.installs == 0 && !service.modelReady)
        service.start(force: true)
        #expect(service.phase == .off)
        await service.clear()
    }

    @Test func failureAndClearSealQueuedAndLateCallbacksWithoutReplay() async throws {
        let (service, root, models, queue) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        models.emit(1)
        try models.complete(status: 503)
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        queue.run(); models.emit(2)
        #expect(queue.count == 0 && service.phase == .failed && models.installs == 0)
        service.downloadModel()
        try await SemanticFileServiceTests.wait { models.fetches == 2 }
        models.emit(3)
        let clear = Task { await service.clear() }
        try await SemanticFileServiceTests.wait { !service.preferences.enabled }
        queue.run(); models.emit(4)
        try models.complete()
        await clear.value
        #expect(service.phase == .off && queue.count == 0 && models.installs == 0 && models.fetches == 2)
    }
}
