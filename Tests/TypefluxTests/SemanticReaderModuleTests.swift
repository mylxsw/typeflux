import Darwin
import Foundation
import Testing
import XCTest
@testable import Typeflux

private final class SemanticHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 1000 } }
}

private final class SemanticHealthReader: AskFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    let response: AskFileReadResponse
    let failure: (any Error)?
    init(response: AskFileReadResponse = .init(path: "/synthetic"), failure: (any Error)? = nil) {
        self.response = response; self.failure = failure
    }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        lock.withLock { count += 1 }
        if let failure { throw failure }
        return response
    }
}

@MainActor final class SemanticReaderModuleTests: XCTestCase {
    private let request = AskFileReadRequest(operation: .resolve, path: "/private-fixture")
    private let answer = "while IFS= read -r line; do printf '{\"entries\":[],\"path\":\"/synthetic\"}\\n'; done"
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func fixture(script: String? = nil, clock: SemanticHealthClock = .init(),
                         cleanup: TimeInterval = 0.05) throws -> (URL, SemanticFileReaderLane, SemanticReaderModule) {
        let root = try semanticFixture(), owner = AskFileReaderOwnership(requiresLifecycle: true), script = script ?? answer
        let lane = SemanticFileReaderLane(makeReader: {
            AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 0.12, ownership: owner)
        }, requiresLifecycle: true, ownership: owner)
        var policy = ModulePolicy(); policy.automaticallyRecover = false; policy.cleanupTimeout = cleanup
        return (root, lane, SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root,
            policy: policy, uptime: { clock.now }))
    }

    func testThreeIndependentRegistrationsReserveOnceAndReadinessDoesNoWork() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let lanes = SemanticFileReaders(requiresLifecycle: true), old = lanes.validation.scope()
        XCTAssertThrowsError(try old.read(request, isCancelled: { false }))
        let modules = SemanticReaderModules(readers: lanes, healthDirectory: root)
        let registry = ModuleRegistry(modules.registrations)
        XCTAssertEqual(Set(modules.registrations.map(\.id)), [.semanticValidation, .semanticIndexReading, .semanticPriorityReading])
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        XCTAssertThrowsError(try old.read(request, isCancelled: { false }), "Ready cannot bless a pre-DI scope")
        for domain in SemanticReaderModule.Domain.allCases {
            let lane = domain.lane(in: lanes)
            XCTAssertFalse(lane.isOccupied)
            let scope = lane.scope()
            for _ in 0..<3 {
                let result = try scope.resolve(root.path, blocked: [])
                XCTAssertEqual(URL(fileURLWithPath: result).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            }
            let record = try JSONDecoder().decode(ModuleHealthStore.Record.self,
                from: Data(contentsOf: root.appendingPathComponent(domain.id.rawValue + ".json")))
            XCTAssertEqual(record.attempts, 1)
        }
        await registry.shutdown()
        XCTAssertFalse(lanes.validation.isOccupied || lanes.indexing.isOccupied || lanes.priority.isOccupied)
    }

    func testCorruptionIsPreservedAndResetDoesNotInvokeFactoryOrOtherDomains() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("semanticPriorityReading.json"), bytes = Data("corrupt".utf8)
        try bytes.write(to: file)
        let calls = SemanticHealthReader(), lanes = SemanticFileReaders(makeReader: { calls }, requiresLifecycle: true)
        let clock = SemanticHealthClock()
        let modules = SemanticReaderModule.Domain.allCases.map {
            SemanticReaderModule(domain: $0, lane: $0.lane(in: lanes), healthDirectory: root, uptime: { clock.now })
        }
        let registry = ModuleRegistry(modules.map(\.registration)); let failed = await registry.startAll()
        XCTAssertEqual(failed.count, 1); XCTAssertEqual(calls.calls, 0)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(modules[0].module.health.current?.state, .ready)
        clock.advance()
        let response = await modules[2].module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(response, .started); try await wait { modules[2].module.health.current?.state == .ready }
        XCTAssertEqual(calls.calls, 0)
        await registry.shutdown()
    }

    func testExpectedRefusalsAndConfigurationAreDistinctFromProtocolFaults() async throws {
        for failure in [AskFileReadError.nonLocalMount, .unavailable, .cancelled] {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = SemanticHealthReader(failure: failure), lane = SemanticFileReaderLane(makeReader: { reader }, requiresLifecycle: true)
            let module = SemanticReaderModule(domain: .indexing, lane: lane, healthDirectory: root)
            try await module.module.start(); let scope = lane.scope()
            XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
            XCTAssertEqual(module.module.health.current?.state, .ready)
            await module.module.shutdown()
        }
        for code in [EACCES, EPERM, ENOENT, ENOEXEC] {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = SemanticHealthReader(failure: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            let lane = SemanticFileReaderLane(makeReader: { reader }, requiresLifecycle: true)
            let module = SemanticReaderModule(domain: .priority, lane: lane, healthDirectory: root)
            try await module.module.start(); let scope = lane.scope()
            XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
            try await wait { module.module.health.current?.state != .ready }
            XCTAssertEqual(reader.calls, 1)
            await module.module.shutdown()
        }
        let faults: [any Error] = [AskFileReadError.protocolError, AskFileReadError.timeout,
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "private fixture"))]
        for fault in faults {
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = SemanticHealthReader(failure: fault)
            let lane = SemanticFileReaderLane(makeReader: { reader }, requiresLifecycle: true)
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let module = SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root, policy: policy)
            try await module.module.start(); let scope = lane.scope()
            XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
            try await wait { module.module.health.current?.state != .ready }
            XCTAssertEqual(reader.calls, 1)
            await module.module.shutdown()
        }
        let (root, lane, module) = try fixture(script: "while read line; do printf '{\"entries\":[],\"error\":13}\\n'; done")
        defer { try? FileManager.default.removeItem(at: root) }
        try await module.module.start(); let scope = lane.scope()
        XCTAssertEqual(try scope.read(request, isCancelled: { false }).error, EACCES)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        await module.module.shutdown()
    }

    func testTransportFaultsFenceOldScopesAndRecoveryNeverReadsAgain() async throws {
        for script in ["read line; printf 'invalid\\n'", "read line; printf '{'", "read line; exit 3", "read line; exec sleep 5"] {
            let clock = SemanticHealthClock(), (root, lane, module) = try fixture(script: script, clock: clock)
            defer { try? FileManager.default.removeItem(at: root) }
            try await module.module.start(); let scope = lane.scope(), generation = module.module.health.current?.generation
            XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
            try await wait { !lane.isOccupied && module.module.health.current?.hasLifecycleWork == false }
            clock.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertNotEqual(module.module.health.current?.generation, generation)
            XCTAssertFalse(lane.ownership.isOccupied, "Recovery cannot launch a read")
            XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
            await module.module.shutdown()
        }
    }

    func testDisableKeepsUncooperativeConsumerAndRejectsLateSuccess() async throws {
        let (root, lane, module) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ModuleRegistry([module.registration]); try await registry.start(.semanticValidation)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), scope = lane.scope(), request = request
        let task = Task.detached { () -> Bool in
            do { try scope.stream(request, isCancelled: { false }) { _ in entered.signal(); release.wait(); return true }; return true }
            catch { return false }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        await registry.disable(.semanticValidation)
        XCTAssertTrue(lane.isOccupied)
        do { try await registry.start(.semanticValidation); XCTFail("Expanded occupied lane") } catch {}
        let premature = lane.scope()
        release.signal(); let success = await task.value; XCTAssertFalse(success)
        try await wait { !lane.isOccupied && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.semanticValidation)
        XCTAssertThrowsError(try premature.read(request, isCancelled: { false }))
        XCTAssertEqual(try lane.scope().read(request, isCancelled: { false }).path, "/synthetic")
        await registry.shutdown()
    }

    func testBlockedFactoryRetainsHostCapacityWithoutNativeChild() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), reader = SemanticHealthReader()
        let lane = SemanticFileReaderLane(makeReader: { entered.signal(); release.wait(); return reader }, requiresLifecycle: true)
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.semanticValidation)
        let scope = lane.scope(), request = request
        let task = Task.detached { try? scope.read(request, isCancelled: { false }) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        await registry.disable(.semanticValidation)
        XCTAssertTrue(lane.isOccupied); XCTAssertFalse(lane.ownership.isOccupied)
        release.signal(); let result = await task.value; XCTAssertNil(result)
        try await wait { !lane.isOccupied && module.module.health.current?.hasLifecycleWork == false }
        XCTAssertEqual(reader.calls, 0)
        await registry.shutdown()
    }

    func testDelayedCollectionLateAttachAndHostRetirementAreAllRequired() async throws {
        let (root, lane, module) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ModuleRegistry([module.registration]); try await registry.start(.semanticValidation)
        let owner = lane.ownership, id = try owner.reserve { false }; try owner.begin(id)
        await registry.disable(.semanticValidation)
        let stop = DispatchSemaphore(value: 0); owner.attach(id) { stop.signal() }
        XCTAssertEqual(stop.wait(timeout: .now() + 1), .success)
        owner.reaped(id); XCTAssertTrue(lane.isOccupied)
        owner.end(id); try await wait { !lane.isOccupied && module.module.health.current?.hasLifecycleWork == false }
        await registry.shutdown()
    }

    func testReleaseFencesOwnerButDuplicateCannotCancelOriginal() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticHealthReader(), lane = SemanticFileReaderLane(makeReader: { reader }, requiresLifecycle: true)
        var module: SemanticReaderModule? = SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root)
        let registry = ModuleRegistry([module!.registration]); try await registry.start(.semanticValidation)
        let scope = lane.scope()
        var duplicate: SemanticReaderModule? = SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root.appendingPathComponent("other"))
        XCTAssertNotNil(duplicate); duplicate = nil
        XCTAssertEqual(try scope.read(request, isCancelled: { false }).path, "/synthetic")
        module = nil
        XCTAssertThrowsError(try scope.read(request, isCancelled: { false }))
        await registry.shutdown()
    }

    func testStatusObservationsDoNotCompeteWithTypedAdmission() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SemanticHealthReader(), lane = SemanticFileReaderLane(makeReader: { reader }, requiresLifecycle: true)
        let module = SemanticReaderModule(domain: .validation, lane: lane, healthDirectory: root)
        try await module.module.start()
        let scope = lane.scope(), done = AskSearchCancellation(), entered = DispatchSemaphore(value: 0)
        let observer = Task.detached {
            entered.signal()
            for _ in 0..<100_000 {
                if done.isCancelled { return }
                _ = lane.isOccupied
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 0..<300 { XCTAssertNoThrow(try scope.read(request, isCancelled: { false })) }
        done.cancel(); await observer.value
        XCTAssertEqual(reader.calls, 300)
        await module.module.shutdown()
    }
}

