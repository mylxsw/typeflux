import Darwin
import Foundation
import Testing
import XCTest
@testable import Typeflux

private final class ModelHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 1000 } }
}

@MainActor final class SemanticModelModuleTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    private func module(_ owner: SemanticEmbeddingOwnership, root: URL,
                        clock: ModelHealthClock = .init(), executable: URL = URL(fileURLWithPath: "/bin/sh")) -> SemanticModelModule {
        var policy = ModulePolicy(); policy.automaticallyRecover = false; policy.cleanupTimeout = 0.03
        return SemanticModelModule(domain: .query, lane: owner, healthDirectory: root,
            executable: executable, policy: policy, uptime: { clock.now })
    }
    private func start(_ module: SemanticModelModule) async throws {
        await module.module.setEnabled(true)
        try await module.module.start()
    }
    private func script(_ root: URL, response: String? = nil, body: String? = nil) throws -> URL {
        let path = root.appendingPathComponent(UUID().uuidString)
        let response = try response ?? "{\"entries\":[],\"embeddings\":\(String(decoding: JSONEncoder().encode([semanticVector()]), as: UTF8.self))}"
        try Data((body ?? "while IFS= read -r line; do printf '%s\\n' '\(response)'; done\n").utf8).write(to: path)
        return path
    }
    private func worker(_ owner: SemanticEmbeddingOwnership, _ path: URL) -> SemanticEmbeddingWorker {
        .init(helper: URL(fileURLWithPath: "/bin/sh"), model: path, timeout: 0.12, startupTimeout: 0.12, ownership: owner)
    }

    func testIndependentDomainsReadinessAndOneReservationWithoutModelWork() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owners = SemanticEmbeddingOwners(requiresLifecycle: true), path = try script(root)
        let old = worker(owners.query, path)
        XCTAssertThrowsError(try old.embed(["private"], cancelled: { false }))
        let modules = SemanticModelModules(readers: owners, healthDirectory: root, executable: URL(fileURLWithPath: "/bin/sh"))
        let registry = ModuleRegistry(modules.registrations)
        XCTAssertEqual(Set(modules.registrations.map(\.id)), [.semanticQueryInference, .semanticIndexInference, .semanticMediaInference])
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(owners.query.isIdle && owners.indexing.isIdle && owners.media.isIdle)
        XCTAssertThrowsError(try old.embed(["private"], cancelled: { false }))
        for domain in SemanticModelModule.Domain.allCases {
            let owner = domain.lane(in: owners), client = worker(owner, path)
            for _ in 0..<3 { XCTAssertEqual(try client.embed(["explicit"], cancelled: { false }), [semanticVector()]) }
            client.release()
            let record = try JSONDecoder().decode(ModuleHealthStore.Record.self,
                from: Data(contentsOf: root.appendingPathComponent(domain.id.rawValue + ".json")))
            XCTAssertEqual(record.attempts, 1)
        }
        await registry.shutdown()
        XCTAssertTrue(owners.query.isIdle && owners.indexing.isIdle && owners.media.isIdle)
    }

    func testControlledRefusalAndMalformedPromisedVectorsAreDifferent() async throws {
        let vector = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        for response in ["{\"entries\":[],\"error\":22}", "{\"entries\":[],\"error\":5}",
                         "{\"entries\":[],\"embeddings\":[[0]]}", "{\"entries\":[],\"embeddings\":[]}",
                         "{\"entries\":[],\"error\":22,\"embeddings\":\(vector)}"] {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), module = module(owner, root: root)
            try await start(module)
            let client = worker(owner, try script(root, response: response))
            XCTAssertThrowsError(try client.embed(["private"], cancelled: { false }))
            let expected = response.contains("error") && !response.contains("embeddings")
            if expected {
                XCTAssertEqual(module.module.health.current?.state, .ready)
                XCTAssertThrowsError(try client.embed(.init(kind: .image, path: "/private-not-read"), cancelled: { false }))
                XCTAssertEqual(module.module.health.current?.state, .ready)
            } else {
                try await wait { module.module.health.current?.failure != nil }
            }
            client.release(); await module.module.shutdown()
        }
    }

    func testTransportFaultsConfigurationAndCapabilityOnlyRecovery() async throws {
        for body in ["read line; exit 7", "read line; printf 'invalid\\n'", "read line; sleep 2"] {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), clock = ModelHealthClock()
            let module = module(owner, root: root, clock: clock); try await start(module)
            let client = worker(owner, try script(root, body: body))
            XCTAssertThrowsError(try client.embed(["private"], cancelled: { false }))
            try await wait { module.module.health.current?.failure != nil }
            try await wait { owner.isIdle && module.module.health.current?.hasLifecycleWork == false }
            clock.advance(); let recovery = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(recovery, .started)
            try await wait { module.module.health.current?.state == .ready }
            XCTAssertTrue(owner.isIdle)
            XCTAssertThrowsError(try client.embed(["old"], cancelled: { false }))
            await module.module.shutdown()
        }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), module = module(owner, root: root)
        try await start(module)
        let missing = SemanticEmbeddingWorker(helper: root.appendingPathComponent("missing"), model: root, ownership: owner)
        XCTAssertThrowsError(try missing.embed(["private"], cancelled: { false }))
        try await wait { module.module.health.current?.failure != nil }
        await module.module.shutdown()
    }

    func testCorruptBudgetExplicitResetDoesNotPrepareOrAffectOtherRoles() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("semanticMediaInference.json"), data = Data("broken".utf8)
        try data.write(to: file)
        let owners = SemanticEmbeddingOwners(requiresLifecycle: true), clock = ModelHealthClock()
        let modules = SemanticModelModule.Domain.allCases.map {
            SemanticModelModule(domain: $0, lane: $0.lane(in: owners), healthDirectory: root,
                executable: URL(fileURLWithPath: "/bin/sh"), uptime: { clock.now })
        }
        let registry = ModuleRegistry(modules.map(\.registration)); let failures = await registry.startAll()
        XCTAssertEqual(failures.count, 1); XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(modules[0].module.health.current?.state, .ready)
        clock.advance(); _ = await modules[2].module.supervisor.requestRecovery(resetPersistentBudget: true)
        try await wait { modules[2].module.health.current?.state == .ready }
        XCTAssertTrue(owners.query.isIdle && owners.indexing.isIdle && owners.media.isIdle)
        await registry.shutdown()
    }

    func testDisableAndQuitRetainBlockedHostAndDelayedChildWithoutLateSuccess() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), module = module(owner, root: root)
        try await start(module)
        let auth = owner.authorization(), entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let id = try owner.native.reserve { false }; try owner.native.begin(id)
        let task = Task.detached {
            try owner.perform(authorization: auth, cancelled: { false }) {
                entered.cancel(); _ = release.wait(timeout: .now() + 8); return 42
            }
        }
        try await wait { entered.isCancelled }
        await module.module.setEnabled(false); XCTAssertFalse(owner.isIdle)
        do { try await start(module); XCTFail("Replaced occupied owner") } catch {}
        owner.native.reaped(id); owner.native.end(id); XCTAssertFalse(owner.isIdle)
        release.signal(); do { _ = try await task.value; XCTFail("Late success") } catch {}
        try await wait { owner.isIdle && module.module.health.current?.hasLifecycleWork == false }
        try await start(module)
        XCTAssertThrowsError(try owner.perform(authorization: auth, cancelled: { false }) { 1 })
        XCTAssertEqual(try owner.perform(cancelled: { false }) { 2 }, 2)
        await module.module.shutdown()
    }

    func testRecoveryCannotOvertakeMutationButUnhealthyModelManagementRemainsExplicit() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owners = SemanticEmbeddingOwners(requiresLifecycle: true)
        let clock = ModelHealthClock(), module = module(owners.query, root: root, clock: clock)
        let mutation = try owners.mutation(.model)
        do { try await start(module); XCTFail("Overtook mutation") } catch {}
        XCTAssertFalse(owners.query.isIdle)
        mutation.finish(); clock.advance(); try await start(module)
        let mutation2 = try owners.mutation(.model)
        await module.module.setEnabled(false); XCTAssertFalse(owners.query.isIdle)
        mutation2.finish()
        try await wait { module.module.health.current?.hasLifecycleWork == false }
        let explicit = try owners.mutation(.model); explicit.finish()
        await module.module.shutdown()
    }

    func testCachedAndQueuedQueriesCannotInheritRecoveredGeneration() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), module = module(owner, root: root)
        try await start(module)
        let path = try script(root), client = worker(owner, path)
        let value = try await client.query("cached private", lifecycle: AskSearchCancellation())
        XCTAssertEqual(value, semanticVector())
        await module.module.setEnabled(false)
        try await wait { module.module.health.current?.hasLifecycleWork == false }
        try await start(module)
        do { _ = try await client.query("cached private", lifecycle: AskSearchCancellation()); XCTFail("Old cached permission") } catch {}
        let next = worker(owner, path)
        let fresh = try await next.query("explicit next", lifecycle: AskSearchCancellation())
        XCTAssertEqual(fresh, semanticVector())
        client.stop(); next.stop(); await module.module.shutdown()
    }

    func testDisableRejectsQueuedPreparationWithoutExecutingItAfterRecovery() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(requiresLifecycle: true), module = module(owner, root: root)
        try await start(module)
        let path = try script(root), client = worker(owner, path)
        let entered = AskSearchCancellation(), enqueued = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let trace = SemanticSearchTrace(sink: {
            if $0.stage == "helper-queue-end" { entered.cancel(); _ = release.wait(timeout: .now() + 8) }
        })
        let first = Task { try await SemanticSearchTrace.$current.withValue(trace) {
            try await client.query("blocked", lifecycle: AskSearchCancellation())
        } }
        try await wait { entered.isCancelled }
        let queuedTrace = SemanticSearchTrace(sink: { if $0.stage == "helper-enqueued" { enqueued.cancel() } })
        let queued = Task { try await SemanticSearchTrace.$current.withValue(queuedTrace) {
            try await client.prepare(lifecycle: AskSearchCancellation())
        } }
        try await wait { enqueued.isCancelled }
        await module.module.setEnabled(false)
        XCTAssertFalse(owner.isIdle)
        release.signal()
        do { _ = try await first.value; XCTFail("Late vector") } catch {}
        do { try await queued.value; XCTFail("Queued prepare replayed") } catch {}
        try await wait { owner.isIdle && module.module.health.current?.hasLifecycleWork == false }
        try await start(module); XCTAssertTrue(owner.isIdle)
        client.stop(); await module.module.shutdown()
    }

    func testLazyMediaCannotDownloadUsingPreReadyOrRecoveredPermission() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try Data("placeholder".utf8).write(to: source)
        let owners = SemanticEmbeddingOwners(requiresLifecycle: true), models = ArtifactModels(source: source)
        models.rejectVerification = true
        func media() -> SemanticMediaWorker {
            SemanticMediaWorker(helper: source, model: source, projector: root.appendingPathComponent("projector"),
                models: models, makeEncoder: { _, _, _ in SemanticFixtureMediaEncoder() }, embeddingOwners: owners)
        }
        let old = media(), module = SemanticModelModule(domain: .media, lane: owners.media,
            healthDirectory: root, executable: URL(fileURLWithPath: "/bin/sh"))
        try await start(module)
        let input = SemanticMediaInput(kind: .image, path: "/private-not-read")
        XCTAssertThrowsError(try old.embed(input, cancelled: { false })); XCTAssertEqual(models.fetches, 0)
        let current = media()
        XCTAssertEqual(try current.embed(input, cancelled: { false }), semanticVector())
        XCTAssertEqual(models.fetches, 1)
        await module.module.setEnabled(false)
        try await wait { owners.media.isIdle && module.module.health.current?.hasLifecycleWork == false }
        try await start(module)
        XCTAssertThrowsError(try current.embed(input, cancelled: { false }))
        XCTAssertEqual(models.fetches, 1, "Recovery cannot prepare or fetch projector")
        await module.module.shutdown()
    }

    func testDuplicateReleaseDoesNotStopOriginalAndOwnerReleaseFencesCache() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = SemanticEmbeddingOwnership(requiresLifecycle: true)
        var adapter: SemanticModelModule? = module(owner, root: root)
        let registry = ModuleRegistry([adapter!.registration]); try await registry.start(.semanticQueryInference)
        let client = worker(owner, try script(root))
        var duplicate: SemanticModelModule? = module(owner, root: root.appendingPathComponent("other"))
        XCTAssertNotNil(duplicate); duplicate = nil
        XCTAssertEqual(try client.embed(["private"], cancelled: { false }), [semanticVector()])
        adapter = nil
        XCTAssertThrowsError(try client.embed(["old"], cancelled: { false }))
        client.release(); await registry.shutdown()
    }
}

