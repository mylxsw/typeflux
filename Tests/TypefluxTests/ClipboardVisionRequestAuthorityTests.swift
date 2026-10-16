import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class VisionRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, calls = 0, replies = 0, empty = false
    var counts: [Int] { lock.withLock { [reads, calls, replies] } }
    var blank: Bool { lock.withLock { empty } }
    func setBlank() { lock.withLock { empty = true } }
    func read() { lock.withLock { reads += 1 } }
    func enter() { lock.withLock { calls += 1 } }
    func reply() { lock.withLock { replies += 1 } }
}
private final class VisionRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() { condition.lock(); defer { condition.unlock() }; while held { condition.wait() } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private final class VisionRequestActions: ClipboardContentActing {
    let recognizer: VisionImageTextRecognizer
    let unrelated: MediaWorker
    var bindings = 0
    init(_ recognizer: VisionImageTextRecognizer) {
        self.recognizer = recognizer
        unrelated = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true,
            run: { _, _ in Issue.record("Native injection incorrectly used clipboardOCR worker"); throw MediaFailure.unavailable })
    }
    @MainActor func textRecognition(in url: URL) -> ClipboardTextRecognition {
        bindings += 1
        // Exact production factory and injected native type, without a System/pasteboard owner.
        return .make(in: url, worker: unrelated, textRecognizer: recognizer)
    }
    func recognizeText(in imageURL: URL) async throws -> String? { Issue.record("Late unbound entry"); return nil }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { Issue.record("Unexpected image write"); return false }
    func sendPasteShortcut() { Issue.record("Unexpected paste") }
    func revealInFinder(_ urls: [URL]) { Issue.record("Unexpected reveal") }
    func saveToDownloads(_ url: URL) -> URL? { Issue.record("Unexpected export"); return nil }
}

