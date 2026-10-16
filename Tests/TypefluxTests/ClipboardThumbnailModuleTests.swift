import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class ClipboardThumbnailModuleTests: XCTestCase {
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

    @MainActor func testProductionDefaultsRefuseBeforeBindingWithoutChangingOriginal() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.png"), png = ClipboardTestSupport.imageData()
        try png.write(to: file)
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64); XCTFail() } catch {}
        let decoder = EnvironmentValues().clipboardThumbnailDecoder
        do { _ = try await decoder(file, 64); XCTFail() } catch {}
        XCTAssertEqual(MediaWorker.clipboardThumbnails.activeCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    func testProductionCompositionMapsEveryIndependentPoolWithoutStartingRequests() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(MediaExtractionModule.Domain.mediaExtraction.worker === MediaWorker.shared)
        XCTAssertTrue(MediaExtractionModule.Domain.mediaPreviews.worker === MediaWorker.previews)
        XCTAssertTrue(MediaExtractionModule.Domain.clipboardThumbnails.worker === MediaWorker.clipboardThumbnails)
        XCTAssertTrue(MediaExtractionModule.Domain.frameRegistration.worker === MediaWorker.frameRegistration)
        XCTAssertTrue(MediaExtractionModule.Domain.textRecognition.worker === MediaWorker.textRecognition)
        XCTAssertTrue(MediaExtractionModule.Domain.clipboardOCR.worker === MediaWorker.clipboardOCR)
        let modules = MediaExtractionModules(healthDirectory: root, worker: { _ in
            MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in XCTFail("Composition replayed a request"); throw MediaFailure.unavailable })
        })
        XCTAssertEqual(Set(modules.registrations.map(\.id)), [.mediaExtraction, .mediaPreviews, .clipboardThumbnails, .frameRegistration, .textRecognition, .clipboardOCR])
        let registry = ModuleRegistry(modules.registrations)
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        for domain in MediaExtractionModule.Domain.allCases {
            XCTAssertEqual(try record(root, domain.rawValue).attempts, 1)
        }
        await registry.shutdown()
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ThumbnailHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            return try self.refusal(p)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardThumbnails, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardThumbnails)
        let file = root.appendingPathComponent("private.pdf")
        let first = Task { try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker) }
        let second = Task { try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.clipboardThumbnails)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
        do { try await registry.start(.clipboardThumbnails); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.clipboardThumbnails)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let previews = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, policy: policy)
        let b = MediaExtractionModule(worker: previews, healthDirectory: root, domain: .clipboardThumbnails, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try previews.decode(.image, input: .data(Data())))
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try previews.decode(.image, input: .data(Data())))
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.decode(.image, input: .data(Data()))) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 1)
        XCTAssertEqual(try record(root, "clipboardThumbnails").attempts, 1)
        await registry.disable(.clipboardThumbnails)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 0)
        XCTAssertEqual(try record(root, "clipboardThumbnails").attempts, 1)
        XCTAssertThrowsError(try previews.decode(.image, input: .data(Data())))
    }

    func testCorruptionDoesNotBlockOtherDomainAndExplicitResetDoesNotRunRequests() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboardThumbnails.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = ThumbnailHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardThumbnails, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "clipboardThumbnails").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedInputRefusalAndMalformedRasterHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ThumbnailHealthState()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { p, _ in
            XCTAssertEqual(p.timeout, 3)
            let count = state.called()
            if count == 1 { return try self.refusal(p) }
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id)
            response.preview = .init(rasters: [.init(width: 1, height: 1)], pages: 0)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardThumbnails, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardThumbnails)
        for call in 0..<2 {
            do { _ = try await ClipboardThumbnailProvider.decode(root.appendingPathComponent("private.pdf"), edge: 64, worker: worker); XCTFail("Invalid input/output accepted") } catch {}
            if call == 0 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 2)
        await registry.shutdown()
    }

    @MainActor func testManagedScopedConsumerRefusesDisabledAndDoesNotReplayOnRecovery() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = ThumbnailHealthState()
        let worker = MediaWorker(timeout: 3, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardThumbnails)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardThumbnails)
        let file = root.appendingPathComponent("private.png"), png = ClipboardTestSupport.imageData(width: 40, height: 20)
        try png.write(to: file)
        let session = ClipboardThumbnailSession(), panel = ClipboardPanelModel()
        let entry = ClipboardTestSupport.entry(.image, imagePath: file.path)
        panel.reset(entries: [entry]); panel.isRecordingPaused = true; session.begin(panel)
        let access = session.access(for: entry)
        let image = AskContextImageModel(maximumEdge: 64, decode: { _ in
            try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker)
        })
        await image.load(file.path, access: access)
        XCTAssertNotNil(image.image); XCTAssertTrue(access.allows())
        let pdf = ClipboardTestSupport.makePDF(named: "private.pdf", in: root, pages: 1)
        let result = try await ClipboardThumbnailProvider.decode(pdf, edge: 64, worker: worker)
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(try record(root, "clipboardThumbnails").attempts, 1)
        let count = state.calls
        await registry.disable(.clipboardThumbnails)
        do { _ = try await ClipboardThumbnailProvider.decode(file, edge: 64, worker: worker); XCTFail() } catch {}
        session.end(); XCTAssertNil(image.image)
        try await registry.start(.clipboardThumbnails)
        XCTAssertEqual(state.calls, count, "Readiness must not reread history or replay capture/copy/paste")
        session.begin(panel); XCTAssertFalse(access.allows())
        await image.load(file.path, access: access); XCTAssertNil(image.image)
        XCTAssertEqual(state.calls, count)
        await image.load(file.path, access: session.access(for: entry)); XCTAssertNotNil(image.image)
        panel.replaceEntries([]); session.changed(); XCTAssertNil(image.image)
        XCTAssertEqual(try Data(contentsOf: file), png)
        session.end(); await registry.shutdown()
    }

}

private final class ThumbnailHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Clipboard thumbnail health presentation", .exclusiveUIState)
@MainActor struct ClipboardThumbnailHealthViewTests {
    @Test func independentThumbnailRecoveryDoesNotDecode() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("clipboardThumbnails.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not decode"); throw MediaFailure.unavailable })
            let clock = ThumbnailHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardThumbnails, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.clipboardThumbnails]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.clipboardThumbnails"), in: host))
                try UI.snapshot(host, name: "clipboard-thumbnail-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.clipboardThumbnails.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.clipboardThumbnails]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
