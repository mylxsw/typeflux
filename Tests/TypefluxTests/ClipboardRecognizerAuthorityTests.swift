import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class RecognizerState: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata = 0, native = 0, replies = 0, mode = 0
    var counts: [Int] { lock.withLock { [metadata, native, replies] } }
    var output: Int { lock.withLock { mode } }
    func setOutput(_ value: Int) { lock.withLock { mode = value } }
    func read() { lock.withLock { metadata += 1 } }
    func run() { lock.withLock { native += 1 } }
    func replied() { lock.withLock { replies += 1 } }
}
private final class RecognizerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = 0
    var count: Int { condition.withLock { entered } }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        entered += 1
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private final class RecognizerActions: ClipboardContentActing {
    var read: (URL) async throws -> String? = { _ in nil }
    private(set) var calls = 0
    func recognizeText(in imageURL: URL) async throws -> String? { calls += 1; return try await read(imageURL) }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { Issue.record("Unexpected clipboard write"); return false }
    func sendPasteShortcut() { Issue.record("Unexpected paste") }
    func revealInFinder(_ urls: [URL]) { Issue.record("Unexpected reveal") }
    func saveToDownloads(_ url: URL) -> URL? { Issue.record("Unexpected export"); return nil }
}

@Suite("Clipboard file recognizer original authority", .exclusiveUIState)
@MainActor struct ClipboardRecognizerAuthorityTests {
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private-input")
        try Data([1, 2, 3]).write(to: url)
        return url
    }
    private func worker(_ state: RecognizerState, gate: RecognizerGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            state.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .clipboardOCR && p.timeout == 30)
            var response = MediaResponse(id: request.id)
            switch state.output {
            case 1: response.ocr = .init(lines: [" ", ""])
            case 2: response.failure = .unreadable
            default: response.ocr = .init(lines: ["owned text"])
            }
            if response.failure == nil { try response.validate(for: request) }
            let json = try JSONEncoder().encode(response)
            state.replied()
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func recognizer(_ worker: MediaWorker, _ state: RecognizerState, gate: RecognizerGate? = nil) -> ClipboardTextRecognizer {
        .init(worker: worker, readRevision: { url in
            state.read()
            let revision = try ClipboardImageRevision(url)
            gate?.wait()
            return revision
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyRetainedAndCanceledInputsCannotInspectMetadata() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), worker = worker(state), detector = recognizer(worker, state)
        let preReady = worker.authorization()
        do { _ = try await detector.recognize(url); Issue.record("Pre-ready input admitted") } catch {}
        #expect(state.counts == [0, 0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        #expect(state.counts == [0, 0, 0], "Readiness never replays OCR")
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, foreign] {
            do { _ = try await detector.recognize(url, authorization: stamp); Issue.record("Queued stamp upgraded") } catch {}
        }
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await detector.recognize(url) }
        do { _ = try await canceled.value; Issue.record("Canceled metadata read") } catch is CancellationError {}
        #expect(state.counts == [0, 0, 0])
        #expect(try await detector.recognize(url) == "owned text")
        #expect(state.counts == [1, 1, 1])
        await registry.shutdown()
    }

    @Test func heldMetadataCannotAdoptRecoveredNativeGeneration() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), worker = worker(state), gate = RecognizerGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = recognizer(worker, state, gate: gate), oldStamp = worker.authorization()
        let old = Task { try await detector.recognize(url) }
        await wait { gate.count == 1 }; #expect(worker.activeCount == 0)
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        #expect(state.counts == [1, 0, 0])
        gate.release()
        do { _ = try await old.value; Issue.record("Old metadata adopted recovery") } catch {}
        do { _ = try await detector.recognize(url, authorization: oldStamp); Issue.record("Retired stamp reused") } catch {}
        #expect(state.counts == [1, 0, 0])
        #expect(try await detector.recognize(url) == "owned text")
        #expect(state.counts == [2, 1, 1])
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func canceledMetadataRetainsBothRecognizerSlotsUntilActualReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), worker = worker(state), gate = RecognizerGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = recognizer(worker, state, gate: gate)
        let a = Task { try await detector.recognize(url) }, b = Task { try await detector.recognize(url) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        do { _ = try await detector.recognize(url); Issue.record("Metadata slots freed early") } catch {}
        #expect(state.counts == [2, 0, 0] && worker.activeCount == 0)
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Canceled metadata produced text") } catch is CancellationError {} }
        #expect(try await detector.recognize(url) == "owned text")
        #expect(state.counts == [3, 1, 1])
        await registry.shutdown()
    }

    @Test func canceledNativeWorkRetainsCapacityAndRejectsLateText() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), gate = RecognizerGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = recognizer(worker, state)
        let a = Task { try await detector.recognize(url) }, b = Task { try await detector.recognize(url) }
        await wait { gate.count == 2 }; a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await detector.recognize(url); Issue.record("Native slots freed early") } catch {}
        #expect(state.counts == [2, 2, 0])
        gate.release()
        for task in [a, b] { do { _ = try await task.value; Issue.record("Late canceled text") } catch {} }
        #expect(worker.activeCount == 0 && state.counts == [2, 2, 2])
        #expect(try await detector.recognize(url) == "owned text")
        #expect(state.counts == [3, 3, 3])
        await registry.shutdown()
    }

    @Test func validLateNativeReplyAfterRevocationCannotReturnText() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), gate = RecognizerGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = recognizer(worker, state)
        let old = Task { try await detector.recognize(url) }
        await wait { gate.count == 1 }; module.module.supervisor.admission.setEnabled(false)
        gate.release()
        do { _ = try await old.value; Issue.record("Revoked source returned native text") } catch {}
        #expect(state.counts == [1, 1, 1] && worker.activeCount == 0)
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        #expect(state.counts == [1, 1, 1])
        #expect(try await detector.recognize(url) == "owned text")
        await registry.shutdown()
    }

    @Test func actualActionWithFakeActionsDoesNotCommitOrReplayRevokedRecognition() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), worker = worker(state), gate = RecognizerGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = recognizer(worker, state, gate: gate), action = ClipboardContentAction(), actions = RecognizerActions()
        actions.read = { try await detector.recognize($0) }
        var commits = 0, failures = 0, value: String?
        func start() -> Bool {
            action.startText(url: url, actions: actions, authorized: { true }, commit: { value = $0; commits += 1 }, failed: { failures += 1 })
        }
        #expect(start())
        await wait { gate.count == 1 }
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        gate.release(); await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && actions.calls == 1 && state.counts == [1, 0, 0])
        #expect(start()); #expect(!start())
        await wait { !action.isRunning }
        #expect(commits == 1 && failures == 1 && actions.calls == 2 && value == "owned text" && state.counts == [2, 1, 1])
        action.preventNewWork(); await registry.shutdown()
    }

    @Test func blankIsNilAndControlledRefusalDoesNotPoisonNativeHealth() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = RecognizerState(), worker = worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let detector = ClipboardTextRecognizer(worker: worker), original = module.module.health.current?.generation
        state.setOutput(1); #expect(try await detector.recognize(url) == nil)
        state.setOutput(2)
        do { _ = try await detector.recognize(url); Issue.record("Refusal became blank") }
        catch { #expect(error as? MediaFailure == .unreadable) }
        #expect(module.module.health.current?.state == .ready && module.module.health.current?.generation == original)
        state.setOutput(0); #expect(try await detector.recognize(url) == "owned text")
        #expect(state.counts == [0, 3, 3])
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        await registry.shutdown()
    }
}
