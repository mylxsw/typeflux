import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class FrameRegistrationModuleTests: XCTestCase {
    private func record(_ root: URL, _ name: String) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Health did not settle")
    }
    private func refusal(_ request: ManagedProcess.Request) throws -> ManagedProcess.Result {
        let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(request.stdin))
        return .init(termination: .exited(0), exitCode: 0,
            stdout: String(decoding: try JSONEncoder().encode(MediaResponse(id: input.id, failure: .unreadable)), as: UTF8.self),
            stderr: "", outputTruncated: false)
    }

    func testProductionDefaultRefusesBeforeBindingAndStitchFallbackStillValidates() async throws {
        let page = ScrollCaptureFixtures.page(width: 200, height: 900)
        let first = page.frame(offset: 0, scrollingHeight: 400), next = page.frame(offset: 120, scrollingHeight: 400)
        let detector = VisionScrollOffsetEstimator()
        do { _ = try await detector.verticalShifts(from: first.image, to: next.image); XCTFail() } catch {}
        XCTAssertEqual(MediaWorker.frameRegistration.activeCount, 0)
        var stitcher = DirectionalScrollStitcher()
        _ = try await stitcher.addPreparingOffsets(first, registration: detector)
        let outcome = try await stitcher.addPreparingOffsets(next, registration: detector)
        XCTAssertEqual(outcome, .appended(rows: 120, suspicious: false))
        XCTAssertEqual(stitcher.height, 520)
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RegistrationHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            return try self.refusal(p)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .frameRegistration, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.frameRegistration)
        let image = ScrollCaptureFixtures.solid(width: 200, height: 200, gray: 255)
        let detector = VisionScrollOffsetEstimator(worker: worker)
        let first = Task { try await detector.verticalShifts(from: image, to: image) }
        let second = Task { try await detector.verticalShifts(from: image, to: image) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.frameRegistration)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await detector.verticalShifts(from: image, to: image); XCTFail() } catch {}
        do { try await registry.start(.frameRegistration); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.frameRegistration)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await detector.verticalShifts(from: image, to: image); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let registration = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, policy: policy)
        let b = MediaExtractionModule(worker: registration, healthDirectory: root, domain: .frameRegistration, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try registration.decode(.image, input: .data(Data())))
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try registration.decode(.image, input: .data(Data())))
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.decode(.image, input: .data(Data()))) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 1)
        XCTAssertEqual(try record(root, "frameRegistration").attempts, 1)
        await registry.disable(.frameRegistration)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 0)
        XCTAssertEqual(try record(root, "frameRegistration").attempts, 1)
        XCTAssertThrowsError(try registration.decode(.image, input: .data(Data())))
    }

    func testCorruptionDoesNotBlockOtherDomainAndExplicitResetDoesNotRunRequests() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("frameRegistration.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = RegistrationHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .frameRegistration, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "frameRegistration").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedRefusalAndMalformedShiftHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RegistrationHealthState()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { p, _ in
            XCTAssertEqual(p.timeout, 3)
            let count = state.called()
            if count == 1 { return try self.refusal(p) }
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id)
            response.registration = .init(translationY: 1000)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .frameRegistration, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.frameRegistration)
        let image = ScrollCaptureFixtures.solid(width: 200, height: 200, gray: 255)
        for call in 0..<2 {
            do { _ = try await VisionScrollOffsetEstimator(worker: worker).verticalShifts(from: image, to: image); XCTFail("Invalid input/output accepted") } catch {}
            if call == 0 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 2)
        await registry.shutdown()
    }

    func testManagedRealCandidatesFallbackUndoAndRecoveryNeverReplayFrames() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/registration-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = RegistrationHealthState()
        let worker = MediaWorker(timeout: 3, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .frameRegistration)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.frameRegistration)
        let page = ScrollCaptureFixtures.page(width: 200, height: 1000)
        let detector = VisionScrollOffsetEstimator(worker: worker)
        for horizontal in [false, true] {
            func frame(_ offset: Int) -> ScrollFrame {
                let image = page.frameImage(offset: offset, scrollingHeight: 400)
                return ScrollFrame(image: horizontal ? ScrollCaptureAxis.horizontal.orient(image)! : image)!
            }
            var stitcher = DirectionalScrollStitcher()
            _ = try await stitcher.addPreparingOffsets(frame(0), registration: detector)
            let joined = try await stitcher.addPreparingOffsets(frame(120), registration: detector)
            XCTAssertEqual(joined, .appended(rows: 120, suspicious: false))
            XCTAssertEqual(stitcher.axis, horizontal ? .horizontal : .vertical)
            let count = state.calls
            await registry.disable(.frameRegistration)
            let fallback = try await stitcher.addPreparingOffsets(frame(240), registration: detector)
            XCTAssertEqual(fallback, .appended(rows: 120, suspicious: false))
            XCTAssertEqual(state.calls, count)
            XCTAssertTrue(stitcher.removeLastSegment())
            try await registry.start(.frameRegistration)
            XCTAssertEqual(state.calls, count, "Readiness must not capture, scroll, drain or export again")
            let next = try await stitcher.addPreparingOffsets(frame(240), registration: detector)
            XCTAssertEqual(next, .appended(rows: 120, suspicious: false))
            XCTAssertNotNil(stitcher.makeImage())
        }
        XCTAssertEqual(try record(root, "frameRegistration").attempts, 1, "Cleanly stopped generations reset; frames never reserve")
        await registry.shutdown()
    }

}

private final class RegistrationHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Frame registration health presentation", .exclusiveUIState)
@MainActor struct FrameRegistrationHealthViewTests {
    @Test func independentRegistrationRecoveryDoesNotDecode() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("frameRegistration.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not decode"); throw MediaFailure.unavailable })
            let clock = RegistrationHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .frameRegistration, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.frameRegistration]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.frameRegistration"), in: host))
                try UI.snapshot(host, name: "frame-registration-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.frameRegistration.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.frameRegistration]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
