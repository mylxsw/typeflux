import AppKit
import SwiftUI
import Testing
import XCTest
import TypefluxMediaProtocol
@testable import Typeflux

final class ClipboardOCRModuleTests: XCTestCase {
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

    func testProductionDefaultsRefuseBeforeBindingWithoutTouchingPasteboard() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png"); try Data([1]).write(to: file)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let actions = SystemClipboardContentActions(pasteboard: pasteboard)
        do { _ = try await actions.recognizeText(in: file); XCTFail("Unavailable OCR became empty text") } catch {}
        XCTAssertEqual(MediaWorker.clipboardOCR.activeCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    func testManagedCancellationRetainsCapacityUntilUncooperativeHostReturns() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ClipboardOCRHealthState(), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            p.onStarted?(); p.onReaped?(); _ = state.called(); release.wait()
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id); response.ocr = .init(lines: ["late valid text"])
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let file = root.appendingPathComponent("image.png"); try Data([1]).write(to: file)
        let detector = ClipboardTextRecognizer(worker: worker)
        let first = Task { try await detector.recognize(file) }
        let second = Task { try await detector.recognize(file) }
        try await wait { state.calls == 2 }
        first.cancel(); second.cancel()
        await registry.disable(.clipboardOCR)
        XCTAssertEqual(worker.activeCount, 2)
        do { _ = try await detector.recognize(file); XCTFail() } catch {}
        do { try await registry.start(.clipboardOCR); XCTFail("Expanded occupied pool") } catch {}
        XCTAssertEqual(state.calls, 2)
        release.signal(); release.signal()
        do { _ = try await first.value; XCTFail("Late result") } catch {}
        do { _ = try await second.value; XCTFail("Late result") } catch {}
        try await wait { worker.activeCount == 0 && module.module.health.current?.hasLifecycleWork == false }
        try await registry.start(.clipboardOCR)
        XCTAssertEqual(state.calls, 2)
        registry.preventNewWork()
        do { _ = try await detector.recognize(file); XCTFail() } catch {}
        await registry.shutdown()
    }

    func testIndependentPersistentBudgetsFaultsDisableAndQuit() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let extraction = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in try self.refusal(p) })
        let recognition = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { _, _ in
            .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private", outputTruncated: false)
        })
        let a = MediaExtractionModule(worker: extraction, healthDirectory: root, domain: .textRecognition, policy: policy)
        let b = MediaExtractionModule(worker: recognition, healthDirectory: root, domain: .clipboardOCR, policy: policy)
        let registry = ModuleRegistry([a.registration, b.registration])
        XCTAssertThrowsError(try recognition.decode(.clipboardOCR, input: .data(Data())))
        let failures = await registry.startAll(); XCTAssertTrue(failures.isEmpty)
        let original = a.module.health.current?.generation
        XCTAssertThrowsError(try recognition.decode(.clipboardOCR, input: .data(Data())))
        try await wait { b.module.health.current?.state == .recovering && b.module.health.current?.hasLifecycleWork == false }
        for _ in 0..<6 { XCTAssertThrowsError(try extraction.decode(.image, input: .data(Data()))) }
        XCTAssertEqual(a.module.health.current?.state, .ready)
        XCTAssertEqual(a.module.health.current?.generation, original)
        XCTAssertEqual(try record(root, "textRecognition").attempts, 1)
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 1)
        await registry.disable(.clipboardOCR)
        XCTAssertEqual(a.module.health.current?.state, .ready)
        await registry.shutdown()
        XCTAssertEqual(try record(root, "textRecognition").attempts, 0)
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 1)
        XCTAssertThrowsError(try recognition.decode(.clipboardOCR, input: .data(Data())))
    }

    func testCorruptRecordRequiresExplicitResetWithoutRecognitionReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboardOCR.json")
        try Data("private corrupt record".utf8).write(to: file)
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { _, _ in XCTFail("Recovery replayed work"); throw MediaFailure.unavailable })
        let clock = ClipboardOCRHealthState()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR, uptime: { clock.now })
        let registry = ModuleRegistry([module.registration])
        let failures = await registry.startAll(); XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("private corrupt record".utf8))
        XCTAssertEqual(module.module.health.current?.failure, .healthPersistence)
        clock.advance()
        let reset = await module.module.supervisor.requestRecovery(resetPersistentBudget: true)
        XCTAssertEqual(reset, .started)
        try await wait { module.module.health.current?.state == .ready }
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private"))
        await registry.shutdown()
    }

    func testExpectedRefusalAndMalformedTextHaveDifferentHealthOutcomes() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ClipboardOCRHealthState()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            XCTAssertEqual(p.timeout, 30)
            let count = state.called()
            if count == 1 { return try self.refusal(p) }
            let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
            var response = MediaResponse(id: input.id)
            if count == 2 { response.failure = .tooLarge }
            else { response.ocr = .init(lines: ["invalid\0text"]) }
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR, policy: policy)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let file = root.appendingPathComponent("image.png"); try Data([1]).write(to: file)
        for call in 0..<3 {
            do { _ = try await ClipboardTextRecognizer(worker: worker).recognize(file); XCTFail("Invalid input/output accepted") } catch {}
            if call < 2 { XCTAssertEqual(module.module.health.current?.state, .ready) }
        }
        try await wait { module.module.health.current?.state == .recovering }
        XCTAssertEqual(state.calls, 3)
        await registry.shutdown()
    }

    @MainActor func testManagedRealFileOCRAndExplicitCommitDoNotReplayOnRecovery() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-ocr-health-validation/helpers")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let state = ClipboardOCRHealthState()
        let worker = MediaWorker(timeout: 30, requiresLifecycle: true, run: { request, cancelled in
            _ = state.called(); var request = request
            request.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration])
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let actions = SystemClipboardContentActions(pasteboard: pasteboard, textWorker: worker)
        let action = ClipboardContentAction()
        let file = root.appendingPathComponent("private.png")
        try ClipboardTestSupport.imageData(width: 900, height: 240, text: "TYPEFLUX").write(to: file)
        var commits: [String?] = [], failures = 0
        func start() -> Bool { action.startText(url: file, actions: actions, authorized: { true },
            commit: { commits.append($0) }, failed: { failures += 1 }) }
        XCTAssertTrue(start()); try await wait(attempts: 8000) { !action.isRunning }
        XCTAssertEqual(failures, 1); XCTAssertEqual(state.calls, 0)
        try await registry.start(.clipboardOCR)
        XCTAssertEqual(state.calls, 0); XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(start()); XCTAssertFalse(start())
        try await wait(attempts: 8000) { !action.isRunning }
        XCTAssertEqual(commits.count, 1); XCTAssertTrue(commits.first.flatMap { $0 }?.uppercased().contains("TYPEFLUX") == true)
        try ClipboardTestSupport.imageData(width: 200, height: 200).write(to: file)
        XCTAssertTrue(start()); try await wait(attempts: 8000) { !action.isRunning }
        XCTAssertEqual(commits.count, 2); XCTAssertNil(commits.last.flatMap { $0 })
        try Data([1, 2]).write(to: file)
        XCTAssertTrue(start()); try await wait(attempts: 8000) { !action.isRunning }
        XCTAssertEqual(failures, 2); XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(module.module.health.current?.state, .ready)
        XCTAssertEqual(try record(root, "clipboardOCR").attempts, 1)
        let calls = state.calls
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        XCTAssertEqual(state.calls, calls); XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2]))
        await registry.shutdown()
    }

    @MainActor func testManagedLateOCRCannotCommitAfterAccountRevocationOrPermissionReplacement() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png"); try Data([1]).write(to: file)
        for accountChange in [false, true] {
            let state = ClipboardOCRHealthState(), release = DispatchSemaphore(value: 0)
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
                p.onStarted?(); _ = state.called(); release.wait(); p.onReaped?()
                let input = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(p.stdin))
                var response = MediaResponse(id: input.id); response.ocr = .init(lines: ["old private text"])
                return .init(termination: .exited(0), exitCode: 0,
                    stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
            })
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
            let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
            let pasteboard = NSPasteboard(name: .init(UUID().uuidString)); defer { pasteboard.releaseGlobally() }
            let actions = SystemClipboardContentActions(pasteboard: pasteboard, textWorker: worker)
            let action = ClipboardContentAction(); var allowed = true, commits = 0
            XCTAssertTrue(action.startText(url: file, actions: actions, authorized: { allowed }, commit: { _ in commits += 1 }, failed: {}))
            try await wait { state.calls == 1 }
            if accountChange { NotificationCenter.default.post(name: .authTokenDidRefresh, object: nil) }
            else { allowed = false; action.cancelPreparation(); allowed = true }
            XCTAssertFalse(action.startText(url: file, actions: actions, authorized: { true }, commit: { _ in commits += 1 }, failed: {}))
            release.signal(); try await wait(attempts: 8000) { !action.isRunning }
            XCTAssertEqual(commits, 0)
            await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
            XCTAssertEqual(state.calls, 1); XCTAssertEqual(commits, 0)
            action.preventNewWork(); await registry.shutdown()
        }
    }

}

