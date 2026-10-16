import Darwin
import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private let imageActionPNG = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
private final class ImageActionState: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, calls = 0, replies = 0
    var counts: [Int] { lock.withLock { [reads, calls, replies] } }
    func read() { lock.withLock { reads += 1 } }
    func enter() { lock.withLock { calls += 1 } }
    func reply() { lock.withLock { replies += 1 } }
}
private final class ImageActionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() { condition.lock(); defer { condition.unlock() }; while held { condition.wait() } }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}
private final class BoundImageActions: ClipboardContentActing {
    var bindings = 0, writes = 0, pastes = 0
    var pasteboardRevision: Int? = 1
    var received: AskWorkflowImage.Clipboard?
    var onWrite: () -> Void = {}
    var succeeds = true
    let worker: MediaWorker
    let read: @Sendable (URL) throws -> Data
    init(_ worker: MediaWorker, read: @escaping @Sendable (URL) throws -> Data) { self.worker = worker; self.read = read }
    @MainActor func imagePreparation(for entry: ClipboardEntry) -> ClipboardImagePreparation {
        bindings += 1
        // Same production factory; no System object, pasteboard or Downloads owner.
        return .make(for: entry, worker: worker, readSource: read)
    }
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard? {
        Issue.record("Queued action recaptured preparation"); return nil
    }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool {
        writes += 1; received = image; onWrite(); return succeeds
    }
    func sendPasteShortcut() { pastes += 1 }
    func revealInFinder(_ urls: [URL]) { Issue.record("Unexpected reveal") }
    func saveToDownloads(_ url: URL) -> URL? { Issue.record("Unexpected export"); return nil }
    func recognizeText(in imageURL: URL) async throws -> String? { Issue.record("Unexpected OCR"); return nil }
}
private actor IndependentImagePreparation {
    var calls = 0
    func prepare() -> AskWorkflowImage.Clipboard? { calls += 1; return nil }
}
private final class IndependentImageActions: ClipboardContentActing {
    let owner = IndependentImagePreparation()
    var writes = 0
    func prepareImage(_ entry: ClipboardEntry) async throws -> AskWorkflowImage.Clipboard? { await owner.prepare() }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { writes += 1; return true }
    func sendPasteShortcut() {}
    func revealInFinder(_ urls: [URL]) {}
    func saveToDownloads(_ url: URL) -> URL? { nil }
    func recognizeText(in imageURL: URL) async throws -> String? { nil }
}

@Suite("Explicit clipboard image request authority", .exclusiveUIState)
@MainActor struct ClipboardImageActionAuthorityTests {
    private func worker(_ state: ImageActionState, gate: ImageActionGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.enter(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            #expect(request.operation == .copyClipboardImage)
            let directory = AskSecureDirectory(descriptor: dup(p.directoryDescriptor))
            let tiff = Data([0x49, 0x49, 42, 0])
            try directory.createFile("clipboard-png", data: imageActionPNG)
            try directory.createFile("clipboard-tiff", data: tiff)
            var metadata = MediaWorkflowImage(format: .png, width: 2, height: 2, scale: 1)
            metadata.pngBytes = imageActionPNG.count; metadata.tiffBytes = tiff.count
            var response = MediaResponse(id: request.id); response.workflowImage = metadata
            try response.validate(for: request); state.reply()
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func entry(_ root: URL) throws -> ClipboardEntry {
        let url = root.appendingPathComponent("private.png"); try imageActionPNG.write(to: url)
        return ClipboardTestSupport.entry(.image, imagePath: url.path)
    }
    private func actions(_ worker: MediaWorker, _ state: ImageActionState, gate: ImageActionGate? = nil) -> BoundImageActions {
        BoundImageActions(worker, read: { url in
            state.read(); gate?.wait(); return try AskWorkflowImage.read(url)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyRequestBindsSynchronouslyAndNeverReplaysOnReadiness() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try entry(root), state = ImageActionState(), worker = worker(state), sink = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]), action = ClipboardContentAction(); var failures = 0
        func start() -> Bool { action.start(entry: entry, plainText: false, paste: false, actions: sink,
            authorized: { true }, failed: { failures += 1 }) }
        #expect(start()); #expect(sink.bindings == 1 && action.isRunning)
        try await registry.start(.mediaPreviews); await wait { !action.isRunning }
        #expect(state.counts == [0, 0, 0] && sink.writes == 0 && failures == 1 && sink.bindings == 1)
        #expect(start()); await wait { !action.isRunning }
        #expect(state.counts == [1, 1, 1] && sink.writes == 1 && failures == 1)
        #expect(sink.received?.png == imageActionPNG && sink.received?.tiff.count == 4)
        #expect(sink.received?.sourceRevision?.matches(URL(fileURLWithPath: entry.imagePath!)) == true)
        await registry.shutdown()
    }

    @Test func acceptedReadyRequestCannotUpgradeBeforeItsQueuedPreparation() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try entry(root), state = ImageActionState(), worker = worker(state), sink = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let action = ClipboardContentAction(); var failures = 0
        func start() -> Bool { action.start(entry: entry, plainText: false, paste: false, actions: sink,
            authorized: { true }, failed: { failures += 1 }) }
        #expect(start()); #expect(sink.bindings == 1)
        // Same MainActor turn, before the queued task can read or enter native work.
        module.module.supervisor.admission.setEnabled(false)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        await wait { !action.isRunning }
        #expect(state.counts == [0, 0, 0] && sink.writes == 0 && failures == 1)
        #expect(start()); await wait { !action.isRunning }
        #expect(state.counts == [1, 1, 1] && sink.writes == 1 && sink.bindings == 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: entry.imagePath!)) == imageActionPNG)
        await registry.shutdown()
    }

    @Test func finalPermissionCallbackCannotBlessRetiredValidPreparation() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try entry(root), state = ImageActionState(), worker = worker(state), sink = actions(worker, state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let action = ClipboardContentAction(), original = worker.authorization(); var checks = 0, failures = 0
        let accepted = action.start(entry: entry, plainText: false, paste: true, actions: sink, authorized: { true }, beforeCommit: {
            checks += 1
            if checks == 2 {
                #expect(state.counts == [1, 1, 1] && worker.activeCount == 0 && worker.permits(original))
                module.module.supervisor.admission.setEnabled(false)
            }
            return true
        }, failed: { failures += 1 })
        #expect(accepted); await wait { !action.isRunning }
        #expect(sink.writes == 0 && sink.pastes == 0 && failures == 1)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(sink.bindings == 1 && sink.writes == 0)
        await registry.shutdown()
    }

    @Test(arguments: [false, true]) func canceledPreparationKeepsAdmissionUntilActualReturn(_ native: Bool) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try entry(root), state = ImageActionState(), gate = ImageActionGate()
        defer { gate.release() }
        let worker = worker(state, gate: native ? gate : nil), sink = actions(worker, state, gate: native ? nil : gate)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let action = ClipboardContentAction(); var failures = 0
        func start() -> Bool { action.start(entry: entry, plainText: false, paste: false, actions: sink,
            authorized: { true }, failed: { failures += 1 }) }
        #expect(start()); await wait { state.counts[native ? 1 : 0] == 1 }
        action.cancel(); #expect(!start() && action.isRunning && sink.bindings == 1)
        #expect(worker.activeCount == (native ? 1 : 0))
        gate.release(); await wait { !action.isRunning }
        #expect(sink.writes == 0 && failures == 0 && worker.activeCount == 0)
        #expect(start()); await wait { !action.isRunning }
        #expect(sink.writes == 1 && sink.bindings == 2)
        await registry.shutdown()
    }

