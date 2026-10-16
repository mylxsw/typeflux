import AppKit
import Darwin
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class ArtifactAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    var count: Int { lock.withLock { runs } }
    func run() { lock.withLock { runs += 1 } }
}
private final class ArtifactAuthorityGate: @unchecked Sendable {
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
private actor ArtifactIndependentDecoder {
    private(set) var calls = 0
    func decode() -> AskFilePreviewPDF.Result {
        calls += 1
        return .init(images: [AskAttachmentFixture.image(width: 2, height: 2)], numbers: [], pages: 0)
    }
}

@Suite("Artifact image original native authority", .exclusiveUIState)
@MainActor struct ArtifactImageAuthorityTests {
    private func bundle() -> AskArtifactBundle {
        let data = Data([1, 2, 3])
        let ref = AskArtifactRef(id: "private", ownerId: "owner", conversationId: "conversation", runId: "original-run",
            version: "1", mediaType: "image/png", sizeBytes: 3, sha256: AskToolPolicy.digest(data), cleanup: "device_persistent")
        return .init(manifest: .init(ref: ref, createdAt: Date(), entry: "image", resources: []), files: ["image": data])
    }
    private func worker(_ state: ArtifactAuthorityState, gate: ArtifactAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            let fd = openat(p.directoryDescriptor, "raster-0", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw MediaFailure.unavailable }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 128, count: 16))
            var response = MediaResponse(id: request.id)
            response.preview = .init(rasters: [.init(width: 2, height: 2)])
            response.preview?.imageType = request.preview?.imageType
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func preReadyModelDoesNotLoadOrCopyAndNeedsExplicitFreshOperation() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactAuthorityState(), worker = worker(state), saved = bundle()
        var loads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in })
        let model = AskArtifactImageModel(worker: worker, write: { data, type in
            #expect(data == saved.files["image"] && type == saved.manifest.ref.mediaType)
            writes += 1; return true
        })
        await model.load(saved.manifest.ref, access: access); await model.copy(saved.manifest.ref, access: access)
        #expect(loads == 0 && writes == 0 && state.count == 0 && model.image == nil && !model.busy)
        #expect(model.error == AskArtifactError.unavailable.localizedDescription)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(loads == 0 && writes == 0 && state.count == 0)
        await model.load(saved.manifest.ref, access: access)
        #expect(model.image != nil && model.error == nil && loads == 1 && writes == 0 && state.count == 1)
        await model.copy(saved.manifest.ref, access: access)
        #expect(loads == 2 && writes == 1 && state.count == 2)
        #expect(saved.files["image"] == Data([1, 2, 3]))
        model.cancel(); await registry.shutdown()
    }

    @Test func originalModelStampPrecedesSourceLoadAndRevocationCannotReachNativeOrWrite() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactAuthorityState(), worker = worker(state), saved = bundle()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration])
        for copying in [false, true] {
            try await registry.start(.mediaPreviews)
            var writes = 0, loads = 0
            let model = AskArtifactImageModel(worker: worker, write: { _, _ in writes += 1; return true })
            let access = AskArtifactAccess(load: { _ in loads += 1; module.module.supervisor.admission.setEnabled(false); return saved }, validate: { _ in })
            let before = state.count
            if copying { await model.copy(saved.manifest.ref, access: access) }
            else { await model.load(saved.manifest.ref, access: access) }
            #expect(model.image == nil && model.error == AskArtifactError.unavailable.localizedDescription)
            #expect(loads == 1 && writes == 0 && state.count == before)
            await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
            #expect(loads == 1 && writes == 0 && state.count == before, "Recovery must not replay source or copy")
            let fresh = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in })
            if copying { await model.copy(saved.manifest.ref, access: fresh) }
            else { await model.load(saved.manifest.ref, access: fresh) }
            #expect(model.image != nil && model.error == nil && loads == 2 && writes == (copying ? 1 : 0) && state.count == before + 1)
            model.cancel(); await registry.disable(.mediaPreviews)
        }
        #expect(saved.files["image"] == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func directPresentationRetainsPreReadyRetiredAndForeignStamps() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactAuthorityState(), worker = worker(state), preReady = worker.authorization()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let old = worker.authorization()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")).authorization()
        for stamp in [preReady, old, foreign] {
            do { _ = try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: worker, authorization: stamp); Issue.record("Old input upgraded") }
            catch { #expect(error as? AskArtifactError == .unavailable) }
        }
        for (data, type) in [(Data(), "image/png"), (Data([1]), "image/svg+xml")] {
            do { _ = try await AskArtifactPresentation.image(data, mediaType: type, worker: worker); Issue.record("Invalid input") } catch {}
        }
        #expect(state.count == 0 && worker.permits(worker.authorization()))
        let fresh = try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: worker)
        #expect(fresh.images.first?.width == 2 && state.count == 1)
        await registry.shutdown()
    }

    @Test func finalValidNativeCompletionThenRevocationCannotPublishOrCopy() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactAuthorityState(), worker = worker(state), saved = bundle()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration])
        for copying in [false, true] {
            try await registry.start(.mediaPreviews)
            var checks = 0, writes = 0
            let access = AskArtifactAccess(load: { _ in saved }, validate: { _ in
                checks += 1
                if checks == 2 {
                    #expect(worker.activeCount == 0 && worker.permits(worker.authorization()), "Valid native result must precede revocation")
                    module.module.supervisor.admission.setEnabled(false)
                }
            })
            let model = AskArtifactImageModel(worker: worker, write: { _, _ in writes += 1; return true })
            let before = state.count
            if copying { await model.copy(saved.manifest.ref, access: access) }
            else { await model.load(saved.manifest.ref, access: access) }
            #expect(checks == 2 && state.count == before + 1 && writes == 0 && model.image == nil && !model.busy)
            #expect(model.error == AskArtifactError.unavailable.localizedDescription)
            model.cancel(); await registry.disable(.mediaPreviews)
        }
        #expect(saved.files["image"] == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func canceledNativeCallsKeepCapacityUntilActualReturnAndNeverWrite() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactAuthorityState(), gate = ArtifactAuthorityGate(), worker = worker(state, gate: gate), saved = bundle()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        var writes = 0
        let a = AskArtifactImageModel(worker: worker, write: { _, _ in writes += 1; return true })
        let b = AskArtifactImageModel(worker: worker, write: { _, _ in writes += 1; return true })
        let access = AskArtifactAccess(load: { _ in saved }, validate: { _ in })
        let ta = Task { await a.load(saved.manifest.ref, access: access) }, tb = Task { await b.copy(saved.manifest.ref, access: access) }
        await wait { gate.count == 2 }; ta.cancel(); tb.cancel(); a.cancel(); b.cancel()
        #expect(worker.activeCount == 2)
        do { _ = try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: worker); Issue.record("Slots released before physical return") } catch {}
        #expect(state.count == 2 && writes == 0)
        gate.release(); await ta.value; await tb.value
        #expect(worker.activeCount == 0 && a.image == nil && b.image == nil && writes == 0)
        await b.copy(saved.manifest.ref, access: access)
        #expect(b.image != nil && writes == 1 && state.count == 3)
        a.cancel(); b.cancel(); await registry.shutdown()
    }

    @Test func customActorRemainsIndependentAndCanceledEntryPreservesNewSnapshot() async throws {
        let state = ArtifactAuthorityState(), worker = worker(state), custom = ArtifactIndependentDecoder(), saved = bundle()
        var loads = 0, writes = 0
        let access = AskArtifactAccess(load: { _ in loads += 1; return saved }, validate: { _ in })
        let model = AskArtifactImageModel(worker: worker, decode: { _, _ in await custom.decode() }, write: { _, _ in writes += 1; return true })
        await model.load(saved.manifest.ref, access: access)
        let snapshot = try #require(model.image)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(saved.manifest.ref, access: access)
            await model.copy(saved.manifest.ref, access: access)
            do { _ = try await AskArtifactPresentation.image(Data([1]), mediaType: "image/png", worker: worker); Issue.record("Pre-canceled native") }
            catch { #expect(error is CancellationError) }
        }
        await canceled.value
        #expect(model.image === snapshot && model.error == nil && !model.busy && loads == 1 && writes == 0 && state.count == 0)
        await model.copy(saved.manifest.ref, access: access)
        #expect(writes == 1 && loads == 2 && state.count == 0)
        #expect(await custom.calls == 2)
        model.cancel()
    }

    @Test func cancellationInsideSourceValidationCannotEnterReadOrWrite() async {
        let state = ArtifactAuthorityState(), worker = worker(state), saved = bundle()
        let model = AskArtifactImageModel(worker: worker, write: { _, _ in Issue.record("Canceled write"); return true })
        let access = AskArtifactAccess(load: { _ in Issue.record("Canceled source read"); return saved }, validate: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { await model.copy(saved.manifest.ref, access: access) }
        await task.value
        #expect(model.image == nil && model.error == nil && !model.busy && state.count == 0)
    }
}