@Suite("Semantic model health settings", .exclusiveUIState)
@MainActor struct SemanticModelHealthViewTests {
    @Test func recoveryButtonsRestoreOnlyCapability() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let owners = SemanticEmbeddingOwners(requiresLifecycle: true), clock = ModelHealthClock()
            for domain in SemanticModelModule.Domain.allCases {
                try Data("broken".utf8).write(to: root.appendingPathComponent(domain.id.rawValue + ".json"))
            }
            let modules = SemanticModelModule.Domain.allCases.map {
                SemanticModelModule(domain: $0, lane: $0.lane(in: owners), healthDirectory: root,
                    executable: URL(fileURLWithPath: "/bin/sh"), uptime: { clock.now })
            }
            let registry = ModuleRegistry(modules.map(\.registration)); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 370) { _, host in
                try await UI.wait { model.health[.semanticMediaInference]?.failure == .healthPersistence }
                try UI.snapshot(host, name: "semantic-model-health")
                clock.advance()
                for domain in SemanticModelModule.Domain.allCases {
                    #expect(UI.contains(L(model.featureKey(domain.id)), in: host))
                    let button = try #require(UI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "settings.services.\(domain.id.rawValue).recover"
                    })
                    try button.press(); try await UI.wait { model.health[domain.id]?.state == .ready }
                }
                #expect(owners.query.isIdle && owners.indexing.isIdle && owners.media.isIdle)
            }
            model.stopObserving(); await registry.shutdown()
        }
    }

    @Test func serviceKeepsOriginalModelGrantUntilExplicitRestartAndPreservesFallback() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let modelPath = directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        let vector = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        try Data("while IFS= read -r line; do printf '%s\\n' '{\"entries\":[],\"embeddings\":\(vector)}'; done\n".utf8).write(to: modelPath)
        var preferences = base.settings.semanticFileSearch; preferences.enabled = true
        base.settings.semanticFileSearch = preferences
        let owners = SemanticEmbeddingOwners(requiresLifecycle: true), watcher = SemanticFixtureWatcher()
        let service = SemanticFileSearchService(settings: base.settings, directory: directory,
            helper: URL(fileURLWithPath: "/bin/sh"), supported: true, watcher: watcher,
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false }, models: models,
            makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() }, embeddingOwners: owners)
        let modules = SemanticModelModules(readers: owners, healthDirectory: root, executable: URL(fileURLWithPath: "/bin/sh"))
        let registry = ModuleRegistry(modules.registrations); _ = await registry.startAll()
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        service.prepareForSearch()
        try await SemanticFileServiceTests.wait { !owners.query.isIdle && service.queryState == .idle }
        await registry.disable(.semanticQueryInference)
        try await SemanticFileServiceTests.wait {
            owners.query.isIdle && modules.modules[0].module.health.current?.hasLifecycleWork == false
        }
        try await registry.start(.semanticQueryInference)
        #expect(owners.query.isIdle, "Readiness cannot warm the model")
        let fallback = await service.search("reimbursement", type: .all, limit: 5)
        #expect(fallback.count == 1)
        #expect(owners.query.isIdle, "Old service query cannot inherit recovery")
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        service.prepareForSearch()
        try await SemanticFileServiceTests.wait { !owners.query.isIdle && service.queryState == .idle }
        await service.clear(removeModel: false)
        #expect(FileManager.default.fileExists(atPath: modelPath.path))
        await registry.shutdown()
    }
}
