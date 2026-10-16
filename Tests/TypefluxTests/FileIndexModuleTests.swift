import Darwin
import Foundation
import Testing
import XCTest
@testable import Typeflux

private final class FileHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance() { lock.withLock { value += 1000 } }
}

@MainActor final class FileIndexModuleTests: XCTestCase {
    private let answer = "while IFS= read -r line; do printf '{\"entries\":[],\"path\":\"/synthetic\"}\\n'; done"
    private func fixture() throws -> (URL, AskFileIndex) {
        let root = try AskAttachmentFixture.directory()
        let index = AskFileIndex(configuration: { (false, .init()) }, fullDiskAccess: { XCTFail("Readiness requested FDA"); return false },
            snapshotURL: root.appendingPathComponent("snapshot"), defaults: UserDefaults(suiteName: UUID().uuidString)!, home: root.path,
            ownership: AskFileReaderOwnership(requiresLifecycle: true), makeWatcher: { AskTestFileWatcher() })
        return (root, index)
    }
    private func reader(_ index: AskFileIndex, script: String? = nil, reaper: OwnedProcessReaper = .shared) -> AskFileReader {
        AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script ?? answer], timeout: 0.15,
            ownership: index.readerOwnership, reaper: reaper)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func attempts(_ root: URL) throws -> Int {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("fileIndex.json"))).attempts
    }
    func testReadinessDoesNotLaunchScanOrTouchPermissionAndReservesOnce() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = reader(index)
        XCTAssertThrowsError(try child.resolve("/private", blocked: []))
        let module = FileIndexModule(index: index, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.fileIndex)
        XCTAssertFalse(index.readerOwnership.isOccupied)
        for _ in 0..<5 { XCTAssertEqual(try child.resolve("/private", blocked: []), "/synthetic") }
        XCTAssertEqual(try attempts(root), 1)
        await registry.disable(.fileIndex)
        XCTAssertFalse(index.readerOwnership.isOccupied)
        try await registry.start(.fileIndex)
        XCTAssertThrowsError(try child.resolve("/old", blocked: [])) // Stopped old child cannot inherit a new generation.
        let next = reader(index); XCTAssertEqual(try next.resolve("/new", blocked: []), "/synthetic")
        await registry.shutdown()
    }
    func testTypedRefusalsAndCancellationDoNotCountAsCrashes() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let module = FileIndexModule(index: index, healthDirectory: root); try await module.module.start()
        let original = module.module.health.current?.generation
        for code in [EACCES, ENOENT, EINVAL] {
            let child = reader(index, script: "while read line; do printf '{\"entries\":[],\"error\":\(code)}\\n'; done")
            XCTAssertEqual(try child.read(.init(operation: .entry, path: "/private")).error, code)
            child.stop(); try await wait { !index.readerOwnership.isOccupied }
        }
        let child = reader(index)
        XCTAssertThrowsError(try child.read(.init(operation: .entry, path: ""), isCancelled: { true }))
        XCTAssertEqual(module.module.health.current?.generation, original)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        let saturated = reader(index, reaper: OwnedProcessReaper(capacity: 0))
        XCTAssertThrowsError(try saturated.resolve("/private", blocked: []))
        XCTAssertEqual(module.module.health.current?.state, .ready)
        await module.module.shutdown()
    }
    func testTransportFaultsHaveIndependentPersistentBudgetAndNeverReplay() async throws {
        for script in ["read line; printf 'invalid\\n'", "read line; printf '{'", "read line; exit 3",
                       "read line; exec /bin/sleep 20", "read line; exec /usr/bin/head -c 8388609 /dev/zero"] {
            let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let clock = FileHealthClock(); var policy = ModulePolicy(); policy.automaticallyRecover = false
            let module = FileIndexModule(index: index, healthDirectory: root, policy: policy, uptime: { clock.now })
            let other = MediaExtractionModule(worker: MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true), healthDirectory: root)
            let registry = ModuleRegistry([module.registration, other.registration]); _ = await registry.startAll()
            let child = reader(index, script: script)
            XCTAssertThrowsError(try child.resolve("/private", blocked: []))
            try await wait { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
            XCTAssertEqual(other.module.health.current?.state, .ready)
            clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertFalse(index.readerOwnership.isOccupied); XCTAssertEqual(try attempts(root), 2)
            await registry.shutdown()
        }
    }
    func testLaunchConfigurationAndMissingReadinessStayUnavailableUntilExplicitRecovery() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = FileHealthClock(), module = FileIndexModule(index: index, healthDirectory: root, uptime: { clock.now })
        try await module.module.start()
        let child = AskFileReader(executable: root.appendingPathComponent("missing"), ownership: index.readerOwnership)
        XCTAssertThrowsError(try child.resolve("/private", blocked: []))
        try await wait { module.module.health.current?.state == .degraded && module.module.health.current?.hasLifecycleWork == false }
        clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }
        await module.module.shutdown()
        let (otherRoot, other) = try fixture(); defer { try? FileManager.default.removeItem(at: otherRoot) }
        let missing = FileIndexModule(index: other, healthDirectory: root.appendingPathComponent("health"), executable: root.appendingPathComponent("absent"))
        do { try await missing.module.start(); XCTFail("Missing executable admitted") } catch {}
        await missing.module.shutdown()
    }
    func testCorruptionIsPreservedUntilReset() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fileIndex.json"), bytes = Data("broken".utf8)
        try bytes.write(to: file)
        let clock = FileHealthClock(), module = FileIndexModule(index: index, healthDirectory: root, uptime: { clock.now })
        do { try await module.module.start(); XCTFail("Corruption ignored") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }
        XCTAssertFalse(index.readerOwnership.isOccupied); await module.module.shutdown()
    }
    func testBlockedConsumerRetainsLineageAfterChildReapingAndBoundedDisable() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = FileIndexModule(index: index, healthDirectory: root, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.fileIndex)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let owner = index.readerOwnership, script = answer
        let task = Task.detached { () -> Bool in
            let child = AskFileReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], ownership: owner)
            do { try child.stream(.init(operation: .resolve, path: "")) { _ in entered.signal(); release.wait(); return true }; return true }
            catch { return false }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        await registry.disable(.fileIndex)
        XCTAssertTrue(owner.isOccupied)
        do { try await registry.start(.fileIndex); XCTFail("Occupied replacement") } catch {}
        release.signal(); let succeeded = await task.value; XCTAssertFalse(succeeded)
        try await wait { !owner.isOccupied && module.module.health.current?.hasLifecycleWork == false }
        await registry.shutdown()
    }
    func testDelayedReapingAndLateAttachKeepOriginalOwnership() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = FileIndexModule(index: index, healthDirectory: root, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.fileIndex)
        let owner = index.readerOwnership, id = try owner.reserve { false }
        try owner.begin(id)
        await registry.disable(.fileIndex)
        let stopped = DispatchSemaphore(value: 0)
        owner.attach(id) { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success); owner.reaped(id); XCTAssertTrue(owner.isOccupied)
        owner.end(id); try await wait { !owner.isOccupied && module.module.health.current?.hasLifecycleWork == false }
        await registry.shutdown()
    }
    func testAdapterReleaseCancelsButDuplicateBindingCannotStopOwner() async throws {
        let (root, index) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var module: FileIndexModule? = FileIndexModule(index: index, healthDirectory: root)
        let registry = ModuleRegistry([module!.registration]); try await registry.start(.fileIndex)
        let child = reader(index); _ = try child.resolve("/private", blocked: [])
        var duplicate: FileIndexModule? = FileIndexModule(index: index, healthDirectory: root.appendingPathComponent("other"))
        XCTAssertNotNil(duplicate); duplicate = nil
        XCTAssertEqual(try child.resolve("/still", blocked: []), "/synthetic")
        module = nil; try await wait { !index.readerOwnership.isOccupied }
        XCTAssertThrowsError(try child.resolve("/old", blocked: [])); await registry.shutdown()
    }
    func testManagedIndexPreservesCacheAndSnapshotWithoutRecoveryScan() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree"); try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data().write(to: tree.appendingPathComponent("Before.txt"))
        var settings = AskLauncherSearchSettings(); settings.fileRoots = [tree.path]; settings.excludedPaths = []
        var access = true
        let owner = AskFileReaderOwnership(requiresLifecycle: true), watcher = AskTestFileWatcher(), snapshot = root.appendingPathComponent("index.bin")
        let index = AskFileIndex(configuration: { (true, settings) }, fullDiskAccess: { access }, snapshotURL: snapshot,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, home: root.path, ownership: owner, makeWatcher: { watcher })
        let module = FileIndexModule(index: index, healthDirectory: root)
        let registry = ModuleRegistry([module.registration])
        try await registry.start(.fileIndex); index.start(); index.waitUntilIdle()
        XCTAssertEqual(index.search(.init("before"), options: .init()).count, 1)
        let saved = try Data(contentsOf: snapshot)
        await registry.disable(.fileIndex); XCTAssertFalse(owner.isOccupied)
        try Data().write(to: tree.appendingPathComponent("After.txt"))
        try await registry.start(.fileIndex); index.start(); index.waitUntilIdle()
        XCTAssertTrue(index.search(.init("after"), options: .init()).isEmpty)
        XCTAssertEqual(index.search(.init("before"), options: .init()).count, 1)
        XCTAssertEqual(try Data(contentsOf: snapshot), saved)
        index.rebuild(); index.waitUntilIdle()
        XCTAssertEqual(index.search(.init("after"), options: .init()).count, 1)
        await registry.disable(.fileIndex)
        let forgotten = try XCTUnwrap(index.search(.init("after"), options: .init()).first?.path)
        index.forget(forgotten); index.waitUntilIdle()
        XCTAssertTrue(index.search(.init("after"), options: .init()).isEmpty)
        XCTAssertEqual(index.search(.init("before"), options: .init()).count, 1)
        access = false
        index.start(); index.waitUntilIdle()
        XCTAssertTrue(index.search(.init("before"), options: .init()).isEmpty, "Explicit launcher permission refresh still fences old cache")
        XCTAssertEqual(index.status.count, 0); XCTAssertTrue(index.status.blocked.isEmpty)
        settings.fileRoots = [root.appendingPathComponent("different").path]
        index.start(); index.waitUntilIdle()
        XCTAssertTrue(index.search(.init("before"), options: .init()).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        await module.module.shutdown(); await registry.shutdown()
    }
}

@Suite("File indexing health presentation", .exclusiveUIState)
@MainActor struct FileIndexHealthViewTests {
    @Test func recoveryRestoresAdmissionWithoutScanning() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("fileIndex.json"))
            let clock = FileHealthClock()
            let index = AskFileIndex(configuration: { (false, .init()) }, ownership: AskFileReaderOwnership(requiresLifecycle: true))
            let module = FileIndexModule(index: index, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.fileIndex]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.fileIndex"), in: host))
                try UI.snapshot(host, name: "file-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.fileIndex.recover" })
                clock.advance(); try button.press()
                try await UI.wait { model.health[.fileIndex]?.state == .ready }
                #expect(!index.readerOwnership.isOccupied)
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
