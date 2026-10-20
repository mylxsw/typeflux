import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class GeneratedBatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, sends = 0
    var counts: [Int] { lock.withLock { [runs, sends] } }
    func run() { lock.withLock { runs += 1 } }
    func send() { lock.withLock { sends += 1 } }
}
private final class GeneratedBatchGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Generated response original batch authority", .serialized, .exclusiveUIState)
@MainActor struct GeneratedBatchAuthorityTests {
    private let bytes = Data([1, 2, 3])
    private let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
    private func worker(_ state: GeneratedBatchState, held: GeneratedBatchGate? = nil) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run(); held?.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            response.generatedImage = .init(mediaType: "image/png", width: 2, height: 2)
            return .init(termination: .exited(0), exitCode: 0,
                stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
    }
    private func journal(_ root: URL, _ call: String) throws -> AskImageGenerationRetention {
        try .init(rootURL: root.appendingPathComponent("receipts"), scope: scope, callId: call, metadata: Data([1]))
    }
    private func saved(_ root: URL, _ journal: AskImageGenerationRetention, _ call: String) throws -> [String: Data] {
        try AskImageGenerationRetention.load(rootURL: root.appendingPathComponent("receipts"), id: journal.id, scope: scope, callId: call)
    }
    private func inline() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "once", "usage": ["images": 2],
            "data": [["b64_json": bytes.base64EncodedString()], ["b64_json": bytes.base64EncodedString()]]])
    }
    private func urls() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "once", "usage": ["images": 2], "output": ["choices": [["message": ["content": [
            ["image": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png"],
            ["image": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/b.png"]]]]]]])
    }
    private func generate(_ service: AskImageGenerationService, _ journal: AskImageGenerationRetention,
                          provider: AskImageProvider = .openAI) async throws -> AskImageGenerationResult {
        try await service.generate(.init(arguments: ["prompt": "private fixture"]), configuration: .preset(provider), key: "fixture", retention: journal)
    }
    private func wait(_ predicate: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func recoveryBetweenCompletedImagesRetainsPartialOutputWithoutAdoptingNewGeneration() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = GeneratedBatchState(), worker = worker(state), gate = GeneratedBatchGate()
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let response = try urls(), bytes = bytes
        let transport = ImageTransportStub { _, count in
            state.send()
            if count == 1 { return response }
            if count == 3 { gate.wait() }
            return bytes
        }
        let receipt = try journal(root, "old")
        let service = AskImageGenerationService(transport: transport, nativeValidator: .init(worker: worker))
        let task = Task { try await generate(service, receipt, provider: .bailian) }
        await wait { state.counts == [1, 3] }
        #expect(worker.activeCount == 0) // Image one has completed, not merely entered preparation.
        #expect(try saved(root, receipt, "old")["response.json"] == response)
        await registry.disable(.mediaPreviews); try await registry.start(.mediaPreviews)
        gate.release()
        let result = try await task.value
        #expect(result.images.map(\.data) == [bytes] && result.unvalidatedImages == [bytes] && result.incomplete)
        #expect(result.requestID == "once" && result.usage != nil && state.counts == [1, 3])
        let retained = try saved(root, receipt, "old")
        #expect(retained["download-0"] == bytes && retained["download-1"] == bytes)
        let requests = await transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(throws: (any Error).self) { try journal(root, "old") }
        // A new explicit batch uses current availability; no old response is resubmitted.
        let freshTransport = ImageTransportStub { _, count in count == 1 ? response : bytes }
        let fresh = AskImageGenerationService(transport: freshTransport, nativeValidator: .init(worker: worker))
        // URL response uses its own injected transport for the two private downloads.
        let freshResult = try await generate(fresh, journal(root, "fresh"), provider: .bailian)
        #expect(freshResult.images.count == 2 && !freshResult.incomplete && state.counts[0] == 3)
        await registry.shutdown()
    }

    @Test func preReadyBatchCannotGainAuthorityFromReadinessWhileResponseIsHeld() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = GeneratedBatchState(), worker = worker(state), gate = GeneratedBatchGate()
        defer { gate.release() }
        let response = try inline()
        let transport = ImageTransportStub { _, _ in state.send(); gate.wait(); return response }
        let service = AskImageGenerationService(transport: transport, nativeValidator: .init(worker: worker))
        let receipt = try journal(root, "old")
        let task = Task { try await generate(service, receipt) }
        await wait { state.counts[1] == 1 }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        #expect(state.counts == [0, 1])
        gate.release()
        let result = try await task.value
        #expect(result.images.isEmpty && result.unvalidatedImages == [bytes, bytes] && result.incomplete)
        let retained = try saved(root, receipt, "old")
        #expect(result.usage != nil && retained["response.json"] == response)
        #expect(state.counts == [0, 1])
        let fresh = try await generate(service, journal(root, "fresh"))
        #expect(fresh.images.count == 2 && state.counts == [2, 2])
        await registry.shutdown()
    }

    @Test func cancellationDuringEnteredValidationKeepsOwnershipAndChargedReceipt() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = GeneratedBatchState(), gate = GeneratedBatchGate(), worker = worker(state, held: gate)
        defer { gate.release() }
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let response = try inline(), transport = ImageTransportStub { _, _ in state.send(); return response }
        let receipt = try journal(root, "cancel")
        let service = AskImageGenerationService(transport: transport, nativeValidator: .init(worker: worker))
        let task = Task { try await generate(service, receipt) }
        await wait { state.counts[0] == 1 }; task.cancel()
        let retained = try saved(root, receipt, "cancel")
        #expect(worker.activeCount == 1 && retained["response.json"] == response)
        gate.release()
        let result = try await task.value
        #expect(result.images.isEmpty && result.unvalidatedImages == [bytes] && result.incomplete && result.usage != nil)
        #expect(worker.activeCount == 0 && state.counts == [1, 1])
        await registry.shutdown()
    }

    @Test func customValidatorKeepsIndependentContractAndPartialOriginals() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = GeneratedBatchState(), worker = worker(state), response = try inline()
        let transport = ImageTransportStub { _, _ in state.send(); return response }
        let service = AskImageGenerationService(transport: transport, validate: { data in
            state.run()
            if state.counts[0] == 1 { return .init(data: data, mediaType: "image/png", width: 2, height: 2) }
            throw MediaFailure.unavailable
        }, nativeValidator: .init(worker: worker))
        let result = try await generate(service, journal(root, "custom"))
        #expect(result.images.map(\.data) == [bytes] && result.unvalidatedImages == [bytes] && result.incomplete)
        #expect(state.counts == [2, 1] && worker.activeCount == 0)
    }

    @Test func transientDownloadRetryDoesNotRetryPaidRequestOrRecaptureBatch() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = GeneratedBatchState(), worker = worker(state), response = try urls(), bytes = bytes
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .mediaPreviews)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.mediaPreviews)
        let transport = ImageTransportStub { _, count in
            state.send()
            if count == 1 { return response }
            if count == 2 { throw AskImageError.http(503) }
            return bytes
        }
        let service = AskImageGenerationService(transport: transport, nativeValidator: .init(worker: worker))
        let result = try await generate(service, journal(root, "retry"), provider: .bailian)
        #expect(result.images.map(\.data) == [bytes, bytes] && !result.incomplete && state.counts == [2, 4])
        let requests = await transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1 && requests[1].url == requests[2].url)
        await registry.shutdown()
    }
}
