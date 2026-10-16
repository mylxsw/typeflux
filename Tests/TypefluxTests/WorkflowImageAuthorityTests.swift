import Darwin
import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private let workflowAuthorityPNG = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
private final class WorkflowAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, reads = 0, hashes = 0
    var counts: [Int] { lock.withLock { [runs, reads, hashes] } }
    func run() { lock.withLock { runs += 1 } }
    @discardableResult func read() -> Int { lock.withLock { reads += 1; return reads } }
    func hash() { lock.withLock { hashes += 1 } }
}
private final class WorkflowAuthorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Workflow image original consumer authority", .serialized)
@MainActor struct WorkflowImageAuthorityTests {
    private func file(_ root: URL) throws -> URL {
        let file = root.appendingPathComponent("private.bytes"); try workflowAuthorityPNG.write(to: file); return file
    }
    private func worker(_ state: WorkflowAuthorityState) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let directory = AskSecureDirectory(descriptor: dup(p.directoryDescriptor))
            var response = MediaResponse(id: request.id)
            if request.operation == .previewImage {
                try directory.createFile(MediaRaster.filename(0), data: Data(repeating: 0, count: 16))
                response.preview = .init(rasters: [.init(width: 2, height: 2)])
            } else {
                var metadata = MediaWorkflowImage(format: .png, width: 2, height: 2, scale: 1)
                if request.operation != .inspectWorkflowImage {
                    let tiff = Data([0x49, 0x49, 42, 0])
                    try directory.createFile("clipboard-png", data: workflowAuthorityPNG)
                    try directory.createFile("clipboard-tiff", data: tiff)
                    metadata.pngBytes = workflowAuthorityPNG.count; metadata.tiffBytes = tiff.count
                }
                response.workflowImage = metadata
            }
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    private func consume(_ kind: String, file: URL, root: URL, worker: MediaWorker,
                         read: @escaping @Sendable (URL) throws -> Data) async throws {
        switch kind {
        case "resolve":
            let value = try await AskWorkflowImage.resolve(file.path, folder: root, cache: root.appendingPathComponent("cache"),
                home: root.path, worker: worker, readSource: read).get()
            #expect(value.url == file && value.digest == AskWorkflowImage.hash(workflowAuthorityPNG))
        case "render":
            let value = try await AskWorkflowImage.render(.init(url: file, width: 2, height: 2,
                digest: AskWorkflowImage.hash(workflowAuthorityPNG)), worker: worker, readSource: read)
            #expect(value.images.count == 1 && value.images.first?.width == 2)
        default:
            let value = try await AskWorkflowImage.clipboard(file, digest: AskWorkflowImage.hash(workflowAuthorityPNG),
                worker: worker, preserveOriginalPNG: kind == "preserve", readSource: read)
            #expect(value.png == workflowAuthorityPNG && value.tiff.count == 4)
            #expect((value.sourceRevision != nil) == (kind == "preserve"))
        }
    }