    @Test func fileListsAndNonimagesStayIndependentOfNativeHealth() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageActionState(), worker = worker(state), sink = actions(worker, state)
        #expect(!worker.permits(worker.authorization()))
        for entry in [ClipboardTestSupport.entry(.files, filePaths: [root.path]), ClipboardTestSupport.entry(.image)] {
            let action = ClipboardContentAction(); var commits = 0
            #expect(action.start(entry: entry, plainText: true, paste: true, actions: sink,
                authorized: { true }, committed: { commits += 1; action.cancelPreparation() }, delay: {}))
            await wait { !action.isRunning }
            #expect(commits == 1 && sink.received == nil)
        }
        #expect(sink.writes == 2 && sink.pastes == 2 && state.counts == [0, 0, 0])
        let independent = IndependentImageActions(), action = ClipboardContentAction()
        #expect(action.start(entry: ClipboardTestSupport.entry(.image, imagePath: "/custom-owned"),
            plainText: false, paste: false, actions: independent, authorized: { true }))
        await wait { !action.isRunning }
        #expect(await independent.owner.calls == 1 && independent.writes == 1 && state.counts == [0, 0, 0])
    }

    @Test func canceledCallbacksCannotAdmitWritesOrRestoreEnteredWriteUI() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageActionState(), worker = worker(state)
        for stage in ["entry", "terminal", "write", "failure"] {
            let action = ClipboardContentAction(), sink = actions(worker, state); var checks = 0, failures = 0, commits = 0
            sink.succeeds = stage != "failure"
            if stage == "write" { sink.onWrite = { action.cancel() } }
            let accepted = action.start(entry: ClipboardTestSupport.entry(.files, filePaths: [root.path]), plainText: false,
                paste: true, actions: sink, authorized: { true }, beforeCommit: {
                    checks += 1
                    if (stage == "entry" && checks == 1) || (stage == "terminal" && checks == 2) { action.cancel() }
                    return true
                }, committed: { commits += 1 }, failed: { failures += 1 }, delay: {})
            #expect(accepted == (stage != "entry")); await wait { !action.isRunning }
            #expect(sink.writes == (["write", "failure"].contains(stage) ? 1 : 0))
            #expect(commits == 0 && sink.pastes == 0 && failures == (stage == "failure" ? 1 : 0))
        }
    }

    @Test func deniedAndPreCanceledEntriesNeverBindOrPrepare() async throws {
        let state = ImageActionState(), worker = worker(state), sink = actions(worker, state), action = ClipboardContentAction()
        let entry = ClipboardTestSupport.entry(.image, imagePath: "/never-read")
        #expect(!action.start(entry: entry, plainText: false, paste: false, actions: sink, authorized: { false }))
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return action.start(entry: entry, plainText: false, paste: false, actions: sink, authorized: { true })
        }
        #expect(await pending.value == false)
        #expect(sink.bindings == 0 && state.counts == [0, 0, 0] && !action.isRunning)
    }
}
