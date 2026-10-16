import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class RecordingTimelineModuleTests: XCTestCase {
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

    func testProductionDefaultsRefuseWhileHostInspectionRemainsAvailable() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.mov"); try Data([1]).write(to: file)
        do { _ = try await ScreenRecordingPreviewMedia.load(file); XCTFail() } catch {}
        do { _ = try await ScreenRecordingPreviewMedia.thumbnail(file); XCTFail() } catch {}
        let original = try await ScreenRecordingTimelineLoader.inspect(file)
        XCTAssertEqual(original.bytes, 1)
        XCTAssertEqual(MediaWorker.recordingTimeline.activeCount, 0)
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = RecordingTimelineHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            let response = MediaResponse(id: input.id, failure: .unreadable)
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        let file = root.appendingPathComponent("file.pdf"); try Data([1]).write(to: file)
        let detector = ScreenRecordingTimelineLoader(worker: worker)
        let first = Task { try await detector.load(file) }
        let second = Task { try await detector.load(file) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.recordingTimeline)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await detector.load(file); XCTFail() } catch {}
        do { try await registry.start(.recordingTimeline); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.recordingTimeline)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await detector.load(file); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let recognition = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, domain: .clipboardMetadata, policy: policy)
        let b = MediaExtractionModule(worker: recognition, healthDirectory: root, domain: .recordingTimeline, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try recognition.perform(.recordingTimeline, input: .data(Data()), isCancelled: { false }) { response, _ in response })
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try recognition.perform(.recordingTimeline, input: .data(Data()), isCancelled: { false }) { response, _ in response })
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.perform(.clipboardMedia, input: .data(Data()), clipboard: .init(kind: .pdf), isCancelled: { false }) { response, _ in response }) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 1)
        XCTAssertEqual(try record(root, "recordingTimeline").attempts, 1)
        await registry.disable(.recordingTimeline)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "clipboardMetadata").attempts, 0)
        XCTAssertEqual(try record(root, "recordingTimeline").attempts, 1)
        XCTAssertThrowsError(try recognition.perform(.recordingTimeline, input: .data(Data()), isCancelled: { false }) { response, _ in response })
    }

    func testCorruptRecordRequiresExplicitResetWithoutExtractionReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("recordingTimeline.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = RecordingTimelineHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "recordingTimeline").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedInputRefusalsAndInvalidSuccessfulRawOutputsHaveDistinctHealth() async throws {
        for operation in [MediaRequest.Operation.recordingTimeline, .recordingPosterVideo, .recordingPosterGIF] {
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let state = RecordingTimelineHealthState()
            var policy = ModulePolicy(); policy.automaticallyRecover = false
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
                XCTAssertEqual(p.timeout, 30)
                let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
                XCTAssertEqual(input.operation, operation)
                let count = state.called()
                var response = MediaResponse(id: input.id)
                if count <= 2 { response.failure = count == 1 ? .unreadable : .tooLarge }
                else if operation == .recordingTimeline {
                    response.timeline = .init(duration: 2, width: 160, height: 120, fps: 30,
                        rasters: Array(repeating: .init(width: 160, height: 120), count: 10), audio: .absent)
                } else { response.preview = .init(rasters: [.init(width: 160, height: 120)]) }
                // A syntactically valid success must still fail health when its promised raw files are missing.
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline, policy: policy)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
            let loader = ScreenRecordingTimelineLoader(worker: worker)
            let url = root.appendingPathComponent(operation == .recordingPosterGIF ? "private.gif" : "private.mov")
            do { _ = try await loader.load(url); XCTFail() } catch {}
            XCTAssertEqual(state.calls, 0); XCTAssertEqual(module.module.health.current?.state, .ready)
            try Data([1]).write(to: url)
            for call in 0..<3 {
                do {
                    if operation == .recordingTimeline { _ = try await loader.load(url) }
                    else { _ = try await loader.thumbnail(url) }
                    XCTFail("Invalid source/output accepted")
                } catch {}
                if call < 2 { XCTAssertEqual(module.module.health.current?.state, .ready) }
            }
            try await wait { module.module.health.current?.state == .recovering }
            XCTAssertEqual(state.calls, 3); XCTAssertEqual(try record(root, "recordingTimeline").attempts, 1)
            XCTAssertEqual(try Data(contentsOf: url), Data([1])); await registry.shutdown()
        }
    }

    @MainActor func testManagedBatchAndBothPostersPreserveGeometryAndDisplayLease() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/timeline-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = RecordingTimelineHealthState()
        let worker = MediaWorker(timeout: 30, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
        let url = root.appendingPathComponent("silent.mov"); try await ClipboardVideoPlaybackTests.movie(url)
        let loader = ScreenRecordingTimelineLoader(worker: worker)
        let media = try await ScreenRecordingPreviewMedia.load(url, loader: loader)
        XCTAssertEqual(media.thumbnails.count, 10); XCTAssertEqual(media.size, CGSize(width: 32, height: 64))
        XCTAssertEqual(media.audio, .absent); XCTAssertTrue(media.waveform.isEmpty)
        XCTAssertNotEqual(media.thumbnails.first?.dataProvider?.data as Data?, media.thumbnails.last?.dataProvider?.data as Data?)
        let poster = try await loader.thumbnail(url); XCTAssertEqual(poster.width, 32); XCTAssertEqual(poster.height, 64)
        let gif = root.appendingPathComponent("private.gif")
        try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 400, height: 100), type: .gif).write(to: gif)
        let budget = AskToolPixelBudget(limit: 200 * 120 * 8)
        var image: CGImage? = try await ScreenRecordingTimelineLoader(worker: worker, budget: budget).thumbnail(gif)
        XCTAssertEqual(image?.width, 200); XCTAssertEqual(image?.height, 50)
        XCTAssertEqual(try record(root, "recordingTimeline").attempts, 1)
        await registry.disable(.recordingTimeline); try await registry.start(.recordingTimeline)
        XCTAssertEqual(state.calls, 3, "Readiness must not repeat either consumer")
        await registry.shutdown()
        XCTAssertThrowsError(try budget.acquire(bytes: 1))
        image = nil; XCTAssertNoThrow(try budget.acquire(bytes: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testUnavailablePosterKeepsSuppliedPixelsAndExplicitFileActionsWithoutRecoveryReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private.mov"); try Data([1]).write(to: url)
        let state = RecordingTimelineHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in
            _ = state.called(); XCTFail("Recovery replayed poster"); throw MediaFailure.unavailable
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
        let registry = ModuleRegistry([module.registration]), loader = ScreenRecordingTimelineLoader(worker: worker)
        let model = ScreenRecordingToastModel(decode: { try await loader.thumbnail($0) })
        model.start(url, thumbnail: nil); await model.task?.value
        XCTAssertTrue(model.ready); XCTAssertNil(model.image)
        try await registry.start(.recordingTimeline)
        XCTAssertTrue(model.ready); XCTAssertNil(model.image); XCTAssertEqual(state.calls, 0)
        await registry.disable(.recordingTimeline)
        let supplied = AskAttachmentFixture.image(width: 160, height: 100)
        model.start(url, thumbnail: supplied); await model.task?.value
        XCTAssertTrue(model.image === supplied); XCTAssertTrue(model.ready)
        var actions = 0
        model.perform(generation: model.generation) { _ in actions += 1 }; await model.actionTask?.value
        XCTAssertEqual(actions, 1); XCTAssertEqual(state.calls, 0)
        model.retire(); try await registry.start(.recordingTimeline)
        XCTAssertNil(model.image); XCTAssertNil(model.url); XCTAssertFalse(model.ready)
        XCTAssertEqual(actions, 1); await registry.shutdown()
    }

    @MainActor func testLateManagedPosterCannotSurviveActualHideAccountReplacementOrOwnerRelease() async throws {
        _ = NSApplication.shared
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private.mov"); try Data([1]).write(to: url)
        for mode in 0..<4 {
            let state = RecordingTimelineHealthState(), release = DispatchSemaphore(value: 0)
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
                p.onStarted?(); _ = state.called(); release.wait(); p.onReaped?(); return try self.refusal(p)
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.recordingTimeline)
            let loader = ScreenRecordingTimelineLoader(worker: worker)
            let model = ScreenRecordingToastModel(decode: { try await loader.thumbnail($0) })
            var controller: ScreenRecordingToastController? = ScreenRecordingToastController(model: model)
            controller?.showSaved(url, thumbnail: nil, duration: 1)
            let pending = model.task, token = model.generation
            try await wait { state.calls == 1 }
            switch mode {
            case 0: controller?.panel?.orderOut(nil)
            case 1: NotificationCenter.default.post(name: .authDidLogout, object: nil)
            case 2: controller?.showSaved(url, thumbnail: AskAttachmentFixture.image(width: 100, height: 60), duration: 1)
            default: controller = nil
            }
            release.signal(); await pending?.value; await model.task?.value
            XCTAssertNotEqual(model.generation, token)
            model.perform(generation: token) { _ in XCTFail("Old authorization committed") }
            if mode == 2 { XCTAssertTrue(model.ready); XCTAssertNotNil(model.image) }
            else { XCTAssertFalse(model.ready); XCTAssertNil(model.image); XCTAssertNil(model.url) }
            controller?.hide(); await registry.disable(.recordingTimeline); try await registry.start(.recordingTimeline)
            XCTAssertNil(model.image); XCTAssertEqual(state.calls, 1)
            await registry.shutdown()
        }
    }
}
private final class RecordingTimelineHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Recording timeline health presentation", .exclusiveUIState)
@MainActor struct RecordingTimelineHealthViewTests {
    @Test func independentTimelineRecoveryDoesNotReadFiles() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("recordingTimeline.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not extract metadata"); throw MediaFailure.unavailable })
            let clock = RecordingTimelineHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .recordingTimeline, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.recordingTimeline]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.recordingTimeline"), in: host))
                try UI.snapshot(host, name: "timeline-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.recordingTimeline.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.recordingTimeline]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
