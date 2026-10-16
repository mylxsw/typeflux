import AppKit
import Darwin
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class PlaybackHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double { lock.withLock { value } }
    func advance() { lock.withLock { value += 601 } }
}
@MainActor private final class HealthPlaybackEngine: MediaPlaybackEngine {
    var loads = 0, stops = 0
    var calls: [MediaPlaybackMessage.Kind] = []
    var failLoad = false, failControl = false
    var controlFailure = MediaFailure.unavailable
    func load(_ url: URL) async throws { loads += 1; if failLoad { throw MediaFailure.unreadable } }
    func perform(_ message: MediaPlaybackMessage) async throws -> MediaPlaybackState {
        calls.append(message.kind)
        if failControl { throw controlFailure }
        return .init(phase: message.kind == .play ? .playing : .paused, elapsed: 0, duration: 2)
    }
    func stop() { stops += 1 }
}

@MainActor final class PlaybackModuleTests: XCTestCase {
    private func pool() -> ClipboardPlaybackPool { .init(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true) }
    private func fixture() throws -> (URL, URL) {
        let root = try AskAttachmentFixture.directory(), file = root.appendingPathComponent("private.wav")
        try Data("synthetic input for injected engine".utf8).write(to: file)
        return (root, file)
    }
    private func runner(_ engine: HealthPlaybackEngine) -> ClipboardPlaybackProcess.Runner {
        { request, cancelled in
            let peer = try MediaPlaybackSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
            request.onStarted?()
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await MediaPlaybackServer(engine: engine).serve(socket: peer, input: URL(fileURLWithPath: "/private/synthetic"))
                done.signal()
            }
            while done.wait(timeout: .now() + 0.01) == .timedOut { if cancelled() { peer.stop() } }
            request.onReaped?()
            return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Playback lifecycle did not settle")
    }
    private func rejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected refusal") } catch {}
    }
    private func attempts(_ root: URL) throws -> Int {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("mediaPlayback.json"))).attempts
    }
    func testDefaultClosedAndPersistentBudgetCountsGenerationsNotControls() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await rejected { _ = try await ClipboardPlaybackProcess.open(file) }
        let pool = pool(), engine = HealthPlaybackEngine(), module = PlaybackModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
        XCTAssertEqual(engine.loads, 0)
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: runner(engine))
        _ = try await client.request(.load)
        for _ in 0..<5 { _ = try await client.request(.status) }
        XCTAssertEqual(try attempts(root), 1); XCTAssertEqual(engine.loads, 1)
        await registry.disable(.mediaPlayback); try await registry.start(.mediaPlayback)
        await rejected { _ = try await client.request(.play) }
        XCTAssertEqual(engine.calls.filter { $0 == .play }.count, 0)
        await registry.shutdown(); XCTAssertEqual(pool.activeCount, 0)
        XCTAssertThrowsError(try pool.reserve())
    }
    func testControlledFailureCanFollowEffectWithoutFaultOrReplay() async throws {
        for mode in 0..<3 {
            let loading = mode == 0
            let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let pool = pool(), module = PlaybackModule(pool: pool, healthDirectory: root)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
            let generation = module.module.health.current?.generation
            for _ in 0..<2 {
                let engine = HealthPlaybackEngine(); engine.failLoad = loading
                if mode == 2 { engine.controlFailure = .invalidProtocol }
                let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: runner(engine))
                do {
                    _ = try await client.request(.load)
                    engine.failControl = true
                    _ = try await client.request(.play)
                    XCTFail()
                } catch { XCTAssertTrue(error is ClipboardPlaybackFailure) }
                try await wait { pool.activeCount == 0 }
                XCTAssertEqual(engine.loads, 1); XCTAssertEqual(engine.calls.filter { $0 == .play }.count, loading ? 0 : 1)
            }
            XCTAssertEqual(module.module.health.current?.generation, generation)
            XCTAssertEqual(module.module.health.current?.state, .ready); XCTAssertEqual(try attempts(root), 1)
            await registry.shutdown()
        }
    }
    func testInputSourceAndCallerControlRefusalsDoNotFault() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), engine = HealthPlaybackEngine(), module = PlaybackModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
        await rejected { _ = try await ClipboardPlaybackProcess.open(root.appendingPathComponent("absent.wav"), pool: pool) }
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: runner(engine))
        await rejected { _ = try await client.request(.seek, fraction: .nan) }
        await rejected { _ = try await client.request(.failed) }
        _ = try await client.request(.load)
        XCTAssertEqual(engine.calls, [.load])
        try Data("changed".utf8).write(to: file, options: .atomic)
        await rejected { _ = try await client.request(.play) }
        try await wait { pool.activeCount == 0 }
        XCTAssertEqual(engine.calls, [.load]); XCTAssertEqual(module.module.health.current?.state, .ready)
        XCTAssertEqual(try attempts(root), 1); await registry.shutdown()
    }
    func testProcessProtocolAndPixelFaultsFenceOnlyPlayback() async throws {
        for mode in 0..<9 {
            let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let pool = pool(), clock = PlaybackHealthClock()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let module = PlaybackModule(pool: pool, healthDirectory: root, policy: policy, uptime: { clock.now })
            let other = MediaExtractionModule(worker: MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true), healthDirectory: root)
            let registry = ModuleRegistry([module.registration, other.registration]); _ = await registry.startAll()
            let generation = other.module.health.current?.generation
            await rejected {
                let client = try await ClipboardPlaybackProcess.open(file, video: mode == 8, pool: pool, timeout: 0.1, run: { request, _ in
                    let peer = try MediaPlaybackSocket(owning: dup(try XCTUnwrap(request.ipcDescriptor)))
                    request.onStarted?(); defer { peer.stop(); request.onReaped?() }
                    let input = try peer.receive(deadline: .now.advanced(by: .seconds(2)))
                    if mode == 0 { throw CocoaError(.fileReadUnknown) }
                    if mode <= 3 { return .init(termination: mode == 1 ? .timedOut : mode == 2 ? .exited(3) : .exited(0), exitCode: 3, stdout: "", stderr: "", outputTruncated: mode == 3) }
                    if mode == 4 { return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false) }
                    var state = MediaPlaybackState(phase: .paused, elapsed: 0, duration: 2)
                    if mode == 8 { state.video = true; state.frame = .init(width: 1, height: 1, time: 0) }
                    var reply = MediaPlaybackMessage(id: mode == 5 ? UUID() : input.id, sequence: mode == 6 ? 99 : input.sequence, kind: .reply, state: state)
                    if mode == 7 {
                        reply.kind = .failed
                        let data = try JSONEncoder().encode(reply); var size = UInt32(data.count).bigEndian
                        _ = withUnsafeBytes(of: &size) { Darwin.write(peer.descriptor, $0.baseAddress, $0.count) }
                        _ = data.withUnsafeBytes { Darwin.write(peer.descriptor, $0.baseAddress, $0.count) }
                    } else { try peer.send(reply, deadline: .now.advanced(by: .seconds(2))) }
                    return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
                })
                _ = try await client.request(.load)
            }
            try await wait { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
            XCTAssertEqual(other.module.health.current?.generation, generation); XCTAssertEqual(other.module.health.current?.state, .ready)
            clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }
            XCTAssertEqual(pool.activeCount, 0); XCTAssertEqual(try attempts(root), 2); await registry.shutdown()
        }
    }
    func testLaunchConfigurationAndCorruptHealthRequireExplicitRecovery() async throws {
        for code in [EACCES, EPERM, ENOENT, ENOEXEC] {
            let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let pool = pool(), clock = PlaybackHealthClock(), module = PlaybackModule(pool: pool, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
            await rejected {
                let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) })
                _ = try await client.request(.load)
            }
            try await wait { module.module.health.current?.state == .degraded && module.module.health.current?.hasLifecycleWork == false }
            clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: false)
            XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }; await registry.shutdown()
        }
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mediaPlayback.json"); try Data("broken".utf8).write(to: file)
        let clock = PlaybackHealthClock(), module = PlaybackModule(pool: pool(), healthDirectory: root, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration]); let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        clock.advance(); let result = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(result, .started); try await wait { module.module.health.current?.state == .ready }; await registry.shutdown()
        let missing = PlaybackModule(pool: ClipboardPlaybackPool(executable: root.appendingPathComponent("absent"), requiresLifecycle: true), healthDirectory: root.appendingPathComponent("missing"))
        await rejected { try await missing.module.start() }; await missing.module.shutdown()
    }
    func testManagedRetirementKeepsHostChildPixelAndOpeningOwnership() async throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(); var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = PlaybackModule(pool: pool, healthDirectory: root, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
        let budget = AskToolPixelBudget(limit: 8)
        let (first, a) = try pool.reserve(), (second, b) = try pool.reserve()
        a.directory = root.appendingPathComponent("owned"); try FileManager.default.createDirectory(at: a.directory!, withIntermediateDirectories: false)
        a.started(); b.started()
        let host = ClipboardPlaybackRetirement(a, opening: true), child = ClipboardPlaybackRetirement(b)
        try host.beginRequest()
        try pool.retainPixels(first, reservation: budget.acquire(bytes: 8))
        XCTAssertThrowsError(try pool.retainPixels(first, reservation: budget.acquire(bytes: 1)))
        host.processReturned(); a.reaped(); child.processReturned()
        await registry.disable(.mediaPlayback)
        XCTAssertEqual(pool.activeCount, 2); XCTAssertThrowsError(try pool.reserve())
        XCTAssertThrowsError(try budget.acquire(bytes: 1)); XCTAssertTrue(FileManager.default.fileExists(atPath: a.directory!.path))
        await rejected { try await registry.start(.mediaPlayback) }
        host.endRequest(); XCTAssertEqual(pool.activeCount, 2)
        host.endRequest(); try await wait { pool.activeCount == 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory!.path))
        b.reaped(); try await wait { pool.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        XCTAssertNoThrow(try budget.acquire(bytes: 8))
        try await registry.start(.mediaPlayback)
        XCTAssertFalse(pool.permits(first)); XCTAssertFalse(pool.permits(second))
        await registry.shutdown()
    }
    func testAutomaticRecoveryAndScopedConsumerNeverReloadOrReplay() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), engine = HealthPlaybackEngine(), clock = PlaybackHealthClock()
        let module = PlaybackModule(pool: pool, healthDirectory: root, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
        let scope = AskImagePresentationScope(), access = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let run = runner(engine)
        let model = ClipboardAudioPlayback(open: { try await ClipboardPlaybackProcess.open($0, pool: pool, run: run) })
        model.load(file, access: access); try await wait { model.isLoaded }
        let (id, lease) = try pool.reserve(); pool.failed(id); lease.returned()
        try await wait { module.module.health.current?.state == .recovering }; clock.advance()
        try await wait { module.module.health.current?.state == .ready && model.failed }
        model.load(file, access: access); model.toggle(); model.seek(to: 0.5)
        XCTAssertEqual(engine.loads, 1); XCTAssertFalse(model.isLoaded); XCTAssertNil(model.image)
        XCTAssertFalse(engine.calls.contains(.play))
        scope.invalidate(); model.load(file, access: access); XCTAssertEqual(engine.loads, 1)
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        model.load(file, access: fresh); try await wait { model.isLoaded }; XCTAssertEqual(engine.loads, 2)
        model.stop(); await registry.shutdown()
    }
    func testManagedNativeVideoAndRecordingShareCapacityAndRetireWithoutPlayback() async throws {
        let (root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("silent.mov"); try await ClipboardVideoPlaybackTests.movie(file)
        let pool = ClipboardPlaybackPool(requiresLifecycle: true), module = PlaybackModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPlayback)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/playback-health-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clients: [ClipboardPlaybackProcess] = []
        for recording in [false, true] {
            let client = try await ClipboardPlaybackProcess.open(file, video: true, recording: recording, pool: pool, run: { request, _ in
                var request = request; request.timeout = 10
                request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
                // EOF allows LLVM profile completion; production cancellation remains unchanged.
                return try ManagedProcess().runBlocking(request, isCancelled: { false })
            })
            clients.append(client)
            let frame = try await client.request(.load)
            XCTAssertEqual(frame.phase, .paused); XCTAssertEqual(frame.frame?.width, 32); XCTAssertEqual(frame.frame?.height, 64)
            XCTAssertEqual(frame.pixels?.count, 32 * 64 * 4)
            _ = try await client.request(.seekPaused, fraction: 0.5)
        }
        XCTAssertEqual(pool.activeCount, 2); XCTAssertEqual(try attempts(root), 1)
        do {
            _ = try await clients[1].request(.playRange, fraction: nil, range: .init(start: 0, end: 100))
            XCTFail("Out-of-duration range must be refused")
        } catch { XCTAssertTrue(error is ClipboardPlaybackFailure) }
        try await wait { pool.activeCount == 1 }
        XCTAssertEqual(module.module.health.current?.state, .ready)
        await registry.disable(.mediaPlayback); XCTAssertEqual(pool.activeCount, 0)
        try await registry.start(.mediaPlayback)
        for client in clients { await rejected { _ = try await client.request(.play) } }
        XCTAssertEqual(pool.activeCount, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await registry.shutdown()
    }

    func testDuplicateAdapterAndOwnerReleaseDoNotExpandCapacity() async throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pool = pool(), engine = HealthPlaybackEngine()
        var module: PlaybackModule? = PlaybackModule(pool: pool, healthDirectory: root)
        let registry = ModuleRegistry([module!.registration]); try await registry.start(.mediaPlayback)
        let client = try await ClipboardPlaybackProcess.open(file, pool: pool, run: runner(engine)); _ = try await client.request(.load)
        var duplicate: PlaybackModule? = PlaybackModule(pool: pool, healthDirectory: root.appendingPathComponent("other"))
        await rejected { try await duplicate!.module.start() }; duplicate = nil
        _ = try await client.request(.status)
        module = nil; try await wait { pool.activeCount == 0 }
        await rejected { _ = try await client.request(.play) }; XCTAssertThrowsError(try pool.reserve())
        await registry.shutdown()
    }
}

@Suite("Media playback health presentation", .exclusiveUIState)
@MainActor struct PlaybackHealthViewTests {
    @Test func recoveryRestoresAdmissionWithoutLoadingMedia() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("mediaPlayback.json"))
            let clock = PlaybackHealthClock()
            let pool = ClipboardPlaybackPool(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true)
            let module = PlaybackModule(pool: pool, healthDirectory: root, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.mediaPlayback]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.mediaPlayback"), in: host))
                try UI.snapshot(host, name: "playback-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.mediaPlayback.recover" })
                clock.advance(); try button.press()
                try await UI.wait { model.health[.mediaPlayback]?.state == .ready }
                #expect(pool.activeCount == 0)
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
