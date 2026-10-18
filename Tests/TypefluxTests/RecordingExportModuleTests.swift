import AppKit
import Darwin
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

private final class ExportHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, time = 0.0
    private var reapers: [@Sendable () -> Void] = []
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.withLock { count } }
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    func called(_ request: ManagedProcess.Request? = nil) {
        request?.onStarted?()
        lock.withLock { count += 1; if let reap = request?.onReaped { reapers.append(reap) } }
    }
    func reap() { let values = lock.withLock { let result = reapers; reapers = []; return result }; values.forEach { $0() } }
}

@MainActor final class RecordingExportModuleTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let root: URL, source: URL, destination: URL
        init() throws {
            root = try AskAttachmentFixture.directory()
            source = root.appendingPathComponent("source.mov"); destination = root.appendingPathComponent("result.mp4")
            try Data("private original".utf8).write(to: source)
        }
        func jobs() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".encoding-") } }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    nonisolated private static func result(_ stdout: String, termination: ManagedProcess.Termination = .exited(0), truncated: Bool = false) -> ManagedProcess.Result {
        .init(termination: termination, exitCode: 0, stdout: stdout, stderr: "", outputTruncated: truncated)
    }
    nonisolated private static func reply(_ p: ManagedProcess.Request, failed: Bool = false) throws -> ManagedProcess.Result {
        let input = try JSONDecoder().decode(MediaRecordingExport.self, from: XCTUnwrap(p.stdin))
        let data = Data([0, 0, 0, 20] + Array("ftypmp42private".utf8))
        let fd = openat(p.directoryDescriptor, input.outputName, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw MediaFailure.unavailable }; defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        let event = MediaRecordingExportEvent(id: input.id, sequence: 1, kind: failed ? .failed : .completed,
            progress: failed ? 0.4 : 1, bytes: failed ? nil : data.count)
        return result(String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n")
    }
    private func encode(_ f: Fixture, worker: MediaWorker) async throws {
        try await ScreenRecordingEncoder(worker: worker).export(source: f.source, destination: f.destination,
            format: .mp4, trim: .init(start: 0, end: 1), progress: { _ in })
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Export health did not settle")
    }
    private func record(_ root: URL) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("recordingExport.json")))
    }
    private func assertRetained(_ f: Fixture) throws {
        let job = try XCTUnwrap(f.jobs().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("input.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
    }

    func testDefaultExporterRefusesBeforeDIWithoutProducingAttempt() async throws {
        let f = try Fixture(); defer { f.clean() }
        do { try await ScreenRecordingExporter().export(source: f.source, destination: f.destination, format: .mp4,
            trim: .init(start: 0, end: 1), progress: { _ in }); XCTFail() } catch {}
        XCTAssertTrue(try f.jobs().isEmpty); XCTAssertEqual(MediaWorker.recordingExport.activeCount, 0)
        XCTAssertEqual(try Data(contentsOf: f.source), Data("private original".utf8))
    }

    func testValidFailedTerminalKeepsPartialBytesAndDoesNotSpendPerRequestBudget() async throws {
        let f = try Fixture(); defer { f.clean() }
        let state = ExportHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 600, requiresLifecycle: true, run: { p, _ in
            state.called(); XCTAssertEqual(p.timeout, 600); return try Self.reply(p, failed: true)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
        let generation = module.module.health.current?.generation
        for _ in 0..<3 {
            do { try await encode(f, worker: worker); XCTFail() } catch { XCTAssertTrue(error is ScreenRecordingEncoder.Failure) }
            XCTAssertEqual(module.module.health.current?.state, .ready)
        }
        XCTAssertEqual(try f.jobs().count, 3); XCTAssertEqual(try record(f.root).attempts, 1)
        XCTAssertEqual(module.module.health.current?.generation, generation)
        for job in try f.jobs() { XCTAssertTrue(FileManager.default.fileExists(atPath: job.appendingPathComponent("output.mp4").path)) }
        await registry.disable(.recordingExport); try await registry.start(.recordingExport)
        XCTAssertEqual(state.calls, 3); try assertRetained(f)
        await registry.shutdown()
    }

    func testProcessAndSuccessfulOutputFaultsFenceHealthWithoutDeletingCandidates() async throws {
        for mode in 0..<10 {
            let f = try Fixture(); defer { f.clean() }
            let state = ExportHealthState()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
                state.called(); let valid = try Self.reply(p)
                switch mode {
                case 0: return Self.result("", termination: .timedOut)
                case 1: return Self.result(valid.stdout, termination: .exited(2))
                case 2: return Self.result("not-json\n")
                case 3: return Self.result(valid.stdout + "trailing")
                case 4: return Self.result(valid.stdout, truncated: true)
                case 5: _ = unlinkat(p.directoryDescriptor, "output.mp4", 0)
                case 6:
                    let fd = openat(p.directoryDescriptor, "output.mp4", O_WRONLY); _ = ftruncate(fd, 1); close(fd)
                case 7:
                    let fd = openat(p.directoryDescriptor, "output.mp4", O_WRONLY); let bytes = [UInt8](repeating: 0, count: 12)
                    _ = write(fd, bytes, bytes.count); close(fd)
                case 8:
                    _ = unlinkat(p.directoryDescriptor, "output.mp4", 0)
                    _ = symlinkat("input.mov", p.directoryDescriptor, "output.mp4")
                default: throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
                }
                return valid
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport, policy: policy)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
            do { try await encode(f, worker: worker); XCTFail() } catch { XCTAssertTrue(error is ScreenRecordingEncoder.Failure) }
            try await wait { module.module.health.current?.state == .recovering && module.module.health.current?.hasLifecycleWork == false }
            try assertRetained(f); XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
            do { try await encode(f, worker: worker); XCTFail() } catch {}
            XCTAssertEqual(state.calls, 1)
            await registry.shutdown(); try assertRetained(f)
        }
    }

    func testLaunchConfigurationWaitsAndIndependentTimelineKeepsItsGeneration() async throws {
        for code in [EACCES, EPERM, ENOENT, ENOEXEC] {
            let f = try Fixture(); defer { f.clean() }
            let state = ExportHealthState()
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in
                state.called(); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            })
            let other = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true)
            let a = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport, uptime: { state.now })
            let b = MediaExtractionModule(worker: other, healthDirectory: f.root, domain: .recordingTimeline)
            let registry = ModuleRegistry([a.registration, b.registration]); _ = await registry.startAll()
            let old = b.module.health.current?.generation
            do { try await encode(f, worker: worker); XCTFail() } catch {}
            try await wait { a.module.health.current?.state == .degraded && a.module.health.current?.hasLifecycleWork == false }
            XCTAssertEqual(b.module.health.current?.generation, old); XCTAssertEqual(b.module.health.current?.state, .ready)
            state.advance()
            let reset = await a.module.supervisor.requestRecovery(resetPersistentBudget: false); XCTAssertEqual(reset, .started)
            try await wait { a.module.health.current?.state == .ready }
            XCTAssertEqual(state.calls, 1); XCTAssertEqual(try record(f.root).attempts, 2)
            try assertRetained(f); await registry.shutdown()
        }
    }

    func testCorruptPersistentRecordNeedsExplicitResetWithoutEncoderReplay() async throws {
        let f = try Fixture(); defer { f.clean() }
        let url = f.root.appendingPathComponent("recordingExport.json")
        try Data("private corruption".utf8).write(to: url)
        let state = ExportHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in
            XCTFail("Reset replayed export"); throw MediaFailure.unavailable
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport, uptime: { state.now })
        let registry = ModuleRegistry([module.registration]); let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), Data("private corruption".utf8))
        do { try await encode(f, worker: worker); XCTFail() } catch {}
        state.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true); XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertTrue(try f.jobs().isEmpty); XCTAssertEqual(try record(f.root).attempts, 1)
        await registry.shutdown()
    }

    func testSourceDestinationAndRetentionRefusalsDoNotBlameDecoder() async throws {
        for mode in 0..<4 {
            let f = try Fixture(); defer { f.clean() }
            let state = ExportHealthState()
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
                state.called(); let result = try Self.reply(p)
                if mode == 0 { try Data([9]).write(to: f.source) }
                if mode == 1 { try Data([8]).write(to: f.destination) }
                return result
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
            if mode == 2 { for i in 0..<4 { try FileManager.default.createDirectory(at: f.root.appendingPathComponent(".encoding-\(i)"), withIntermediateDirectories: false) } }
            if mode == 3 { try FileManager.default.removeItem(at: f.source) }
            do { try await encode(f, worker: worker); XCTFail() } catch {}
            XCTAssertEqual(module.module.health.current?.state, .ready)
            XCTAssertEqual(state.calls, mode < 2 ? 1 : 0)
            if mode < 2 { try assertRetained(f) }
            await registry.shutdown()
        }
    }

    func testCancelledHostAndUncollectedChildrenKeepCapacityAndSessionOwnership() async throws {
        let a = try Fixture(), b = try Fixture(), c = try Fixture(); defer { a.clean(); b.clean(); c.clean() }
        let state = ExportHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.called(p); state.release.wait(); return try Self.reply(p)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: a.root, domain: .recordingExport, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
        let first = Task { try await encode(a, worker: worker) }, second = Task { try await encode(b, worker: worker) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel(); await registry.disable(.recordingExport)
        do { try await encode(c, worker: worker); XCTFail() } catch {}
        do { try await encode(a, worker: worker); XCTFail("Duplicate source owner") } catch {}
        XCTAssertEqual(worker.activeCount, 2)
        state.release.signal(); state.release.signal(); _ = await first.result; _ = await second.result
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try ScreenRecordingEncodingOwnership(a.root); XCTFail("Owner retired before child") } catch {}
        state.reap()
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.recordingExport); XCTAssertEqual(state.calls, 2)
        try assertRetained(a); try assertRetained(b)
        registry.preventNewWork(); do { try await encode(c, worker: worker); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testReapedChildCannotReleaseBlockedHostAndLateGenerationNeverPublishes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let state = ExportHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.called(p); state.reap(); state.release.wait(); return try Self.reply(p)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
        let pending = Task { try await encode(f, worker: worker) }; try await wait { state.calls == 1 }
        await registry.disable(.recordingExport)
        XCTAssertEqual(worker.activeCount, 1)
        do { try await registry.start(.recordingExport); XCTFail("Replaced occupied pool") } catch {}
        state.release.signal(); do { try await pending.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.recordingExport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path)); XCTAssertEqual(state.calls, 1)
        try assertRetained(f); await registry.shutdown()
    }

    func testManagedSyntheticMP4GIFAndControlledNativeRefusalNeverReplayPublication() async throws {
        let f = try Fixture(); defer { f.clean() }
        try FileManager.default.removeItem(at: f.source); try await ClipboardVideoPlaybackTests.movie(f.source)
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/encoding-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = ExportHealthState()
        let worker = MediaWorker(timeout: 600, requiresLifecycle: true, run: { request, cancelled in
            state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: f.root, domain: .recordingExport)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
        try await encode(f, worker: worker)
        let exporter = ScreenRecordingExporter(encoder: ScreenRecordingEncoder(worker: worker))
        let gif = f.root.appendingPathComponent("result.gif")
        try await exporter.export(source: f.source, destination: gif, format: .gif, trim: .init(start: 0, end: 1), progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: gif.path))
        do { try await exporter.export(source: f.source, destination: f.root.appendingPathComponent("invalid.mp4"), format: .mp4,
            trim: .init(start: 0, end: 100), progress: { _ in }); XCTFail() } catch {}
        XCTAssertEqual(module.module.health.current?.state, .ready); XCTAssertEqual(try record(f.root).attempts, 1)
        try assertRetained(f)
        let files = ScreenRecordingFiles(root: f.root.appendingPathComponent("owned"))
        let publication = try await files.preparePublication(f.destination, in: f.root.appendingPathComponent("saved"), format: .mp4)
        let published = try publication.commit { true }
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        XCTAssertThrowsError(try publication.commit { true })
        await registry.disable(.recordingExport); try await registry.start(.recordingExport)
        XCTAssertEqual(state.calls, 3); try assertRetained(f)
        await registry.shutdown()
    }
    func testAccountAndActualPanelRetirementPreventLateEncoderPublicationAndCopy() async throws {
        _ = NSApplication.shared
        for account in [false, true] {
            let state = ExportHealthState()
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
                state.called(p); state.release.wait(); let value = try Self.reply(p); state.reap(); return value
            })
            let fixture = ScreenRecordingCoordinatorTests.Fixture(exporter: ScreenRecordingExporter(encoder: ScreenRecordingEncoder(worker: worker)))
            let module = MediaExtractionModule(worker: worker, healthDirectory: fixture.root, domain: .recordingExport)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingExport)
            await fixture.recording(); fixture.model.stop(); await fixture.model.pendingTask?.value
            let source = try XCTUnwrap(fixture.model.sourceURL)
            XCTAssertTrue(fixture.model.canExport)
            fixture.model.export(copy: true); let pending = fixture.model.pendingTask
            try await wait { state.calls == 1 }
            fixture.model.export(copy: true); XCTAssertEqual(state.calls, 1)
            if account { NotificationCenter.default.post(name: .authDidLogout, object: nil) }
            else {
                let panel = ScreenRecordingPreviewPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.retire = { fixture.model.retirePreview() }; panel.orderOut(nil)
            }
            state.release.signal(); await pending?.value
            XCTAssertNil(fixture.model.savedURL); XCTAssertNil(fixture.copiedURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            let attempts = try FileManager.default.contentsOfDirectory(at: source.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".encoding-") }
            XCTAssertEqual(attempts.count, 1)
            let attempt = try XCTUnwrap(attempts.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: attempt.appendingPathComponent("output.mp4").path))
            await registry.disable(.recordingExport); try await registry.start(.recordingExport)
            XCTAssertEqual(state.calls, 1); XCTAssertNil(fixture.copiedURL)
            await registry.shutdown(); await fixture.clean()
        }
    }

}

@Suite("Recording encoding health presentation", .exclusiveUIState)
@MainActor struct RecordingExportHealthViewTests {
    @Test func independentEncodingRecoveryDoesNotRunProducer() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("recordingExport.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not run encoder"); throw MediaFailure.unavailable })
            let clock = ExportHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingExport, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.recordingExport]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.recordingExport)), in: host))
                try UI.snapshot(host, name: "encoding-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.recordingExport.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.recordingExport]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
