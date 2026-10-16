import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

// A bounded envelope for the pure IPC validator, never passed to an image decoder.
private let imageAuthorityEnvelope = Data([255, 216, 255, 192, 0, 11, 8, 0, 2, 0, 2, 1, 1, 17, 0,
    255, 218, 0, 8, 1, 1, 0, 0, 63, 0, 0, 255, 217])
private final class ImageDataAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, sends = 0
    var counts: [Int] { lock.withLock { [runs, sends] } }
    func run() { lock.withLock { runs += 1 } }
    func send() { lock.withLock { sends += 1 } }
}
private final class ImageDataAuthorityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Read-only image data original authority", .serialized)
@MainActor struct ImageDataAuthorityTests {
    private let original = Data([1, 2, 3])
    private func worker(_ state: ImageDataAuthorityState, gate: ImageDataAuthorityGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); gate?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            if request.operation == .normalizeImage {
                response.items = [.init(image: "data:image/jpeg;base64," + imageAuthorityEnvelope.base64EncodedString())]
                response.normalization = request.normalization
            } else { response.generatedImage = .init(mediaType: "image/png", width: 2, height: 2) }
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    private func consume(_ kind: String, normalizer: AskToolImageNormalizer, validator: AskGeneratedImageValidator,
                         authorization: MediaWorker.Authorization? = nil) async throws {
        if kind == "normalize" {
            let url: String
            if let authorization { url = try await normalizer.normalize(original, type: .png, authorization: authorization) }
            else { url = try await normalizer.normalize(original, type: .png) }
            #expect(AskToolImageNormalizer.valid(url))
        } else {
            let value: AskGeneratedImageData
            if let authorization { value = try await validator.validate(original, authorization: authorization) }
            else { value = try await validator.validate(original) }
            #expect(value.data == original && value.width == 2 && value.fileExtension == "png")
        }
    }

