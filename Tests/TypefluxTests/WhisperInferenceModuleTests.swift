import AppKit
import Darwin
import SwiftUI
import Testing
import XCTest
import TypefluxInferenceProtocol
import TypefluxInferenceRuntime
@testable import Typeflux

private final class InferenceHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double { lock.withLock { value } }
    func advance() { lock.withLock { value += 601 } }
}

private final class ManagedInferenceFixture: @unchecked Sendable {
    let engine = InferenceFixtureEngine()
    private let lock = NSLock()
    private var count = 0, ended = false
    private var reapAction: (@Sendable () -> Void)?
    let delayedReap: Bool
    init(delayedReap: Bool = false) { self.delayedReap = delayedReap }
    var launches: Int { lock.withLock { count } }
    var finished: Bool { lock.withLock { ended } }
    func reap() { lock.withLock { reapAction }?() }
    func run(_ request: ManagedProcess.Request) async throws -> ManagedProcess.Result {
        let peer = try InferenceSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
        lock.withLock { count += 1; reapAction = request.onReaped }
        request.onStarted?()
        await InferenceServer(engine: engine).serve(socket: peer)
        if !delayedReap { request.onReaped?() }
        lock.withLock { ended = true }
        return .init(termination: Task.isCancelled ? .cancelled : .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
    }
}

private final class ManagedInferenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var entered: Bool { lock.withLock { continuation != nil } }
    func wait() async { await withCheckedContinuation { c in lock.withLock { continuation = c } } }
    func release() { let c = lock.withLock { let c = continuation; continuation = nil; return c }; c?.resume() }
}

private struct RefusingInferenceEngine: InferenceEngine {
    let preparing: Bool
    func prepare(_ configuration: InferenceConfiguration) async throws -> String? {
        if preparing { throw InferenceFailure.engineFailed }
        return nil
    }
    func transcribe(_ request: InferenceMessage, progress: @escaping @Sendable (String) -> Bool) async throws -> String {
        throw InferenceFailure.engineFailed
    }
}