    @Test func preReadyConsumersDoNotReadHashOrCreateCache() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try file(root), state = WorkflowAuthorityState(), worker = self.worker(state)
        let read: @Sendable (URL) throws -> Data = { url in state.read(); return try AskWorkflowImage.read(url) }
        for kind in ["resolve", "render", "copy", "preserve"] {
            do { try await consume(kind, file: file, root: root, worker: worker, read: read); Issue.record("Pre-ready consumer") } catch {}
        }
        let result = await AskWorkflowImage.resolve("data:image/png;base64," + workflowAuthorityPNG.base64EncodedString(),
            folder: root, cache: root.appendingPathComponent("cache"), home: root.path, worker: worker,
            hashData: { data in state.hash(); return AskWorkflowImage.hash(data) })
        #expect(result == .failure(.unavailable) && state.counts == [0, 0, 0])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 0, 0])
        await registry.shutdown()
    }

    @Test(arguments: ["resolve", "render", "copy", "preserve"])
    func heldSourceCannotAdoptRecoveredConsumerGeneration(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try file(root), state = WorkflowAuthorityState(), worker = self.worker(state), gate = WorkflowAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let read: @Sendable (URL) throws -> Data = { url in
            let data = try AskWorkflowImage.read(url); state.read(); gate.wait(); return data
        }
        let pending = Task { try await consume(kind, file: file, root: root, worker: worker, read: read) }
        await wait { state.counts[1] == 1 }
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 1, 0] && worker.activeCount == 0)
        gate.release()
        do { try await pending.value; Issue.record("Old source adopted recovered native lane") } catch {}
        #expect(state.counts == [0, 1, 0])
        try await consume(kind, file: file, root: root, worker: worker, read: read)
        let retained = try Data(contentsOf: file)
        #expect(state.counts == [1, 2, 0] && retained == workflowAuthorityPNG)
        await registry.shutdown()
    }

    @Test func revocationAfterNativeBeforeCacheWritePreservesOriginalAndCreatesNoCache() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkflowAuthorityState(), worker = self.worker(state), gate = WorkflowAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let original = "data:image/png;base64," + workflowAuthorityPNG.base64EncodedString(), cache = root.appendingPathComponent("cache")
        let pending = Task { await AskWorkflowImage.resolve(original, folder: root, cache: cache, home: root.path, worker: worker,
            hashData: { data in let digest = AskWorkflowImage.hash(data); state.hash(); gate.wait(); return digest }) }
        await wait { state.counts[2] == 1 }
        #expect(state.counts == [1, 0, 1] && worker.activeCount == 0)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release()
        #expect(await pending.value == .failure(.unavailable))
        #expect(!FileManager.default.fileExists(atPath: cache.path) && state.counts[0] == 1)
        let fresh = try await AskWorkflowImage.resolve(original, folder: root, cache: cache, home: root.path, worker: worker).get()
        #expect(try Data(contentsOf: fresh.url) == workflowAuthorityPNG)
        #expect(original.hasSuffix(workflowAuthorityPNG.base64EncodedString()) && state.counts[0] == 2)
        await registry.shutdown()
    }

    @Test func canceledCopyPreparationRetainsSlotsAndByteReservationsUntilReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try file(root), state = WorkflowAuthorityState(), worker = self.worker(state), gate = WorkflowAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let read: @Sendable (URL) throws -> Data = { url in
            let data = try AskWorkflowImage.read(url); state.read(); gate.wait(); return data
        }
        let a = Task { try await AskWorkflowImage.clipboard(file, worker: worker, readSource: read) }
        let b = Task { try await AskWorkflowImage.clipboard(file, worker: worker, readSource: read) }
        await wait { state.counts[1] == 2 }; a.cancel(); b.cancel()
        do { _ = try await AskWorkflowImage.clipboard(file, worker: worker); Issue.record("Freed occupied copy capacity") } catch {}
        do { _ = try await AskWorkflowImage.work { _ in 0 }; Issue.record("Freed occupied work slots") } catch {}
        #expect(state.counts == [0, 2, 0])
        gate.release(); _ = await a.result; _ = await b.result
        #expect(state.counts == [0, 2, 0])
        let fresh = try await AskWorkflowImage.clipboard(file, worker: worker)
        #expect(fresh.png == workflowAuthorityPNG && state.counts[0] == 1)
        await registry.shutdown()
    }

    @Test func stableDigestCacheReuseCorruptionAndQuotaNeverOverwriteOrEvictOutput() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkflowAuthorityState(), worker = self.worker(state), cache = root.appendingPathComponent("cache")
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let value = "data:image/png;base64," + workflowAuthorityPNG.base64EncodedString()
        let first = try await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: root.path, worker: worker).get()
        let again = try await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: root.path, worker: worker).get()
        #expect(first == again && first.digest == AskWorkflowImage.hash(workflowAuthorityPNG))
        let permissions = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try Data([7]).write(to: first.url)
        #expect(await AskWorkflowImage.resolve(value, folder: root, cache: cache, home: root.path, worker: worker) == .failure(.notImage))
        #expect(try Data(contentsOf: first.url) == Data([7]))
        let full = root.appendingPathComponent("full"), secure = try AskSecureDirectory.openRoot(full.appendingPathComponent("images"))
        for n in 0..<128 { try secure.createFile("entry-\(n)", data: Data()) }
        #expect(await AskWorkflowImage.resolve(value, folder: root, cache: full, home: root.path, worker: worker) == .failure(.unavailable))
        #expect(secure.entries(limit: 129).count == 128)
        await registry.shutdown()
    }

    @Test func actualProjectionReplacementRejectsOldPreparationAndKeepsFreshPixels() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try file(root), state = WorkflowAuthorityState(), worker = self.worker(state), gate = WorkflowAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let scope = AskImagePresentationScope(), old = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let image = AskPluginImage(url: file, width: 2, height: 2, digest: AskWorkflowImage.hash(workflowAuthorityPNG))
        let model = AskContextImageModel(budget: AskToolPixelBudget(limit: 32), maximumEdge: 2, decode: { _ in
            try await AskWorkflowImage.render(image, worker: worker, readSource: { url in
                let data = try AskWorkflowImage.read(url); if state.read() == 1 { gate.wait() }; return data
            })
        })
        let pending = Task { await model.load("same", access: old) }
        await wait { state.counts[1] == 1 }; scope.invalidate()
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        await model.load("same", access: fresh)
        #expect(model.displayed("same", access: fresh) != nil && state.counts[0] == 1)
        gate.release(); await pending.value
        #expect(model.displayed("same", access: fresh) != nil && state.counts[0] == 1)
        await model.load("same", access: old)
        #expect(model.displayed("same", access: fresh) != nil && state.counts[0] == 1)
        model.cancel(); await registry.shutdown()
    }

    @Test func previewDefaultCallerStillUsesExistingEntryAdmission() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = WorkflowAuthorityState(), worker = self.worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let result = try MediaPreviewDisplay.renderImage(workflowAuthorityPNG, type: nil,
            cancellation: AskSearchCancellation(), worker: worker)
        #expect(result.images.first?.width == 2 && state.counts[0] == 1)
        await registry.shutdown()
    }
}
