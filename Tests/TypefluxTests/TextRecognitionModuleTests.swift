import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class TextRecognitionModuleTests: XCTestCase {
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

    func testProductionDefaultsRefuseWithoutInventingEmptyTextOrGeometry() async throws {
        let image = ScreenCaptureTestSupport.image(width: 200, height: 200)
        do { _ = try await VisionImageTextRecognizer().recognizeText(in: .image(image)); XCTFail() } catch {}
        do { _ = try await VisionTextHeightMeasurer().geometry(in: image); XCTFail() } catch {}
        do { _ = try await VisionSensitiveInfoScanner().scan(image); XCTFail() } catch {}
        XCTAssertEqual(MediaWorker.textRecognition.activeCount, 0)
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TextHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id); response.recognition = .init(lines: [])
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let image = ScreenCaptureTestSupport.image(width: 200, height: 200)
        let detector = VisionImageTextRecognizer(worker: worker)
        let first = Task { try await detector.recognizeText(in: .image(image)) }
        let second = Task { try await detector.recognizeText(in: .image(image)) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.textRecognition)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await detector.recognizeText(in: .image(image)); XCTFail() } catch {}
        do { try await registry.start(.textRecognition); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.textRecognition)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await detector.recognizeText(in: .image(image)); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let recognition = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, policy: policy)
        let b = MediaExtractionModule(worker: recognition, healthDirectory: root, domain: .textRecognition, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try recognition.decode(.image, input: .data(Data())))
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try recognition.decode(.image, input: .data(Data())))
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.decode(.image, input: .data(Data()))) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 1)
        XCTAssertEqual(try record(root, "textRecognition").attempts, 1)
        await registry.disable(.textRecognition)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "mediaExtraction").attempts, 0)
        XCTAssertEqual(try record(root, "textRecognition").attempts, 1)
        XCTAssertThrowsError(try recognition.decode(.image, input: .data(Data())))
    }

    func testCorruptRecordRequiresExplicitResetWithoutRecognitionReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("textRecognition.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = TextHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "textRecognition").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedRefusalAndMalformedTextHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TextHealthState()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            XCTAssertEqual(p.timeout, 30)
            let count = state.called()
            if count == 1 { return try self.refusal(p) }
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id)
            response.recognition = .init(lines: [.init(text: "private", confidence: 1, box: .zero, regions: [])])
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let image = ScreenCaptureTestSupport.image(width: 200, height: 200)
        for call in 0..<2 {
            do { _ = try await VisionImageTextRecognizer(worker: worker).recognizeText(in: .image(image)); XCTFail("Invalid input/output accepted") } catch {}
            if call == 0 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 2)
        await registry.shutdown()
    }

    @MainActor func testManagedNativeTextGeometryAndTiledConsumersPreserveExactBounds() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/text-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = TextHealthState()
        let worker = MediaWorker(timeout: 30, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let data = ClipboardTestSupport.imageData(width: 1400, height: 240, text: "Contact a@example.com")
        let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        let recognizer = VisionImageTextRecognizer(worker: worker)
        let result = try await TiledImageTextRecognizer(base: recognizer).recognizeText(in: .image(image))
        let line = try XCTUnwrap(result.lines.first { $0.sensitiveMatches?.isEmpty == false })
        let match = try XCTUnwrap(line.sensitiveMatches?.first)
        let box = try XCTUnwrap(line.locate?(match.range))
        XCTAssertGreaterThan(box.width, 0); XCTAssertLessThan(box.width, line.boundingBox.width)
        XCTAssertNil(line.locate?(.init(location: 0, length: 1)))
        let findings = ScreenshotSensitiveInfoDetector.findings(in: result)
        XCTAssertEqual(findings.first?.text, "a@example.com")
        let geometry = try await VisionTextHeightMeasurer(recognizer: recognizer).geometry(in: image)
        XCTAssertFalse(geometry.lines.isEmpty); XCTAssertGreaterThan(try XCTUnwrap(geometry.height), 0)
        let file = root.appendingPathComponent("private.png"); try data.write(to: file)
        let encoded = try await recognizer.recognizeText(in: .url(file)); XCTAssertEqual(encoded.string, result.string)
        XCTAssertEqual(try record(root, "textRecognition").attempts, 1)
        let calls = state.calls
        await registry.disable(.textRecognition)
        do { _ = try await recognizer.recognizeText(in: .image(image)); XCTFail() } catch {}
        try await registry.start(.textRecognition)
        XCTAssertEqual(state.calls, calls, "Recovery must not recognize, translate, redact or copy the previous image")
        await registry.shutdown()
        do { _ = try await recognizer.textGeometry(in: image); XCTFail() } catch {}
    }

    @MainActor func testManagedUnavailableRedactionRemainsFailedAfterRecoveryUntilNewRequest() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = TextHealthState()
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            _ = state.called(); return try self.refusal(p)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration])
        let scanner = VisionSensitiveInfoScanner(recognizer: TiledImageTextRecognizer(base: VisionImageTextRecognizer(worker: worker)))
        let controller = ScreenshotSensitiveInfoController(scanner: scanner)
        controller.scan(ScreenCaptureTestSupport.image(width: 200, height: 200), scale: 1)
        await controller.waitForScan()
        XCTAssertEqual(controller.suggestions.status, .failed); XCTAssertFalse(controller.hasFindings)
        try await registry.start(.textRecognition)
        XCTAssertEqual(state.calls, 0); XCTAssertEqual(controller.suggestions.status, .failed)
        NotificationCenter.default.post(name: .authDidLogout, object: nil)
        XCTAssertFalse(controller.isPanelShown)
        await registry.disable(.textRecognition); try await registry.start(.textRecognition)
        XCTAssertEqual(state.calls, 0); XCTAssertFalse(controller.isPanelShown)
        await registry.shutdown()
    }

}

private final class TextHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Shared text recognition health presentation", .exclusiveUIState)
@MainActor struct TextRecognitionHealthViewTests {
    @Test func independentTextRecoveryDoesNotRecognize() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("textRecognition.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not decode"); throw MediaFailure.unavailable })
            let clock = TextHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.textRecognition]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.textRecognition)), in: host))
                try UI.snapshot(host, name: "text-recognition-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.textRecognition.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.textRecognition]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
