import AppKit
import Darwin
import SwiftUI
import Testing
import XCTest
@testable import Typeflux

private final class NativeHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var callsValue = 0, time = 0.0
    private var continuation: CheckedContinuation<Void, Never>?
    private var reap: (@Sendable () -> Void)?
    var calls: Int { lock.withLock { callsValue } }
    var now: Double { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    func called(_ p: ManagedProcess.Request? = nil) {
        p?.onStarted?(); lock.withLock { callsValue += 1; reap = p?.onReaped }
    }
    func reaped() { lock.withLock { reap }?() }
    func suspend() async { await withCheckedContinuation { c in lock.withLock { continuation = c } } }
    var suspended: Bool { lock.withLock { continuation != nil } }
    func resume() { let c = lock.withLock { let c = continuation; continuation = nil; return c }; c?.resume() }
    static func reply(_ p: ManagedProcess.Request, outcome: NativeSystemOutcome = .completed) throws -> ManagedProcess.Result {
        let request = try NativeSystemProtocol.decodeRequest(XCTUnwrap(p.stdin))
        let response = NativeSystemResponse(requestID: request.requestID, operation: request.operation, outcome: outcome)
        return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
    }
}

@MainActor final class NativeSystemModuleTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Native health did not settle")
    }
    private func failure(_ expected: NativeSystemFailure, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected failure") } catch { XCTAssertEqual(error as? NativeSystemFailure, expected) }
    }
    private func record(_ root: URL) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("nativeSystem.json")))
    }
    func testDefaultFailsClosedAndReadinessNeverExecutesAProbe() async throws {
        await failure(.disabled) { try await NativeSystemWorker.shared.perform(.toggleWiFi) }
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeHealthState()
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in
            state.called(); return try NativeHealthState.reply(p)
        })
        let module = NativeSystemModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.nativeSystem)
        XCTAssertEqual(state.calls, 0); XCTAssertEqual(worker.activeCount, 0)
        for _ in 0..<3 { try await worker.perform(.toggleWiFi) }
        XCTAssertEqual(try record(root).attempts, 1)
        await registry.disable(.nativeSystem)
        await failure(.disabled) { try await worker.perform(.toggleBluetooth) }
        try await registry.start(.nativeSystem)
        XCTAssertEqual(state.calls, 3); XCTAssertEqual(try record(root).attempts, 1) // Clean successful stop resets the prior generation.
        await registry.shutdown()
        await failure(.disabled) { try await worker.perform(.toggleWiFi) }
    }
    func testControlledNotExecutedAndUnknownRemainTruthfulWithoutFaultOrReplay() async throws {
        for outcome in [NativeSystemOutcome.notExecuted, .unknown] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = NativeHealthState()
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in
                state.called(p); defer { state.reaped() }; return try NativeHealthState.reply(p, outcome: outcome)
            })
            let module = NativeSystemModule(worker: worker, healthDirectory: root)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.nativeSystem)
            let generation = module.module.health.current?.generation
            for _ in 0..<3 { await failure(outcome == .notExecuted ? .notExecuted : .unknown) { try await worker.perform(.toggleBluetooth) } }
            XCTAssertEqual(module.module.health.current?.state, .ready)
            XCTAssertEqual(module.module.health.current?.generation, generation); XCTAssertEqual(try record(root).attempts, 1)
            await registry.disable(.nativeSystem); try await registry.start(.nativeSystem)
            XCTAssertEqual(state.calls, 3); await registry.shutdown()
        }
    }
    func testTransportFaultsFenceOnlyNativeGenerationAndWaitForExplicitRecovery() async throws {
        for mode in 0..<6 {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = NativeHealthState()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in
                state.called(p); defer { state.reaped() }
                if mode == 5 { throw CocoaError(.fileReadUnknown) }
                let valid = try NativeHealthState.reply(p)
                return .init(termination: mode == 0 ? .timedOut : mode == 1 ? .exited(7) : .exited(0), exitCode: 0,
                    stdout: mode == 2 ? "private broken" : mode == 3 ? valid.stdout.replacingOccurrences(of: "completed", with: "invalid") : valid.stdout,
                    stderr: "private diagnostic", outputTruncated: mode == 4)
            })
            let module = NativeSystemModule(worker: worker, healthDirectory: root, policy: policy, uptime: { state.now })
            let media = MediaExtractionModule(worker: MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true), healthDirectory: root)
            let registry = ModuleRegistry([module.registration, media.registration]); _ = await registry.startAll()
            let generation = media.module.health.current?.generation
            await failure(.unknown) { try await worker.perform(.toggleWiFi) }
            try await wait { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
            await failure(.coolingDown) { try await worker.perform(.toggleWiFi) }
            XCTAssertEqual(media.module.health.current?.generation, generation); XCTAssertEqual(media.module.health.current?.state, .ready)
            state.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertEqual(state.calls, 1); await registry.shutdown()
        }
    }
    func testLaunchConfigurationAndCorruptHealthPreserveExplicitResetSemantics() async throws {
        for code in [EACCES, EPERM, ENOENT, ENOEXEC] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = NativeHealthState()
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _ in
                state.called(); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            })
            let module = NativeSystemModule(worker: worker, healthDirectory: root, uptime: { state.now })
            let registry = ModuleRegistry([module.registration]); try await registry.start(.nativeSystem)
            await failure(.notExecuted) { try await worker.perform(.toggleWiFi) }
            try await wait { module.module.health.current?.state == .degraded && module.module.health.current?.hasLifecycleWork == false }
            state.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertEqual(state.calls, 1); await registry.shutdown()
        }
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nativeSystem.json"); try Data("broken".utf8).write(to: file)
        let state = NativeHealthState()
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _ in XCTFail(); throw NativeSystemFailure.notExecuted })
        let module = NativeSystemModule(worker: worker, healthDirectory: root, uptime: { state.now })
        let registry = ModuleRegistry([module.registration]); let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        state.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root).attempts, 1); await registry.shutdown()
    }
    func testMissingExecutableAndDuplicateBindingCannotStartASecondLifecycle() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/missing/native-health-fixture"), requiresLifecycle: true)
        let first = NativeSystemModule(worker: worker, healthDirectory: root)
        let second = NativeSystemModule(worker: worker, healthDirectory: root.appendingPathComponent("second"))
        let failures = await ModuleRegistry([first.registration]).startAll(); XCTAssertEqual(failures.count, 1)
        do { try await second.module.start(); XCTFail() } catch {}
        await first.module.shutdown(); await second.module.shutdown()
    }
    func testCancelledHostAndDelayedChildKeepSingleSlotAndNeverReplayAfterRecovery() async throws {
        for childFirst in [false, true] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = NativeHealthState()
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in
                state.called(p); if childFirst { state.reaped() }; await state.suspend(); return try NativeHealthState.reply(p)
            })
            var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
            let module = NativeSystemModule(worker: worker, healthDirectory: root, policy: policy)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.nativeSystem)
            let action = Task { try await worker.perform(.toggleWiFi) }; try await wait { state.suspended }
            await failure(.busy) { try await worker.perform(.toggleBluetooth) }
            action.cancel(); await registry.disable(.nativeSystem)
            XCTAssertEqual(worker.activeCount, 1)
            do { try await registry.start(.nativeSystem); XCTFail() } catch {}
            state.resume(); await failure(.unknown) { try await action.value }
            if !childFirst {
                XCTAssertEqual(worker.activeCount, 1)
                await failure(.busy) { try await worker.perform(.toggleWiFi) }
                state.reaped()
            }
            try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
            try await registry.start(.nativeSystem); XCTAssertEqual(state.calls, 1)
            state.reaped(); XCTAssertEqual(worker.activeCount, 0)
            await registry.shutdown()
        }
    }
    func testShutdownReturnsWithUncooperativeHostButSlotAndUnknownOutcomeRemainOwned() async throws {
        let state = NativeHealthState()
        let worker = NativeSystemWorker(run: { p in state.called(p); await state.suspend(); return try NativeHealthState.reply(p) })
        let task = Task { try await worker.perform(.toggleWiFi) }; try await wait { state.suspended }
        let began = ContinuousClock.now; await worker.shutdown()
        XCTAssertLessThan(began.duration(to: .now), .seconds(3)); XCTAssertEqual(worker.activeCount, 1)
        XCTAssertFalse(worker.isEnabled)
        state.resume(); await failure(.unknown) { try await task.value }
        XCTAssertEqual(worker.activeCount, 1); state.reaped(); XCTAssertEqual(worker.activeCount, 0)
        await failure(.disabled) { try await worker.perform(.toggleWiFi) }
    }
    func testManagedHarmlessProcessAndCrashDoNotExecuteOrReplayNativeAdapter() async throws {
        for script in ["sed 's/}$/ ,\"outcome\":\"completed\"}/'", "kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 0.2, requiresLifecycle: true)
            let module = NativeSystemModule(worker: worker, healthDirectory: root, policy: policy)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.nativeSystem)
            if script.hasPrefix("sed") { try await worker.perform(.toggleBluetooth) }
            else { await failure(.unknown) { try await worker.perform(.toggleBluetooth) } }
            try await wait { worker.activeCount == 0 }; await registry.shutdown()
        }
    }
    func testAdapterReleaseFencesLateSuccessWithoutReplayingCommand() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeHealthState()
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in
            state.called(p); await state.suspend(); XCTAssertTrue(Task.isCancelled); state.reaped(); return try NativeHealthState.reply(p)
        })
        var module: NativeSystemModule? = NativeSystemModule(worker: worker, healthDirectory: root)
        try await module!.module.start()
        let task = Task { try await worker.perform(.toggleWiFi) }; try await wait { state.suspended }
        module = nil
        XCTAssertEqual(worker.activeCount, 1)
        state.resume(); await failure(.unknown) { try await task.value }
        XCTAssertEqual(worker.activeCount, 0); XCTAssertEqual(state.calls, 1)
        await failure(.disabled) { try await worker.perform(.toggleWiFi) }
        await worker.shutdown()
    }
    func testCancellationInstallationAndOldReaperCannotReleaseANewerCommand() async {
        let activity = NativeSystemActivity(), first = UUID(), second = UUID(), state = NativeHealthState()
        activity.begin(first); activity.stop()
        activity.installCancellation(first) { state.called() }
        XCTAssertEqual(state.calls, 1)
        activity.returned(first); await activity.waitForRetirement()
        activity.begin(second); activity.started(second)
        activity.returned(first); activity.reaped(first); XCTAssertEqual(activity.count, 1)
        activity.installCancellation(first) { state.called() }
        XCTAssertEqual(state.calls, 2)
        activity.returned(second); XCTAssertEqual(activity.count, 1)
        activity.reaped(second); XCTAssertEqual(activity.count, 0)
    }
    func testOwnerReleaseAndQueuedCancellationFenceAdmissionWithoutHidingUserFailure() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = NativeHealthState()
        let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p in state.called(); return try NativeHealthState.reply(p) })
        var module: NativeSystemModule? = NativeSystemModule(worker: worker, healthDirectory: root)
        try await module!.module.start()
        let task = Task { try await worker.perform(.toggleWiFi) }; task.cancel()
        await failure(.notExecuted) { try await task.value }; XCTAssertEqual(state.calls, 0)
        module = nil
        await failure(.disabled) { try await worker.perform(.toggleWiFi) }
        let runner = AskSystemCommandRunner(native: worker)
        XCTAssertTrue(runner.presentsFailures(for: .toggleWiFi))
        do { try await runner.run(.toggleWiFi); XCTFail() }
        catch let error as AskPluginFailure { XCTAssertFalse(error.retry); XCTAssertEqual(error.message, L(NativeSystemFailure.disabled.messageKey)) }
        await worker.shutdown()
    }
}

@Suite("Native system health presentation", .exclusiveUIState)
@MainActor struct NativeSystemHealthViewTests {
    @Test func recoveryRestoresCapabilityWithoutExecutingCommand() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("nativeSystem.json"))
            let state = NativeHealthState()
            let worker = NativeSystemWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _ in Issue.record("Recovery ran a command"); throw NativeSystemFailure.notExecuted })
            let module = NativeSystemModule(worker: worker, healthDirectory: root, uptime: { state.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.nativeSystem]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.nativeSystem)), in: host))
                try UI.snapshot(host, name: "native-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.nativeSystem.recover" })
                state.advance(); try button.press()
                try await UI.wait { model.health[.nativeSystem]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