    @Test func preReadyAndPrecancelledFacadeEntriesDoNotDispatch() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(MediaJPEG.isNormalized(imageAuthorityEnvelope))
        let state = ImageDataAuthorityState(), worker = self.worker(state)
        let normalizer = AskToolImageNormalizer(worker: worker), validator = AskGeneratedImageValidator(worker: worker)
        for kind in ["normalize", "validate"] {
            do { try await consume(kind, normalizer: normalizer, validator: validator); Issue.record("Pre-ready data") } catch {}
        }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 0])
        for kind in ["normalize", "validate"] {
            let pending = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await consume(kind, normalizer: normalizer, validator: validator)
            }
            do { try await pending.value; Issue.record("Canceled data") } catch {}
        }
        #expect(state.counts == [0, 0])
        try await consume("normalize", normalizer: normalizer, validator: validator)
        try await consume("validate", normalizer: normalizer, validator: validator)
        #expect(state.counts == [2, 0])
        await registry.shutdown()
    }

    @Test(arguments: ["normalize", "validate"])
    func retainedContinuationCannotUpgradeAfterRecovery(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageDataAuthorityState(), worker = self.worker(state), preReady = worker.authorization()
        let normalizer = AskToolImageNormalizer(worker: worker), validator = AskGeneratedImageValidator(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let old = worker.authorization()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        for authorization in [preReady, old] {
            do { try await consume(kind, normalizer: normalizer, validator: validator, authorization: authorization); Issue.record("Old data upgraded") } catch {}
        }
        #expect(state.counts == [0, 0])
        try await consume(kind, normalizer: normalizer, validator: validator, authorization: worker.authorization())
        #expect(state.counts == [1, 0])
        await registry.shutdown()
    }

    @Test(arguments: ["normalize", "validate"])
    func cancellationRetainsFacadeAndNativeSlotsUntilActualReturn(_ kind: String) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageDataAuthorityState(), gate = ImageDataAuthorityGate(), worker = self.worker(state, gate: gate)
        defer { gate.release() }
        let normalizer = AskToolImageNormalizer(worker: worker), validator = AskGeneratedImageValidator(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let a = Task { try await consume(kind, normalizer: normalizer, validator: validator) }
        let b = Task { try await consume(kind, normalizer: normalizer, validator: validator) }
        await wait { state.counts[0] == 2 }; a.cancel(); b.cancel()
        do { try await consume(kind, normalizer: normalizer, validator: validator); Issue.record("Freed occupied facade") } catch {}
        #expect(worker.activeCount == 2 && state.counts[0] == 2)
        gate.release(); _ = await a.result; _ = await b.result
        #expect(worker.activeCount == 0 && state.counts[0] == 2)
        try await consume(kind, normalizer: normalizer, validator: validator)
        #expect(state.counts[0] == 3)
        await registry.shutdown()
    }

    @Test func receivedGenerationResponseRetainsUsageAndOriginalWithoutAnotherRequest() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageDataAuthorityState(), worker = self.worker(state), gate = ImageDataAuthorityGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let stamp = worker.authorization(), validator = AskGeneratedImageValidator(worker: worker), bytes = original
        let response = try JSONSerialization.data(withJSONObject: ["id": "fixture-once", "usage": ["images": 1],
            "data": [["b64_json": bytes.base64EncodedString()]]])
        let transport = ImageTransportStub { _, _ in state.send(); gate.wait(); return response }
        let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
        let retentionRoot = root.appendingPathComponent("retention")
        let journal = try AskImageGenerationRetention(rootURL: retentionRoot, scope: scope, callId: "call", metadata: Data([1]))
        let service = AskImageGenerationService(transport: transport, validate: { data in
            let saved = try AskImageGenerationRetention.load(rootURL: retentionRoot, id: journal.id, scope: scope, callId: "call")
            #expect(saved["response.json"] == response)
            return try await validator.validate(data, authorization: stamp)
        })
        let pending = Task { try await service.generate(.init(arguments: ["prompt": "fixture"]), configuration: .preset(.openAI), key: "fixture", retention: journal) }
        await wait { state.counts[1] == 1 }
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release()
        let result = try await pending.value
        #expect(result.incomplete && result.images.isEmpty && result.unvalidatedImages == [bytes])
        #expect(result.requestID == "fixture-once" && result.usage != nil && state.counts == [0, 1])
        let saved = try AskImageGenerationRetention.load(rootURL: retentionRoot, id: journal.id, scope: scope, callId: "call")
        #expect(saved["response.json"] == response)
        #expect(throws: (any Error).self) { try AskImageGenerationRetention(rootURL: retentionRoot, scope: scope, callId: "call", metadata: Data([1])) }
        #expect(try await validator.validate(bytes).data == bytes)
        let requests = await transport.requests
        #expect(requests.count == 1 && state.counts == [1, 1])
        await registry.shutdown()
    }

    @Test func toolReceiptAndPrivateProgramOutputSurviveUnavailableProjection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageDataAuthorityState(), worker = self.worker(state), normalizer = AskToolImageNormalizer(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let stamp = worker.authorization()
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        let raw = AskTypedContent.json(["type": "image", "mimeType": "image/png", "data": original.base64EncodedString()])
        let receipt = AskExecutionOutcome(status: "ok", content: [raw])
        let failed = await AskTypedContent.prepare(receipt) { try await normalizer.normalize($0, type: $1, authorization: stamp) }
        #expect(failed.content == receipt.content && failed.safeStatus == .ok && failed.preparedImages.isEmpty)
        #expect(AskTypedContent.project(failed).incomplete && state.counts[0] == 0)
        let workspace = try AskSecureDirectory.openRoot(root.appendingPathComponent("workspace"))
        try workspace.createFile("out.png", data: original)
        let projection = await AskCodeSandbox.firstImage([("out.png", original.count)], workspace: workspace) {
            try await normalizer.normalize($0, type: $1, authorization: stamp)
        }
        #expect(projection.url == nil && projection.incomplete)
        #expect(try workspace.readFile("out.png", limit: 10) == original)
        let fresh = await AskTypedContent.prepare(receipt) { try await normalizer.normalize($0, type: $1) }
        #expect(fresh.content == receipt.content && AskTypedContent.project(fresh).images.count == 1)
        #expect(state.counts[0] == 1)
        await registry.shutdown()
    }

    @Test func emptyAndForeignAuthorityRefuseWithoutNativeDispatch() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ImageDataAuthorityState(), worker = self.worker(state)
        let normalizer = AskToolImageNormalizer(worker: worker), validator = AskGeneratedImageValidator(worker: worker)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        do { _ = try await normalizer.normalize(Data(), type: .png); Issue.record("Empty normalized") } catch {}
        do { _ = try await validator.validate(Data()); Issue.record("Empty validated") } catch {}
        let foreign = MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true")), stamp = foreign.authorization()
        for kind in ["normalize", "validate"] {
            do { try await consume(kind, normalizer: normalizer, validator: validator, authorization: stamp); Issue.record("Foreign authority") } catch {}
        }
        #expect(state.counts[0] == 0 && module.module.health.current?.state == .ready)
        await registry.shutdown()
    }
}
