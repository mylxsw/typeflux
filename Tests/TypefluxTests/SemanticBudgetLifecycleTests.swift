import Combine
import Foundation
import Testing
@testable import Typeflux

private final class RevisionStoreReference: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SemanticFileStore?
    func set(_ value: SemanticFileStore?) {
        lock.withLock { self.value = value }
    }

    var store: SemanticFileStore? {
        lock.withLock { value }
    }
}

private final class RevisionBlockingEncoder: SemanticEmbedding, @unchecked Sendable {
    let reference: RevisionStoreReference
    let entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
    init(_ reference: RevisionStoreReference) {
        self.reference = reference
    }

    func embed(_ texts: [String], cancelled _: () -> Bool) throws -> [[Float]] {
        let store = try #require(reference.store)
        try store.lock.withLock {
            entered.cancel()
            guard release.wait(timeout: .now() + 8) == .success else { throw CancellationError() }
        }
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Budgeted service priority and ownership", .serialized, .exclusiveUIState)
@MainActor
struct SemanticBudgetLifecycleTests {
    private func context(installed: Bool = true, budgetEnabled: Bool = false,
                         makeEncoder: @escaping @Sendable (URL, URL) -> any SemanticEmbedding = { _, _ in
                             SemanticFixtureEncoder()
                         }) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureModels) {
        let (original, root, reader, models) = try SemanticFileServiceTests().fixture()
        if installed {
            try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        }
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: SemanticFixtureWatcher(), access: { true },
                                                automaticStart: false,
                                                budgetEnabled: budgetEnabled, lowPowerMode: { false },
                                                thermalConstrained: { false },
                                                models: models, makeReader: { reader }, makeEncoder: makeEncoder,
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        return (service, root, models)
    }

    @Test func lexicalPublicationAlreadyOwnsQueryPriority() async throws {
        let (service, root, _) = try context()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            #expect(service.setEnabled(true))
            try await SemanticFileServiceTests.wait { service.phase == .ready }
            let gate = try #require(Mirror(reflecting: service).descendant("pauseGate") as? SemanticIndexPauseGate)
            var published = false
            _ = await service.search("reimbursement", type: .all, limit: 5) { _ in
                published = true
                #expect(gate.isPaused, "FTS and permission validation have the same priority as semantic inference")
            }
            #expect(published && !gate.isPaused)
            await service.clear(removeModel: true)
        } catch { await service.clear(removeModel: true); throw error }
    }

    @Test func droppingAServiceCancelsAnInFlightModelDownload() async throws {
        var fixture: (SemanticFileSearchService, URL, SemanticFixtureModels)? = try context(installed: false)
        let root = try #require(fixture?.1), models = try #require(fixture?.2)
        defer { try? FileManager.default.removeItem(at: root) }
        var service = fixture?.0; fixture = nil
        var task: Task<Void, Never>?
        do {
            #expect(service?.setEnabled(true) == true)
            try await SemanticFileServiceTests.wait { service?.phase == .modelRequired }
            models.delay = .seconds(30)
            service?.downloadModel()
            try await SemanticFileServiceTests.wait { models.fetchStarted.isCancelled }
            task = try #require(service.flatMap { Mirror(reflecting: $0).descendant("download") as? Task<Void, Never> })
            weak var weakService = service
            service = nil
            try await SemanticFileServiceTests.wait { weakService == nil }
            await task?.value
        } catch { task?.cancel(); await service?.clear(removeModel: true); await task?.value; throw error }
    }

    @Test func pendingCountSnapshotsDoNotOwnTheServiceWhileSQLIsBlocked() async throws {
        let reference = RevisionStoreReference(), encoder = RevisionBlockingEncoder(reference)
        var fixture: (SemanticFileSearchService, URL, SemanticFixtureModels)? = try context(makeEncoder: { _, _ in
            encoder
        })
        let root = try #require(fixture?.1)
        defer { encoder.release.signal(); try? FileManager.default.removeItem(at: root) }
        var service = fixture?.0; fixture = nil
        // Observe only the fixture's private store/owned tasks; no production test hooks or public DB API.
        let subscription = service?.$phase.sink { [weak service] phase in
            if phase == .indexing, let service {
                reference.set(Mirror(reflecting: service).descendant("store") as? SemanticFileStore)
            }
        }
        defer { subscription?.cancel() }
        var counts: Task<Void, Never>?, work: Task<Void, Never>?
        do {
            #expect(service?.setEnabled(true) == true)
            try await SemanticFileServiceTests.wait { encoder.entered.isCancelled }
            try await SemanticFileServiceTests.wait { service?.indexProgress != nil }
            // Main coalesces progress/count notifications. Explicitly deliver a new priority
            // snapshot after SQL is blocked, instead of relying on a scheduling race.
            let delivery = try #require(service.flatMap { Mirror(reflecting: $0).descendant("progressDelivery") as? SemanticIndexProgressDelivery })
            let attempt = try #require(service.flatMap { Mirror(reflecting: $0).descendant("indexAttempt") as? SemanticIndexProgressDelivery.Source })
            delivery.offer(.summary(.init(priorityUpdates: 99)), from: attempt)
            try await SemanticFileServiceTests.wait {
                service.flatMap { Mirror(reflecting: $0).descendant("countRefresh") as? Task<Void, Never> } != nil
            }
            counts = try #require(service.flatMap { Mirror(reflecting: $0).descendant("countRefresh") as? Task<
                Void,
                Never
            > })
            work = try #require(service.flatMap { Mirror(reflecting: $0).descendant("work") as? Task<Void, Never> })
            weak var weakService = service
            service = nil
            try await SemanticFileServiceTests.wait { weakService == nil }
            encoder.release.signal()
            await counts?.value; await work?.value
            try reference.store?.destroy()
        } catch {
            encoder.release.signal(); counts?.cancel(); await service?.clear(removeModel: true)
            await counts?.value; await work?.value; try? reference.store?.destroy(); throw error
        }
    }

    @Test func aRealBudgetPausesPreparationThenResumesWithoutReencoding() async throws {
        let encoder = SemanticFixtureEncoder()
        let (service, root, _) = try context(budgetEnabled: true, makeEncoder: { _, _ in encoder })
        defer { try? FileManager.default.removeItem(at: root) }
        service.pause(true)
        #expect(service.setEnabled(true))
        do {
            try await SemanticFileServiceTests.wait { service.resourceWaitReason == .priority }
            #expect(!service.modelReady && encoder.calls == 0)
            service.pause(false)
            try await SemanticFileServiceTests.wait { service.phase == .ready }
            #expect(encoder.calls == 1)
            service.start(force: true)
            try await SemanticFileServiceTests.wait { service.phase == .ready }
            #expect(encoder.calls == 1 && service.diagnostics?.counters["encodingRequests"] == 0)
            await service.clear(removeModel: true)
        } catch { service.pause(false); await service.clear(removeModel: true); throw error }
    }
}
