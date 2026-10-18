import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

private final class ExtractionState: @unchecked Sendable {
    let lock = NSLock()
    private var time: TimeInterval = 0
    private var count = 0
    var now: TimeInterval { lock.withLock { time } }
    var calls: Int { lock.withLock { count } }
    func advance() { lock.withLock { time += 601 } }
    func called() { lock.withLock { count += 1 } }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var reaped: (@Sendable () -> Void)?
    var callbacks: [@Sendable () -> Void] = []
}

final class MediaExtractionModuleTests: XCTestCase {
    private func root() throws -> URL { try AskAttachmentFixture.directory() }
    private func fixture(_ root: URL, state: ExtractionState = ExtractionState(), automatic: Bool = false,
                         run: @escaping MediaWorker.Runner) -> (MediaWorker, MediaExtractionModule, ModuleRegistry) {
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: run)
        var policy = ModulePolicy(); policy.automaticallyRecover = automatic; policy.cleanupTimeout = 0.04
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, policy: policy, uptime: { state.now })
        return (worker, module, ModuleRegistry([module.registration]))
    }
    private func response(_ p: ManagedProcess.Request, failure: MediaFailure? = nil) throws -> ManagedProcess.Result {
        let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
        let value = MediaResponse(id: request.id, items: failure == nil ? [.init(text: "private", pages: 1)] : [], failure: failure)
        return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), stderr: "", outputTruncated: false)
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Lifecycle did not settle")
    }
    private func record(_ root: URL) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("mediaExtraction.json")))
    }

    func testReservationIsPerGenerationAndExpectedRefusalsDoNotPoisonService() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state) { p, _ in
            state.called(); return try self.response(p, failure: state.calls <= 3 ? [.unreadable, .tooLarge, .unavailable][state.calls - 1] : nil)
        }
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await registry.start(.mediaExtraction)
        let generation = module.module.health.current?.generation
        for _ in 0..<3 { XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data()))) }
        XCTAssertThrowsError(try worker.decode(.pdf, input: .file(root.appendingPathComponent("missing"))))
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data()), isCancelled: { true }))
        for _ in 0..<8 { XCTAssertEqual(try worker.decode(.pdf, input: .data(Data())).items.first?.text, "private") }
        XCTAssertEqual(try record(root).attempts, 1)
        XCTAssertEqual(module.module.health.current?.generation, generation)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root).attempts, 0)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
    }

    func testFaultFencesImmediatelyRecoveryDoesNotReplayAndOldSignalIsIgnored() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state) { p, _ in
            state.called()
            if state.calls == 1 { return .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false) }
            return try self.response(p)
        }
        try await registry.start(.mediaExtraction)
        let old = try XCTUnwrap(module.module.health.current?.generation)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
        let response1 = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(response1, .coolingDown)
        state.advance()
        let response2 = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(response2, .started)
        try await eventually { module.module.health.current?.state == .ready }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(try record(root).attempts, 2)
        await module.module.supervisor.externalActivity(failedGeneration: old)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        _ = try worker.decode(.pdf, input: .data(Data()))
        XCTAssertEqual(state.calls, 2)
        await registry.shutdown()
    }

    func testAutomaticRecoveryReopensOnlyAfterCooldownWithoutReplayingInput() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state, automatic: true) { _, _ in
            state.called(); throw MediaFailure.unavailable
        }
        try await registry.start(.mediaExtraction)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.state == .recovering }
        state.advance()
        try await eventually { module.module.health.current?.state == .ready }
        XCTAssertEqual(state.calls, 1)
        await registry.shutdown()
    }

    func testFaultCancelsSiblingAndRetirementWaitsForItsUncooperativeHost() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state) { p, _ in
            state.called()
            if state.calls == 1 {
                state.entered.signal(); state.release.wait()
                return try self.response(p)
            }
            return .init(termination: .exited(0), exitCode: 0, stdout: "{}", stderr: "", outputTruncated: false)
        }
        try await registry.start(.mediaExtraction)
        let first = Task.detached { try worker.decode(.pdf, input: .data(Data())) }
        XCTAssertEqual(state.entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.failure == .cleanupTimeout }
        state.advance()
        let recovery = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(recovery, .busy)
        state.release.signal()
        do { _ = try await first.value; XCTFail("Sibling crossed fault generation") } catch {}
        try await eventually { module.module.health.current?.hasLifecycleWork == false }
        let next = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(next, .started)
        try await eventually { module.module.health.current?.state == .ready }
        XCTAssertEqual(state.calls, 2)
        XCTAssertEqual(try record(root).attempts, 2)
        await registry.shutdown()
    }

    func testUnreapedChildHoldsCleanupAndPersistentFailureAcrossDisable() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state) { p, _ in
            p.onStarted?(); state.reaped = p.onReaped
            return .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "", outputTruncated: false)
        }
        try await registry.start(.mediaExtraction)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.failure == .cleanupTimeout }
        XCTAssertEqual(module.module.health.current?.activeOperations, 1)
        state.advance()
        let response3 = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(response3, .busy)
        await registry.disable(.mediaExtraction)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        state.reaped?()
        try await eventually { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        XCTAssertEqual(try record(root).attempts, 1, "A failed generation must not erase persisted failures on disable")
        try await registry.start(.mediaExtraction)
        XCTAssertEqual(try record(root).attempts, 2)
        await registry.shutdown()
    }

    func testUncooperativeHostLateResultIsFencedAndCannotOverlapNewGeneration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root) { p, _ in
            p.onStarted?(); p.onReaped?(); state.entered.signal(); state.release.wait()
            return try self.response(p)
        }
        try await registry.start(.mediaExtraction)
        let operation = Task.detached { try worker.decode(.pdf, input: .data(Data())) }
        XCTAssertEqual(state.entered.wait(timeout: .now() + 2), .success)
        await registry.disable(.mediaExtraction)
        XCTAssertEqual(worker.activeCount, 1)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        state.release.signal()
        do { _ = try await operation.value; XCTFail("Late private result delivered") } catch {}
        try await eventually { module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.mediaExtraction)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        registry.preventNewWork()
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        await registry.shutdown()
    }

    func testCorruptAndQuarantinedPersistenceRequireDeliberateReset() async throws {
        for corrupt in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("mediaExtraction.json"), state = ExtractionState()
            if corrupt { try Data("private damaged metadata".utf8).write(to: url) }
            else { for _ in 0..<4 { try ModuleHealthStore(url: url).reserve() } }
            let before = try Data(contentsOf: url)
            let (worker, module, registry) = fixture(root, state: state) { p, _ in try self.response(p) }
            do { try await registry.start(.mediaExtraction); XCTFail("Should refuse") } catch {}
            XCTAssertEqual(module.module.health.current?.failure, corrupt ? .healthPersistence : .quarantined)
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
            state.advance()
            let response4 = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
            XCTAssertEqual(response4, .started)
            try await eventually { module.module.health.current?.state == .ready }
            XCTAssertEqual(try record(root).attempts, 1)
            let response5 = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
            XCTAssertEqual(response5, .ready)
            await registry.shutdown()
        }
    }

    func testMissingHelperWaitsForConditionAndReadyRegistrationDoesNotResetBudget() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper"), state = ExtractionState()
        let worker = MediaWorker(executable: helper, requiresLifecycle: true)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, uptime: { state.now })
        let registry = ModuleRegistry([module.registration])
        do { try await registry.start(.mediaExtraction); XCTFail("Missing executable") } catch {}
        XCTAssertEqual(module.module.health.current?.state, .degraded)
        try Data("fixture, never executed".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        state.advance()
        let response6 = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(response6, .started)
        try await eventually { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root).attempts, 2)
        await registry.shutdown()
        let response7 = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(response7, .disabled)
    }

    func testProtocolCorruptionAndSaturationAreDifferentFromInputRefusal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (worker, module, registry) = fixture(root) { _, _ in
            .init(termination: .exited(0), exitCode: 0, stdout: "not-json", stderr: "", outputTruncated: false)
        }
        try await registry.start(.mediaExtraction)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.state != .ready }
        await registry.shutdown()
        let plain = MediaWorker(requiresLifecycle: true)
        XCTAssertThrowsError(try plain.decode(.pdf, input: .data(Data())))
    }

    func testExecutablePermissionFailureWaitsForExplicitConditionRecovery() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let (worker, module, registry) = fixture(root, state: state, automatic: true) { _, _ in
            state.called(); throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        try await registry.start(.mediaExtraction)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.state == .degraded && module.module.health.current?.hasLifecycleWork == false }
        state.advance()
        XCTAssertEqual(state.calls, 1)
        let recovery = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
        XCTAssertEqual(recovery, .started)
        try await eventually { module.module.health.current?.state == .ready }
        XCTAssertEqual(state.calls, 1)
        await registry.shutdown()
    }

    func testTwoOwnedChildrenBoundCapacityWithoutSpendingAnotherReservation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ExtractionState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                                 run: { p, _ in
            state.called(); p.onStarted?()
            state.lock.withLock { state.callbacks.append(p.onReaped!) }
            return try self.response(p)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration])
        try await registry.start(.mediaExtraction)
        for _ in 0..<2 { _ = try worker.decode(.pdf, input: .data(Data())) }
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        try await eventually { module.module.health.current?.activeOperations == 2 }
        XCTAssertEqual(module.module.health.current?.state, .ready)
        XCTAssertEqual(try record(root).attempts, 1)
        worker.preventNewWork()
        for callback in state.lock.withLock({ state.callbacks }) { callback() }
        await worker.shutdown()
        await registry.shutdown()
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testDuplicateBindingAndOwnerReleaseNeverCreateAnUnmanagedFallback() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true)
        var first: MediaExtractionModule? = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([first!.registration])
        try await registry.start(.mediaExtraction)
        let duplicate = MediaExtractionModule(worker: worker, healthDirectory: root)
        let response8 = await duplicate.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(response8, .disabled)
        first = nil
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        await registry.shutdown()
    }

    func testRealAttachmentFacadeUsesManagedPoolAndRefusesAfterShutdown() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/media-health-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(requiresLifecycle: true, run: { p, cancelled in
            var p = p; p.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(p, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration])
        try await registry.start(.mediaExtraction)
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 100, height: 100), type: .png)
        let image = try AskAttachmentLoader.load(.image(png, name: "fixture"), worker: worker)
        XCTAssertEqual(image.count, 1)
        let file = root.appendingPathComponent("fixture.png"); try png.write(to: file)
        XCTAssertEqual(try AskAttachmentLoader.load(.file(file), worker: worker).count, 1)
        await registry.shutdown()
        XCTAssertThrowsError(try AskAttachmentLoader.load(.file(file), worker: worker))
    }
}

@Suite("Media extraction health presentation", .exclusiveUIState)
@MainActor
struct MediaExtractionHealthViewTests {
    @Test func unavailableMediaRecoversWithoutExecutingAnAttachment() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("mediaExtraction.json")
            try Data("broken".utf8).write(to: url)
            let clock = ExtractionState()
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                                     run: { _, _ in clock.called(); throw MediaFailure.unavailable })
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration])
            _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.mediaExtraction]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.mediaExtraction)), in: host))
                try UI.snapshot(host, name: "media-extraction-health")
                clock.advance()
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.mediaExtraction.recover" })
                try button.press()
                try await UI.wait { model.health[.mediaExtraction]?.state == .ready }
                #expect(clock.calls == 0)
                #expect(!model.canRecover(.mediaExtraction))
            }
            model.stopObserving()
            await registry.shutdown()
        }
    }
}
