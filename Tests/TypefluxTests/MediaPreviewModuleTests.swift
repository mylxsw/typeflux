import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class MediaPreviewModuleTests: XCTestCase {
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
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 20, height: 10), type: .png)
        let file = root.appendingPathComponent("private.png"); try png.write(to: file)
        do { _ = try await AskContextImageDecoder.decode("data:image/png;base64," + png.base64EncodedString()); XCTFail() } catch {}
        do { _ = try await AskGeneratedImageValidator.shared.validate(png); XCTFail() } catch {}
        do { _ = try await AskToolImageNormalizer.image(png, type: .png); XCTFail() } catch {}
        do { _ = try await AskWorkflowImage.clipboard(file); XCTFail() } catch {}
        let picture = await AskFinderIcon.image(for: file); XCTAssertNil(picture)
        XCTAssertEqual(MediaWorker.previews.activeCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let previews = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 3, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, policy: policy)
        let b = MediaExtractionModule(worker: previews, healthDirectory: root, domain: .mediaPreviews, policy: policy)
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
        XCTAssertEqual(try record(root, "mediaPreviews").attempts, 1)
        await registry.disable(.mediaPreviews)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 0)
        XCTAssertEqual(try record(root, "mediaPreviews").attempts, 1)
        XCTAssertThrowsError(try previews.decode(.image, input: .data(Data())))
    }

    func testCorruptionDoesNotBlockOtherDomainAndExplicitResetDoesNotRunRequests() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mediaPreviews.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = PreviewHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "mediaPreviews").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedInputRefusalAndMalformedRasterHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = PreviewHealthState()
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
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        for call in 0..<2 {
            do { _ = try await AskSmallIconDecoder.decode(.data(Data([1])), worker: worker); XCTFail("Invalid input/output accepted") } catch {}
            if call == 0 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 2)
        await registry.shutdown()
    }

    func testManagedConsumersUseTypedPoolWithoutReplayingProducer() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/preview-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = PreviewHealthState()
        let worker = MediaWorker(timeout: 3, requiresLifecycle: true, run: { p, cancelled in
            _ = state.called(); var p = p
            p.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(p, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 40, height: 20), type: .png)
        let file = root.appendingPathComponent("image.png"); try png.write(to: file)
        let source = "data:image/png;base64," + png.base64EncodedString()
        let actual1 = try await AskContextImageDecoder.decode(source, worker: worker).images.count
        XCTAssertEqual(actual1, 1)
        let actual2 = try await AskArtifactPresentation.image(png, mediaType: "image/png", worker: worker).images.count
        XCTAssertEqual(actual2, 1)
        let actual3 = try await AskSmallIconDecoder.decode(.data(png), worker: worker).width
        XCTAssertEqual(actual3, 40)
        let actual4 = try await AskFinderIcon.decode(.init(kind: .type, value: "public.folder"), worker: worker).images.count
        XCTAssertEqual(actual4, 1)
        let actual5 = try await AskQuickLookThumbnail.decode(file, pixels: .init(width: 56, height: 56), worker: worker).images.count
        XCTAssertEqual(actual5, 1)
        let normalized = try await AskToolImageNormalizer(worker: worker).normalize(png, type: .png)
        XCTAssertTrue(AskToolImageNormalizer.valid(normalized))
        let actual6 = try await AskGeneratedImageValidator(worker: worker).validate(png).data
        XCTAssertEqual(actual6, png)
        let result = try await AskWorkflowImage.resolve(file.path, folder: root, cache: root.appendingPathComponent("cache"), home: "/", worker: worker).get()
        let actual7 = try await AskWorkflowImage.render(result, worker: worker).images.count
        XCTAssertEqual(actual7, 1)
        let actual8 = try await AskWorkflowImage.clipboard(file, worker: worker, preserveOriginalPNG: true).png
        XCTAssertEqual(actual8, png)
        XCTAssertEqual(try record(root, "mediaPreviews").attempts, 1)
        let count = state.calls
        await registry.disable(.mediaPreviews)
        do { _ = try await AskWorkflowImage.clipboard(file, worker: worker); XCTFail("Disabled conversion") } catch {}
        try await registry.start(.mediaPreviews)
        XCTAssertEqual(state.calls, count, "Readiness must never replay copy, workflow or paid generation")
        XCTAssertEqual(try Data(contentsOf: file), png)
        await registry.shutdown()
    }
}

private final class PreviewHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Media preview health presentation", .exclusiveUIState)
@MainActor struct MediaPreviewHealthViewTests {
    @Test func defaultViewsFailClosedBeforeBindingAndTextStillLoads() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("fixture.png")
            let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 20, height: 10), type: .png)
            try png.write(to: file)
            let scope = AskImagePresentationScope()
            let content = VStack {
                AskSmallFileIcon(url: file, symbol: "doc")
                AskWorkflowImageView(image: .init(url: file, width: 20, height: 10), size: .init(width: 100, height: 50))
                AskWorkflowImageEditorPreview(name: "fixture.png", folder: root)
            }.environment(\.askContextImageAccess, .init(scope: scope, epoch: scope.epoch, authorize: { true }))
            try await UI.withWindow(content, width: 300, height: 190) { _, host in
                // Drain view-owned preparations. They can read this private fixture,
                // but the unbound production pool must never launch a decoder.
                try await Task.sleep(for: .milliseconds(200))
                #expect(UI.contains(L("ask.image.previewUnavailable"), in: host))
                #expect(MediaWorker.previews.activeCount == 0)
                scope.setVisible(false)
            }
            let loader = AskFilePreviewLoader(metadata: { _, _ in .init(text: "private text", fileSize: 12, modified: Date()) })
            var result: AskFilePreviewContent?
            loader.load(previewHit("fixture.txt"), pixels: .init(width: 100, height: 100)) { result = $0 }
            try await UI.wait { result != nil }
            #expect(result?.text == "private text")
            loader.cancel(); loader.clearCache()
            #expect(try Data(contentsOf: file) == png)
        }
    }

    @Test func independentPreviewRecoveryDoesNotDecode() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("mediaPreviews.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not decode"); throw MediaFailure.unavailable })
            let clock = PreviewHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.mediaPreviews]?.failure == .healthPersistence }
                #expect(UI.contains(L("settings.services.mediaPreviews"), in: host))
                try UI.snapshot(host, name: "media-preview-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.mediaPreviews.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.mediaPreviews]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
