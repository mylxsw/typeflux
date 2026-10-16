import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class ClipboardMetadataModuleTests: XCTestCase {
    private func record(_ root: URL, _ name: String) throws -> ModuleHealthStore.Record {
        try JSONDecoder().decode(ModuleHealthStore.Record.self, from: Data(contentsOf: root.appendingPathComponent(name + ".json")))
    }
    private func wait(attempts: Int = 400, _ condition: () -> Bool) async throws {
        for _ in 0..<attempts { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Health did not settle")
    }
    private func refusal(_ request: ManagedProcess.Request) throws -> ManagedProcess.Result {
        let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(request.stdin))
        return .init(termination: .exited(0), exitCode: 0,
            stdout: String(decoding: try JSONEncoder().encode(MediaResponse(id: input.id, failure: .unreadable)), as: UTF8.self),
            stderr: "", outputTruncated: false)
    }

    func testProductionDefaultsRefuseBeforeBindingWithoutInventingMetadata() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.pdf"); try Data([1]).write(to: file)
        let provider = ClipboardMediaInfoProvider()
        do { _ = try await provider.load(.init(url: file, options: .init(kind: .pdf))); XCTFail() } catch {}
        let info = await provider.info(for: file, kind: .pdf)
        let waveform = await provider.waveform(for: file, bars: 180)
        XCTAssertNil(info); XCTAssertNil(waveform)
        XCTAssertEqual(MediaWorker.clipboardMetadata.activeCount, 0)
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ClipboardMetadataHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 10, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id); response.clipboard = .init(pages: 7)
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let file = root.appendingPathComponent("file.pdf"); try Data([1]).write(to: file)
        let detector = ClipboardMediaInfoProvider(worker: worker)
        let first = Task { try await detector.load(.init(url: file, options: .init(kind: .pdf))) }
        let second = Task { try await detector.load(.init(url: file, options: .init(kind: .pdf))) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.clipboardMetadata)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await detector.load(.init(url: file, options: .init(kind: .pdf))); XCTFail() } catch {}
        do { try await registry.start(.clipboardMetadata); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.clipboardMetadata)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await detector.load(.init(url: file, options: .init(kind: .pdf))); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let recognition = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 10, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, domain: .clipboardOCR, policy: policy)
        let b = MediaExtractionModule(worker: recognition, healthDirectory: root, domain: .clipboardMetadata, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try recognition.perform(.clipboardMedia, input: .data(Data()), clipboard: .init(kind: .pdf), isCancelled: { false }) { response, _ in response })
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try recognition.perform(.clipboardMedia, input: .data(Data()), clipboard: .init(kind: .pdf), isCancelled: { false }) { response, _ in response })
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.decode(.clipboardOCR, input: .data(Data()))) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 1)
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 1)
        await registry.disable(.clipboardMetadata)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 0)
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 1)
        XCTAssertThrowsError(try recognition.perform(.clipboardMedia, input: .data(Data()), clipboard: .init(kind: .pdf), isCancelled: { false }) { response, _ in response })
    }

    func testCorruptRecordRequiresExplicitResetWithoutExtractionReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboardMetadata.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = ClipboardMetadataHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedRefusalAndMalformedMetadataHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ClipboardMetadataHealthState()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 10, requiresLifecycle: true, run: { p, _ in
            XCTAssertEqual(p.timeout, 10)
            let count = state.called()
            if count == 1 { return try self.refusal(p) }
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id)
            if count == 2 { response.failure = .tooLarge }
            else { response.clipboard = .init(pages: 0) }
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let file = root.appendingPathComponent("file.pdf"); try Data([1]).write(to: file)
        for missing in [root.appendingPathComponent("missing.pdf"), URL(string: "https://example.test/private.pdf")!] {
            do { _ = try await ClipboardMediaInfoProvider(worker: worker).load(.init(url: missing, options: .init(kind: .pdf))); XCTFail() } catch {}
        }
        XCTAssertEqual(state.calls, 0); XCTAssertEqual(module.module.health.current?.state, .ready)
        for call in 0..<3 {
            do { _ = try await ClipboardMediaInfoProvider(worker: worker).load(.init(url: file, options: .init(kind: .pdf))); XCTFail("Invalid input/output accepted") } catch {}
            if call < 2 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 3)
        await registry.shutdown()
    }

    @MainActor func testManagedRealMetadataAndScopedConsumerNeverReplayOnRecovery() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/metadata-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = ClipboardMetadataHealthState()
        let worker = MediaWorker(timeout: 10, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]), provider = ClipboardMediaInfoProvider(worker: worker)
        let file = ClipboardTestSupport.makePDF(named: "private.pdf", in: root, pages: 3)
        let request = ClipboardMediaInfoProvider.Request(url: file, options: .init(kind: .pdf))
        let scope = AskImagePresentationScope()
        func access() -> AskImagePresentationAccess { .init(scope: scope, epoch: scope.epoch, authorize: { true }) }
        let model = ClipboardMediaProjection(read: { try await provider.load($0) })
        await model.load(request, access: access()); XCTAssertNil(model.value); XCTAssertEqual(state.calls, 0)
        try await registry.start(.clipboardMetadata)
        await model.load(request, access: access())
        XCTAssertNil(model.value); XCTAssertEqual(state.calls, 0, "Readiness replayed a failed presentation")
        scope.invalidate(); await model.load(request, access: access())
        XCTAssertEqual(model.value?.pages, 3)
        let wav = try ClipboardTestSupport.makeAudioFile(named: "private.wav", in: root, seconds: 1)
        let duration = try await provider.load(.init(url: wav, options: .init(kind: .duration, container: .wav)))
        XCTAssertEqual(duration.duration ?? 0, 1, accuracy: 0.05)
        let waveform = try await provider.load(.init(url: wav, options: .init(kind: .waveform, container: .wav)))
        XCTAssertEqual(waveform.waveform?.count, 180); XCTAssertEqual(waveform.waveform?.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(ClipboardMediaInfoProvider.waveformScanLimit, 600)
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 1)
        let old = access(); scope.setVisible(false); XCTAssertNil(model.value)
        let calls = state.calls
        await registry.disable(.clipboardMetadata); try await registry.start(.clipboardMetadata)
        await model.load(request, access: old); XCTAssertNil(model.value); XCTAssertEqual(state.calls, calls)
        let malformed = root.appendingPathComponent("bad.pdf"); try Data([1, 2]).write(to: malformed)
        do { _ = try await provider.load(.init(url: malformed, options: .init(kind: .pdf))); XCTFail() } catch {}
        XCTAssertEqual(module.module.health.current?.state, .ready)
        XCTAssertEqual(try Data(contentsOf: malformed), Data([1, 2]))
        await registry.shutdown()
    }

    @MainActor func testActualPanelRetirementRejectsLateManagedMetadataAndFreshPermission() async throws {
        _ = NSApplication.shared
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.pdf"); try Data([1]).write(to: file)
        let request = ClipboardMediaInfoProvider.Request(url: file, options: .init(kind: .pdf))
        for mode in 0..<4 {
            let state = ClipboardMetadataHealthState(), release = DispatchSemaphore(value: 0)
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 10, requiresLifecycle: true, run: { p, _ in
                p.onStarted?(); _ = state.called(); release.wait(); p.onReaped?()
                let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
                var response = MediaResponse(id: input.id); response.clipboard = .init(pages: 7)
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
            let suite = "ClipboardMetadataModuleTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
            let panel = ClipboardPanelModel(), entry = ClipboardTestSupport.entry(.pdf, filePaths: [file.path])
            panel.reset(entries: [entry])
            var controller: ClipboardPanelController? = ClipboardPanelController(settingsStore: SettingsStore(defaults: defaults), thumbnailDecoder: { _, _ in throw MediaFailure.unavailable })
            controller?.present(panel)
            let session = try XCTUnwrap(controller?.thumbnails), old = session.access(for: entry)
            panel.isRecordingPaused = true; XCTAssertTrue(old.allows())
            let provider = ClipboardMediaInfoProvider(worker: worker)
            let model = ClipboardMediaProjection(read: { try await provider.load($0) })
            let pending = Task { await model.load(request, access: old) }
            try await wait { state.calls == 1 }
            switch mode {
            case 0: controller?.presentedWindow?.orderOut(nil)
            case 1: NotificationCenter.default.post(name: .authDidLogout, object: nil)
            case 2: panel.replaceEntries([])
            default: controller = nil
            }
            try await wait { !old.allows() }
            release.signal(); await pending.value
            XCTAssertNil(model.value)
            await registry.disable(.clipboardMetadata); try await registry.start(.clipboardMetadata)
            panel.reset(entries: [entry]); session.begin(panel)
            await model.load(request, access: old)
            XCTAssertNil(model.value); XCTAssertEqual(state.calls, 1)
            session.end(); controller?.dismiss(); await registry.shutdown()
        }
    }

}

private final class ClipboardMetadataHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Clipboard metadata health presentation", .exclusiveUIState)
@MainActor struct ClipboardMetadataHealthViewTests {
    @Test func independentMetadataRecoveryDoesNotReadFiles() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("clipboardMetadata.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not extract metadata"); throw MediaFailure.unavailable })
            let clock = ClipboardMetadataHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.clipboardMetadata]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.clipboardMetadata"), in: host))
                try UI.snapshot(host, name: "metadata-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.clipboardMetadata.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.clipboardMetadata]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