@MainActor final class WhisperInferenceModuleTests: XCTestCase {
    private let configuration = InferenceConfiguration(model: "fixture", modelFolder: "/private-synthetic-model")
    private func pool() -> WhisperWorkerPool { .init(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true) }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Inference lifecycle did not settle")
    }
    private func prepare(_ client: WhisperWorkerClient) async throws {
        var request = InferenceMessage(kind: .prepare); request.configuration = configuration
        _ = try await client.request(request)
    }
    private func record(_ root: URL) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("whisperInference.json")))
    }
    private func rejected(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected refusal") } catch {}
    }

    func testDefaultClosedReadinessAndRecoveryNeverPrepareOrTranscribe() async throws {
        XCTAssertThrowsError(try WhisperWorkerClient(configuration: configuration))
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), fixture = ManagedInferenceFixture()
        let module = WhisperInferenceModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
        XCTAssertEqual(fixture.launches, 0)
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        try await prepare(client)
        for _ in 0..<3 { _ = try await client.request(.init(kind: .probe)) }
        XCTAssertEqual(try record(root).attempts, 1)
        XCTAssertEqual(fixture.engine.prepares, 1)
        await registry.disable(.whisperInference)
        XCTAssertFalse(client.canReuse)
        try await registry.start(.whisperInference)
        await rejected { _ = try await client.request(.init(kind: .probe)) }
        XCTAssertEqual(fixture.launches, 1); XCTAssertEqual(fixture.engine.prepares, 1)
        let newer = ManagedInferenceFixture()
        let fresh = try WhisperWorkerClient(configuration: configuration, pool: pool, run: newer.run)
        try await prepare(fresh)
        XCTAssertEqual(newer.launches, 1)
        await registry.shutdown()
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertThrowsError(try WhisperWorkerClient(configuration: configuration, pool: pool, run: newer.run))
        try pool.checkUnused(URL(fileURLWithPath: "/private-synthetic-model"))
    }

    func testControlledPreparationAndTranscriptionFailuresAreNotPoolCrashes() async throws {
        for preparing in [true, false] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let pool = pool(), module = WhisperInferenceModule(pool: pool, healthDirectory: root)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
            let generation = module.module.health.current?.generation
            for _ in 0..<2 {
                let client = try WhisperWorkerClient(configuration: configuration, pool: pool) { request in
                    let peer = try InferenceSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
                    request.onStarted?()
                    await InferenceServer(engine: RefusingInferenceEngine(preparing: preparing)).serve(socket: peer)
                    request.onReaped?()
                    return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
                }
                do {
                    try await prepare(client)
                    let audio = root.appendingPathComponent(UUID().uuidString + ".wav"); try Data("synthetic".utf8).write(to: audio)
                    _ = try await client.transcribe(audio: audio, lowEnergy: false, prompt: nil, language: nil) { _ in }
                    XCTFail()
                } catch { XCTAssertEqual(error as? InferenceFailure, .engineFailed) }
                try await wait { pool.activeCount == 0 }
            }
            XCTAssertEqual(module.module.health.current?.generation, generation)
            XCTAssertEqual(module.module.health.current?.state, .ready)
            XCTAssertEqual(try record(root).attempts, 1)
            await registry.shutdown()
        }
    }

    func testSourceAndHostRequestRefusalsDoNotFaultOrConsumePersistentAttempts() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), fixture = ManagedInferenceFixture(), module = WhisperInferenceModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        await rejected { _ = try await client.request(.init(kind: .prepare)) }
        await rejected { _ = try await client.transcribe(audio: root.appendingPathComponent("absent.wav"), lowEnergy: false, prompt: nil, language: nil) { _ in } }
        let audio = root.appendingPathComponent("synthetic.wav"); try Data("synthetic".utf8).write(to: audio)
        await rejected { _ = try await client.transcribe(audio: audio, lowEnergy: false, prompt: String(repeating: "x", count: 16385), language: nil) { _ in } }
        try await prepare(client)
        XCTAssertNil(fixture.engine.lastRequest)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        XCTAssertEqual(try record(root).attempts, 1)
        await registry.shutdown()
    }

    func testProtocolAndProcessFaultsFenceOnlyInferenceWithoutReplaying() async throws {
        for mode in 0..<9 {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let clock = InferenceHealthClock(), pool = pool()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let module = WhisperInferenceModule(pool: pool, healthDirectory: root, policy: policy, uptime: { clock.now })
            let media = MediaExtractionModule(worker: MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true), healthDirectory: root)
            let registry = ModuleRegistry([module.registration, media.registration]); _ = await registry.startAll()
            let mediaGeneration = media.module.health.current?.generation
            let client = try WhisperWorkerClient(configuration: configuration, pool: pool, timeout: 0.2) { request in
                let peer = try InferenceSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
                request.onStarted?(); defer { peer.stop(); request.onReaped?() }
                let incoming = try peer.receive(deadline: .now.advanced(by: .seconds(1)))
                if mode < 2 { return .init(termination: mode == 0 ? .timedOut : .exited(7), exitCode: 7, stdout: "", stderr: "", outputTruncated: false) }
                if mode == 2 { throw CocoaError(.fileReadUnknown) }
                if mode == 3 { return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: true) }
                if mode == 4 { return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false) }
                var reply = InferenceMessage(id: mode == 5 ? UUID() : incoming.id, kind: mode == 8 ? .failed : .ready)
                if mode == 6 { reply.sequence = 2 }
                if mode == 7 { reply.configuration = .init(model: "invalid-response") }
                if mode == 8 { reply.text = "invalid failed payload" }
                try peer.send(reply, deadline: .now.advanced(by: .seconds(1)))
                _ = try? peer.receive(deadline: .now.advanced(by: .seconds(1)))
                return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
            }
            await rejected { _ = try await client.request(.init(kind: .probe)) }
            try await wait { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
            XCTAssertEqual(media.module.health.current?.generation, mediaGeneration)
            XCTAssertEqual(media.module.health.current?.state, .ready)
            XCTAssertThrowsError(try pool.reserve(paths: [], stop: {}))
            clock.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertFalse(client.canReuse); XCTAssertEqual(pool.activeCount, 0)
            XCTAssertEqual(try record(root).attempts, 2)
            await registry.shutdown()
        }
    }

    func testLaunchConfigurationWaitsForExplicitCapabilityRecovery() async throws {
        for code in [EACCES, EPERM, ENOENT, ENOEXEC] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let clock = InferenceHealthClock(), pool = pool(), module = WhisperInferenceModule(pool: pool, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
            let client = try WhisperWorkerClient(configuration: configuration, pool: pool) { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            await rejected { _ = try await client.request(.init(kind: .probe)) }
            try await wait { module.module.health.current?.state == .degraded && module.module.health.current?.hasLifecycleWork == false }
            clock.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertEqual(pool.activeCount, 0); await registry.shutdown()
        }
    }

    func testAutomaticRecoveryRestoresOnlyAdmissionWithoutReplayingPreparation() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = InferenceHealthClock(), pool = pool(), fixture = ManagedInferenceFixture()
        let module = WhisperInferenceModule(pool: pool, healthDirectory: root, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
        let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        try await prepare(client)
        // A malformed host-to-child operation is deliberately sent through the
        // fixture transport; it closes without a terminal reply, never native work.
        await rejected { _ = try await client.request(.init(kind: .ready)) }
        try await wait { module.module.health.current?.state == .recovering }
        clock.advance()
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(fixture.launches, 1); XCTAssertEqual(fixture.engine.prepares, 1)
        XCTAssertNil(fixture.engine.lastRequest); XCTAssertFalse(client.canReuse)
        XCTAssertEqual(pool.activeCount, 0); XCTAssertEqual(try record(root).attempts, 2)
        await registry.shutdown()
    }

    func testCorruptionMissingHelperAndDuplicateBindingStayFailClosed() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = InferenceHealthClock(), pool = pool()
        let file = root.appendingPathComponent("whisperInference.json"); try Data("broken".utf8).write(to: file)
        let module = WhisperInferenceModule(pool: pool, healthDirectory: root, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration]); let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        clock.advance(); let response = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(response, .started); try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root).attempts, 1)
        let fixture = ManagedInferenceFixture(), client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
        try await prepare(client)
        var duplicate: WhisperInferenceModule? = WhisperInferenceModule(pool: pool, healthDirectory: root.appendingPathComponent("other"))
        await rejected { try await duplicate!.module.start() }; duplicate = nil
        XCTAssertTrue(client.canReuse)
        await registry.shutdown()
        let missing = WhisperWorkerPool(executable: root.appendingPathComponent("missing"), requiresLifecycle: true)
        let unavailable = WhisperInferenceModule(pool: missing, healthDirectory: root.appendingPathComponent("missing-health"))
        let missingFailures = await ModuleRegistry([unavailable.registration]).startAll(); XCTAssertEqual(missingFailures.count, 1)
        await unavailable.module.shutdown()
    }

    func testDisableAndLateConsumerRetainPoolPathsUntilHostAndChildRetire() async throws {
        for delayedReap in [false, true] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let pool = pool(), fixture = ManagedInferenceFixture(delayedReap: delayedReap), gate = ManagedInferenceGate()
            var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
            let module = WhisperInferenceModule(pool: pool, healthDirectory: root, policy: policy)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.whisperInference)
            let client = try WhisperWorkerClient(configuration: configuration, pool: pool, run: fixture.run)
            try await prepare(client)
            let audio = root.appendingPathComponent("fixture.wav"); try Data("synthetic".utf8).write(to: audio)
            let action = Task { try await client.transcribe(audio: audio, lowEnergy: false, prompt: nil, language: nil) { _ in await gate.wait() } }
            try await wait { gate.entered }
            let copy = try XCTUnwrap(fixture.engine.lastRequest?.audioPath)
            await registry.disable(.whisperInference)
            try await wait { fixture.finished }
            XCTAssertEqual(pool.activeCount, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: copy))
            XCTAssertThrowsError(try pool.checkUnused(URL(fileURLWithPath: "/private-synthetic-model")))
            await rejected { try await registry.start(.whisperInference) }
            gate.release(); await rejected { _ = try await action.value }
            if delayedReap { XCTAssertEqual(pool.activeCount, 1); fixture.reap() }
            try await wait { pool.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
            try await registry.start(.whisperInference)
            XCTAssertEqual(fixture.launches, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
            XCTAssertFalse(client.canReuse); await registry.shutdown()
        }
    }

    func testFacadeNeedsANewExplicitInstanceAfterRecoveryAndOwnerReleaseCancels() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), fixture = ManagedInferenceFixture()
        var module: WhisperInferenceModule? = WhisperInferenceModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module!.registration]); try await registry.start(.whisperInference)
        let old = WhisperKitTranscriber(modelName: "fixture", pool: pool) { try WhisperWorkerClient(configuration: $0, pool: $1, run: fixture.run) }
        XCTAssertTrue(old.isAvailableForReuse); try await old.prepare()
        await registry.disable(.whisperInference); try await registry.start(.whisperInference)
        XCTAssertFalse(old.isAvailableForReuse); XCTAssertEqual(fixture.launches, 1)
        await rejected { try await old.prepare() }
        let audio = root.appendingPathComponent("fixture.wav"); try Data("synthetic".utf8).write(to: audio)
        await rejected { _ = try await old.transcribe(audioFile: .init(fileURL: audio, duration: 1)) }
        XCTAssertFalse(old.isAvailableForReuse)
        let freshFixture = ManagedInferenceFixture()
        let fresh = WhisperKitTranscriber(modelName: "fixture", pool: pool) { try WhisperWorkerClient(configuration: $0, pool: $1, run: freshFixture.run) }
        let text = try await fresh.transcribe(audioFile: .init(fileURL: audio, duration: 1))
        XCTAssertEqual(text, "final"); XCTAssertEqual(freshFixture.engine.prepares, 1)
        module = nil
        try await wait { pool.activeCount == 0 }
        XCTAssertFalse(fresh.isAvailableForReuse)
        XCTAssertThrowsError(try pool.reserve(paths: [], stop: {}))
        await registry.shutdown(); old.stop(); fresh.stop()
    }
}

@Suite("Whisper inference health presentation", .exclusiveUIState)
@MainActor struct WhisperInferenceHealthViewTests {
    @Test func recoveryRestoresAdmissionWithoutLoadingAModel() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("whisperInference.json"))
            let clock = InferenceHealthClock()
            let pool = WhisperWorkerPool(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true)
            let module = WhisperInferenceModule(pool: pool, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.whisperInference]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.whisperInference)), in: host))
                try UI.snapshot(host, name: "whisper-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.whisperInference.recover" })
                clock.advance(); try button.press()
                try await UI.wait { model.health[.whisperInference]?.state == .ready }
                #expect(pool.activeCount == 0)
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