private final class ClipboardOCRHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 601 } }
    var calls: Int { lock.withLock { count } }
    func called() -> Int { lock.withLock { count += 1; return count } }
}

@Suite("Clipboard OCR health presentation", .exclusiveUIState)
@MainActor struct ClipboardOCRHealthViewTests {
    @Test func independentClipboardRecoveryDoesNotCopy() async throws {
        typealias UI = SettingsBehaviorTestSupport
        try await UI.withFixture { _ in
            let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("clipboardOCR.json"))
            let worker = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
                run: { _, _ in Issue.record("Recovery must not decode"); throw MediaFailure.unavailable })
            let clock = ClipboardOCRHealthState()
            let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR, uptime: { clock.now })
            let registry = ModuleRegistry([module.registration]); _ = await registry.startAll()
            let model = ModuleHealthSettingsModel(registry: registry)
            try await UI.withWindow(ModuleHealthSettingsView(model: model), width: 640, height: 190) { _, host in
                try await UI.wait { model.health[.clipboardOCR]?.failure == .healthPersistence }
                #expect(UI.contains(L(model.featureKey(.clipboardOCR)), in: host))
                try UI.snapshot(host, name: "clipboard-ocr-health")
                let button = try #require(UI.elements(in: host).first { $0.value("accessibilityIdentifier") as? String == "settings.services.clipboardOCR.recover" })
                clock.advance()
                try button.press()
                try await UI.wait { model.health[.clipboardOCR]?.state == .ready }
            }
            model.stopObserving(); await registry.shutdown()
        }
    }
}