@Suite("Semantic reader health settings", .exclusiveUIState)
@MainActor struct SemanticReaderHealthViewTests {
    @Test func initialStartupIsExplicitAndHealthRecoveryNeverRescans() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: models.source, to: directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        var preferences = base.settings.semanticFileSearch; preferences.enabled = true
        base.settings.semanticFileSearch = preferences
        let permission = AskSearchCancellation(), watcher = SemanticFixtureWatcher()
        let service = SemanticFileSearchService(settings: base.settings, directory: directory,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { permission.cancel(); return true }, automaticStart: true,
            lowPowerMode: { false }, thermalConstrained: { false }, models: models,
            makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }, requiresReaderLifecycle: true, deferInitialStart: true)
        let modules = SemanticReaderModules(readers: service.readers, healthDirectory: root)
        let registry = ModuleRegistry(modules.registrations)
        #expect(service.phase == .off && !permission.isCancelled && reader.directoryReads == 0)
        await service.startForApplication(using: registry)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let firstScan = reader.directoryReads
        #expect(firstScan > 0 && permission.isCancelled)
        let cancelledStartup = Task { await service.startForApplication(using: registry) }
        cancelledStartup.cancel(); await cancelledStartup.value
        #expect(reader.directoryReads == firstScan)
        watcher.change?([.init(path: reader.path, rescan: true, isDirectory: false)], 1)
        try await SemanticFileServiceTests.wait { service.phase == .ready && reader.directoryReads > firstScan }
        let scans = reader.directoryReads
        watcher.change?([.init(path: reader.path, rescan: true, isDirectory: false)], 2)
        await Task.yield()
        await registry.disable(.semanticIndexReading)
        try await registry.start(.semanticIndexReading)
        // Drain the existing 150ms watcher debounce. It must retain the old grant.
        try await Task.sleep(for: .milliseconds(220))
        #expect(service.phase == .ready && reader.directoryReads == scans)
        #expect(await service.search("reimbursement", type: .all, limit: 5).count == 1)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready && reader.directoryReads > scans }
        await service.clear(removeModel: false)
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        await registry.shutdown()
    }

    @Test func recoveryOnlyRestoresIndependentReaderCapabilities() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
            let reader = SemanticHealthReader(), lanes = SemanticFileReaders(makeReader: { reader }, requiresLifecycle: true)
            for domain in SemanticReaderModule.Domain.allCases {
                try Data("broken".utf8).write(to: root.appendingPathComponent(domain.id.rawValue + ".json"))
            }
            let clock = SemanticHealthClock(), modules = SemanticReaderModule.Domain.allCases.map {
                SemanticReaderModule(domain: $0, lane: $0.lane(in: lanes), healthDirectory: root, uptime: { clock.now })
            }
            let registry = ModuleRegistry(modules.map(\.registration)); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 370) { _, host in
                try await UI.wait { model.health[.semanticPriorityReading]?.failure == .healthPersistence }
                try UI.snapshot(host, name: "semantic-reader-health")
                clock.advance()
                for domain in SemanticReaderModule.Domain.allCases {
                    #expect(UI.contains(L("settings.services.\(domain.id.rawValue)"), in: host))
                    let button = try #require(UI.elements(in: host).first {
                        $0.value("accessibilityIdentifier") as? String == "settings.services.\(domain.id.rawValue).recover"
                    })
                    try button.press(); try await UI.wait { model.health[domain.id]?.state == .ready }
                }
                #expect(reader.calls == 0)
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
