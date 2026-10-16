import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

// A JPEG envelope for the pure IPC validator only, never entropy-decoded.
private let attachmentEnvelope = Data([255, 216, 255, 192, 0, 11, 8, 0, 2, 0, 2, 1, 1, 17, 0,
    255, 218, 0, 8, 1, 1, 0, 0, 63, 0, 0, 255, 217])
private final class AttachmentAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var native = 0, replies = 0, reads = 0, canceled = false
    var counts: [Int] { lock.withLock { [native, replies, reads] } }
    var isCanceled: Bool { lock.withLock { canceled } }
    func cancel() { lock.withLock { canceled = true } }
    func entered() { lock.withLock { native += 1 } }
    func returned() { lock.withLock { replies += 1 } }
    func read() { lock.withLock { reads += 1 } }
}
private final class AttachmentAuthorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = 0
    var count: Int { condition.withLock { entered } }
    func wait() {
        condition.lock(); defer { condition.unlock() }; entered += 1
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Attachment batch original native authority", .exclusiveUIState)
@MainActor struct AttachmentBatchAuthorityTests {
    private func worker(_ state: AttachmentAuthorityState, gate: AttachmentAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.entered(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            if request.operation == .pdf { response.items = [.init(text: "private PDF text", pages: 2)] }
            else {
                #expect(request.operation == .image)
                response.items = [.init(image: "data:image/jpeg;base64," + attachmentEnvelope.base64EncodedString())]
            }
            try response.validate(for: request); state.returned()
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func file(_ root: URL, _ name: String, data: Data = Data([1, 2, 3])) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func wait(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyBatchRetainsTextAndFoldersWithoutReadinessReplay() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = try file(root, "notes.txt", data: Data("abc".utf8)), pdf = try file(root, "private.pdf")
        let state = AttachmentAuthorityState(), worker = worker(state), original = worker.authorization()
        let sources: [AskAttachmentSource] = [.image(Data([1]), name: "image"), .file(text), .file(root), .file(pdf)]
        let before = AskAttachmentBatch.load(sources, worker: worker)
        #expect(before.items.map(\.kind) == [.file, .folder] && before.items.first?.text == "abc")
        #expect(before.failure == .unreadable("image") && state.counts == [0, 0, 0])
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        #expect(state.counts == [0, 0, 0], "Readiness cannot replay attachments")
        let queued = Task.detached { AskAttachmentBatch.load(sources, worker: worker, authorization: original) }
        let old = await queued.value
        #expect(old.items.map(\.kind) == [.file, .folder] && state.counts == [0, 0, 0])
        let fresh = AskAttachmentBatch.load(sources, worker: worker)
        #expect(fresh.items.map(\.kind) == [.image, .file, .folder, .file] && fresh.failure == nil)
        #expect(fresh.items.last?.pages == 2 && fresh.items.last?.text == "private PDF text")
        #expect(state.counts == [2, 2, 0])
        await registry.shutdown()
    }

    @Test(arguments: ["png", "pdf"])
    func betweenCompletedNativeAndNextMetadataCannotAdoptRecovery(_ ext: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try file(root, "second." + ext), text = try file(root, "tail.txt", data: Data("tail".utf8))
        let state = AttachmentAuthorityState(), worker = worker(state), gate = AttachmentAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        let sources: [AskAttachmentSource] = [.image(Data([1]), name: "first"), .file(second), .file(text)]
        let read: AskAttachmentLoader.MetadataReader = { url in
            state.read(); let values = try AskAttachmentLoader.metadata(url)
            if url == second { gate.wait() }
            return values
        }
        let old = Task.detached { AskAttachmentBatch.load(sources, worker: worker, readMetadata: read) }
        await wait { gate.count == 1 }
        #expect(state.counts == [1, 1, 1] && worker.activeCount == 0)
        await registry.disable(.mediaExtraction); try await registry.start(.mediaExtraction)
        #expect(state.counts == [1, 1, 1])
        gate.release(); let result = await old.value
        #expect(result.items.map(\.name) == ["first", "tail.txt"] && result.items.first?.image != nil)
        #expect(result.failure == .unreadable(second.lastPathComponent) && state.counts == [1, 1, 2])
        let fresh = AskAttachmentBatch.load(sources, worker: worker)
        #expect(fresh.items.count == 3 && fresh.failure == nil && state.counts == [3, 3, 2])
        #expect(try Data(contentsOf: second) == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func directFileCapturesBeforeMetadataAndExplicitStampsNeverUpgrade() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root, "single.png"), pdf = try file(root, "direct.pdf")
        let state = AttachmentAuthorityState(), worker = worker(state), gate = AttachmentAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        let original = worker.authorization()
        let old = Task.detached { try AskAttachmentLoader.file(url, worker: worker, readMetadata: { url in
            let values = try AskAttachmentLoader.metadata(url); gate.wait(); return values
        }) }
        await wait { gate.count == 1 }; #expect(state.counts == [0, 0, 0])
        await registry.disable(.mediaExtraction); try await registry.start(.mediaExtraction)
        gate.release()
        do { _ = try await old.value; Issue.record("File metadata adopted recovery") } catch {}
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [original, foreign] {
            do { _ = try AskAttachmentLoader.image(data: Data([1]), name: "old", byteSize: 1, worker: worker, authorization: stamp); Issue.record("Old image stamp upgraded") } catch {}
            do { _ = try AskAttachmentLoader.pdf(pdf, name: "old", byteSize: 3, worker: worker, authorization: stamp); Issue.record("Old PDF stamp upgraded") } catch {}
        }
        #expect(state.counts == [0, 0, 0])
        #expect(try AskAttachmentLoader.load(.file(url), worker: worker).first?.kind == .image)
        #expect(try AskAttachmentLoader.pdf(pdf, name: "direct", byteSize: 3, worker: worker).first?.pages == 2)
        await registry.shutdown()
    }

    @Test func canceledUncooperativeBatchesRetainNativeAndOwnerOccupancyUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AttachmentAuthorityState(), gate = AttachmentAuthorityGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        let owner = AskAttachmentWork(), ids = [UUID(), UUID()]
        let tasks = ids.map { id in
            let task = Task.detached { AskAttachmentBatch.load([.image(Data([1]), name: "held")], worker: worker, isCancelled: { Task.isCancelled }) }
            owner.insert(id, launcher: false, cancel: { task.cancel() }); return task
        }
        await wait { gate.count == 2 }; owner.cancel()
        #expect(owner.count == 2 && worker.activeCount == 2)
        let refused = AskAttachmentBatch.load([.image(Data([1]), name: "third")], worker: worker)
        #expect(refused.items.isEmpty && refused.failure == .unreadable("third") && state.counts == [2, 0, 0])
        gate.release()
        for (id, task) in zip(ids, tasks) {
            let result = await task.value; #expect(result.items.isEmpty); #expect(!owner.remove(id))
        }
        #expect(owner.count == 0 && worker.activeCount == 0 && state.counts == [2, 2, 0])
        #expect(AskAttachmentBatch.load([.image(Data([1]), name: "fresh")], worker: worker).items.count == 1)
        await registry.shutdown()
    }

    @Test func validNativeReplyAfterOriginalRevocationCannotEnterPartialBatch() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = try file(root, "tail.txt", data: Data("kept".utf8))
        let state = AttachmentAuthorityState(), gate = AttachmentAuthorityGate(), worker = worker(state, gate: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        let old = Task.detached { AskAttachmentBatch.load([.image(Data([1]), name: "old"), .file(text)], worker: worker) }
        await wait { gate.count == 1 }; module.module.supervisor.admission.setEnabled(false)
        gate.release(); let result = await old.value
        #expect(result.items.map(\.text) == ["kept"] && result.failure == .unreadable("old"))
        #expect(state.counts == [1, 1, 0] && worker.activeCount == 0)
        await registry.disable(.mediaExtraction); try await registry.start(.mediaExtraction)
        #expect(state.counts == [1, 1, 0])
        #expect(AskAttachmentBatch.load([.image(Data([1]), name: "fresh")], worker: worker).failure == nil)
        await registry.shutdown()
    }

    @Test func cancellationMetadataErrorsAndBatchOutputBoundsRemainIndependent() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root, "private.txt", data: Data("abc".utf8)), state = AttachmentAuthorityState(), worker = worker(state)
        let read: AskAttachmentLoader.MetadataReader = { url in state.read(); return try AskAttachmentLoader.metadata(url) }
        let canceled = AskAttachmentBatch.load([.file(url)], worker: worker, readMetadata: read, isCancelled: { true })
        #expect(canceled.items.isEmpty && state.counts == [0, 0, 0])
        do { _ = try AskAttachmentLoader.file(url, worker: worker, readMetadata: read, isCancelled: { true }); Issue.record("Precanceled metadata") } catch is CancellationError {}
        do {
            _ = try AskAttachmentLoader.file(url, worker: worker, readMetadata: { url in state.cancel(); return try read(url) }, isCancelled: { state.isCanceled })
            Issue.record("Canceled metadata returned text")
        } catch is CancellationError {}
        #expect(state.counts == [0, 0, 1])
        let missing = AskAttachmentBatch.load([.file(root.appendingPathComponent("absent.txt"))], worker: worker)
        #expect(missing.failure == .unreadable("absent.txt"))
        let unknown = AskAttachmentBatch.load([.file(root.appendingPathComponent("unknown.unrecognized")), .file(url)], worker: worker)
        #expect(unknown.failure == .unsupported("unknown.unrecognized") && unknown.items.first?.text == "abc")
        let module = MediaExtractionModule(worker: worker, healthDirectory: root)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaExtraction)
        let many = AskAttachmentBatch.load(Array(repeating: .image(Data([1]), name: "image"), count: 9), worker: worker)
        #expect(many.items.count == 8 && many.failure == .tooManyImages)
        await registry.shutdown()
    }
}