@Suite("Injected native clipboard OCR request authority", .exclusiveUIState)
@MainActor struct ClipboardVisionRequestAuthorityTests {
    private let text = "😀 a@example.com"
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private-input"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func worker(_ state: VisionRequestState, gate: VisionRequestGate? = nil) -> MediaWorker {
        let text = self.text
        return MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30, requiresLifecycle: true, run: { p, _ in
            state.enter(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .recognizeText && request.textInput == nil && p.timeout == 30)
            let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1)
            var response = MediaResponse(id: request.id)
            response.recognition = .init(lines: state.blank ? [] : [.init(text: text, confidence: 0.9, box: box,
                regions: [.init(kind: .email, range: .init(location: 3, length: 13), box: box)])])
            try response.validate(for: request); state.reply()
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func actions(_ worker: MediaWorker, _ state: VisionRequestState, gate: VisionRequestGate? = nil) -> VisionRequestActions {
        .init(.init(worker: worker, readRevision: { url in
            state.read(); let revision = try ClipboardImageRevision(url); gate?.wait(); return revision
        }))
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyInjectedNativeRequestCannotUpgradeWhenRegistryStarts() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), worker = worker(state), actions = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]), action = ClipboardContentAction(); var values: [String?] = [], failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }) }
        #expect(start()); #expect(actions.bindings == 1 && action.isRunning)
        try await registry.start(.textRecognition); await wait { !action.isRunning }
        #expect(state.counts == [0, 0, 0] && values.isEmpty && failures == 1 && actions.bindings == 1)
        #expect(!actions.unrelated.permits(actions.unrelated.authorization()))
        #expect(start()); await wait { !action.isRunning }
        #expect(values == [text] && state.counts == [1, 1, 1] && actions.bindings == 2)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func readyRequestRetainsOriginalNativeGenerationBeforeQueuedEntry() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), worker = worker(state), actions = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let action = ClipboardContentAction(); var values: [String?] = [], failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }) }
        #expect(start()); #expect(actions.bindings == 1)
        // Synchronous revocation in the accepting MainActor turn, before the queued task.
        module.module.supervisor.admission.setEnabled(false)
        await registry.disable(.textRecognition); try await registry.start(.textRecognition)
        await wait { !action.isRunning }
        #expect(state.counts == [0, 0, 0] && values.isEmpty && failures == 1 && actions.bindings == 1)
        #expect(start()); await wait { !action.isRunning }
        #expect(values == [text] && state.counts == [1, 1, 1] && actions.bindings == 2)
        await registry.shutdown()
    }

    @Test func validRecognitionCannotCommitAfterFinalPermissionRevokesOriginalNativeGrant() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), worker = worker(state), actions = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let original = worker.authorization(), action = ClipboardContentAction(); var checks = 0, commits = 0, failures = 0
        let accepted = action.startText(url: url, actions: actions, authorized: {
            checks += 1
            if checks == 2 {
                #expect(state.counts == [1, 1, 1] && worker.activeCount == 0 && worker.permits(original))
                module.module.supervisor.admission.setEnabled(false)
            }
            return true
        }, commit: { _ in commits += 1 }, failed: { failures += 1 })
        #expect(accepted); await wait { !action.isRunning }
        #expect(commits == 0 && failures == 1 && actions.bindings == 1)
        await registry.disable(.textRecognition); try await registry.start(.textRecognition)
        #expect(commits == 0 && state.counts == [1, 1, 1])
        await registry.shutdown()
    }

    @Test(arguments: [false, true]) func canceledPreparationOrNativeRetainsBothSlotsUntilPhysicalReturn(_ native: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), gate = VisionRequestGate(); defer { gate.release() }
        let worker = worker(state, gate: native ? gate : nil), actions = actions(worker, state, gate: native ? nil : gate)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let owners = [ClipboardContentAction(), ClipboardContentAction()]; var values: [String?] = [], failures = 0
        func start(_ owner: ClipboardContentAction) -> Bool { owner.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }) }
        for owner in owners { #expect(start(owner)) }
        await wait { state.counts[native ? 1 : 0] == 2 }
        for owner in owners { owner.cancel(); #expect(!start(owner) && owner.isRunning) }
        #expect(worker.activeCount == (native ? 2 : 0))
        let third = ClipboardContentAction(); #expect(start(third)); await wait { !third.isRunning }
        #expect(state.counts[0] == 2 && failures == 1 && values.isEmpty)
        gate.release(); await wait { owners.allSatisfy { !$0.isRunning } }
        #expect(worker.activeCount == 0 && values.isEmpty && failures == 1)
        #expect(start(third)); await wait { !third.isRunning }
        #expect(values == [text])
        await registry.shutdown()
    }

    @Test func originalSourceAndAccountStillFenceCompletedRecognitionAndBlankRemainsNil() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), worker = worker(state), actions = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        for account in [false, true] {
            let action = ClipboardContentAction(); var checks = 0, values: [String?] = [], failures = 0
            let accepted = action.startText(url: url, actions: actions, authorized: {
                checks += 1
                if checks == 2 {
                    if account { return false }
                    try? Data([9]).write(to: url, options: .atomic)
                }
                return true
            }, commit: { values.append($0) }, failed: { failures += 1 })
            #expect(accepted); await wait { !action.isRunning }
            #expect(values.isEmpty && failures == (account ? 0 : 1))
            try Data([1, 2, 3]).write(to: url)
        }
        state.setBlank()
        let action = ClipboardContentAction(); var values: [String?] = [], failures = 0
        #expect(action.startText(url: url, actions: actions, authorized: { true },
            commit: { values.append($0) }, failed: { failures += 1 }))
        await wait { !action.isRunning }
        #expect(values.count == 1 && values[0] == nil && failures == 0 && state.counts == [3, 3, 3])
        await registry.shutdown()
    }

    @Test func accountNotificationCancelsHeldNativeWithoutReplayOrEarlyAdmissionRelease() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = VisionRequestState(), gate = VisionRequestGate(); defer { gate.release() }
        let worker = worker(state, gate: gate), actions = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .textRecognition)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.textRecognition)
        let action = ClipboardContentAction(); var commits = 0, failures = 0
        func start() -> Bool { action.startText(url: url, actions: actions, authorized: { true },
            commit: { _ in commits += 1 }, failed: { failures += 1 }) }
        #expect(start()); await wait { state.counts[1] == 1 }
        NotificationCenter.default.post(name: .authDidLogout, object: nil)
        #expect(action.isRunning && !start() && worker.activeCount == 1)
        gate.release(); await wait { !action.isRunning }
        #expect(commits == 0 && failures == 0 && worker.activeCount == 0 && actions.bindings == 1)
        #expect(start()); await wait { !action.isRunning }
        #expect(commits == 1 && state.counts == [2, 2, 2] && actions.bindings == 2)
        await registry.shutdown()
    }
}
