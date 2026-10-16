import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class ActionOCRState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0, replies = 0
    var counts: [Int] { lock.withLock { [calls, replies] } }
    func entered() { lock.withLock { calls += 1 } }
    func returned() { lock.withLock { replies += 1 } }
}
private final class ActionOCRGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() { condition.lock(); defer { condition.unlock() }; while held { condition.wait() } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private final class BoundOCRActions: ClipboardContentActing {
    let worker: MediaWorker
    var custom: (any ImageTextRecognizing)?
    var bindings = 0
    init(_ worker: MediaWorker) { self.worker = worker }
    @MainActor func textRecognition(in url: URL) -> ClipboardTextRecognition {
        bindings += 1
        // The exact production factory, without constructing a pasteboard/Downloads owner.
        return .make(in: url, worker: worker, textRecognizer: custom)
    }
    func recognizeText(in imageURL: URL) async throws -> String? { Issue.record("Late entry used instead of bound request"); return nil }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { Issue.record("Unexpected image write"); return false }
    func sendPasteShortcut() { Issue.record("Unexpected paste") }
    func revealInFinder(_ urls: [URL]) { Issue.record("Unexpected reveal") }
    func saveToDownloads(_ url: URL) -> URL? { Issue.record("Unexpected export"); return nil }
}
private actor ActionActorRecognizer: ImageTextRecognizing {
    var calls = 0
    let lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func recognizeText(in source: ImageTextSource) async throws -> RecognizedText {
        calls += 1
        return .init(lines: lines.map { .init(text: $0, confidence: 1, boundingBox: .zero) })
    }
}

@Suite("Explicit clipboard OCR request authority", .exclusiveUIState)
@MainActor struct ClipboardActionAuthorityTests {
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private-input"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func worker(_ state: ActionOCRState, gate: ActionOCRGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            state.entered(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .clipboardOCR && p.timeout == 30)
            var response = MediaResponse(id: request.id); response.ocr = .init(lines: ["owned text"])
            try response.validate(for: request)
            state.returned()
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyActionBindsBeforeTaskAndNeverReplaysWhenReady() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = ActionOCRState(), worker = worker(state), actions = BoundOCRActions(worker)
        let action = ClipboardContentAction(), module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); var commits = 0, failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true }, commit: { _ in commits += 1 }, failed: { failures += 1 }) }
        #expect(start()); #expect(actions.bindings == 1 && action.isRunning)
        try await registry.start(.clipboardOCR)
        await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && state.counts == [0, 0])
        #expect(actions.bindings == 1, "Readiness cannot create a new request")
        #expect(start()); await wait { !action.isRunning }
        #expect(commits == 1 && failures == 1 && state.counts == [1, 1] && actions.bindings == 2)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func readyActionCannotRecaptureAfterSynchronousRevocation() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = ActionOCRState(), worker = worker(state), actions = BoundOCRActions(worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let action = ClipboardContentAction(); var commits = 0, failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true }, commit: { _ in commits += 1 }, failed: { failures += 1 }) }
        #expect(start()); #expect(actions.bindings == 1)
        // Same MainActor turn: no queued preparation has run yet.
        module.module.supervisor.admission.setEnabled(false)
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && state.counts == [0, 0])
        #expect(start()); await wait { !action.isRunning }
        #expect(commits == 1 && actions.bindings == 2 && state.counts == [1, 1])
        await registry.shutdown()
    }

    @Test func finalSourceAuthorizationCannotBlessRetiredValidText() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = ActionOCRState(), worker = worker(state), actions = BoundOCRActions(worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let original = worker.authorization(), action = ClipboardContentAction(); var checks = 0, commits = 0, failures = 0
        let accepted = action.startText(url: url, actions: actions, authorized: {
            checks += 1
            if checks == 2 {
                #expect(state.counts == [1, 1] && worker.activeCount == 0 && worker.permits(original))
                module.module.supervisor.admission.setEnabled(false)
            }
            return true
        }, commit: { _ in commits += 1 }, failed: { failures += 1 })
        #expect(accepted)
        await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && state.counts == [1, 1])
        await registry.disable(.clipboardOCR); try await registry.start(.clipboardOCR)
        #expect(commits == 0 && actions.bindings == 1)
        await registry.shutdown()
    }

    @Test func canceledEnteredNativeKeepsActionSlotUntilPhysicalCollection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = ActionOCRState(), gate = ActionOCRGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let actions = BoundOCRActions(worker), module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let action = ClipboardContentAction(); var commits = 0, failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true }, commit: { _ in commits += 1 }, failed: { failures += 1 }) }
        #expect(start()); await wait { state.counts[0] == 1 }
        action.cancel(); #expect(!start())
        #expect(action.isRunning && worker.activeCount == 1 && actions.bindings == 1)
        gate.release(); await wait { !action.isRunning }
        #expect(commits == 0 && failures == 0 && worker.activeCount == 0 && state.counts == [1, 1])
        #expect(start()); #expect(!start()); await wait { !action.isRunning }
        #expect(commits == 1 && failures == 0 && actions.bindings == 2 && state.counts == [2, 2])
        action.preventNewWork(); #expect(!start())
        await registry.shutdown()
    }

    @Test func customActorFactoryRemainsIndependentAndBlankCommitsOnce() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = ActionOCRState(), worker = worker(state), actions = BoundOCRActions(worker)
        #expect(!worker.permits(worker.authorization()))
        for lines in [["custom"], []] {
            let custom = ActionActorRecognizer(lines); actions.custom = custom
            let action = ClipboardContentAction(); var values: [String?] = [], failures = 0
            #expect(action.startText(url: url, actions: actions, authorized: { true }, commit: { values.append($0) }, failed: { failures += 1 }))
            await wait { !action.isRunning }
            #expect(values.count == 1 && values[0] == lines.first && failures == 0)
            #expect(await custom.calls == 1)
        }
        #expect(state.counts == [0, 0])
    }

    @Test func deniedOrMissingSourceCannotDispatchNativeOrCommit() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ActionOCRState(), worker = worker(state), actions = BoundOCRActions(worker), action = ClipboardContentAction()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardOCR)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardOCR)
        let url = root.appendingPathComponent("missing"); var commits = 0, failures = 0
        #expect(!action.startText(url: url, actions: actions, authorized: { false }, commit: { _ in commits += 1 }, failed: { failures += 1 }))
        #expect(actions.bindings == 0)
        #expect(action.startText(url: url, actions: actions, authorized: { true }, commit: { _ in commits += 1 }, failed: { failures += 1 }))
        await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && state.counts == [0, 0])
        await registry.shutdown()
    }
}
