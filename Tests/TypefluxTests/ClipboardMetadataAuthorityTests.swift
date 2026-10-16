import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private final class MetadataAuthorityState: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0, reads = 0
    var counts: [Int] { lock.withLock { [runs, reads] } }
    func run() { lock.withLock { runs += 1 } }
    @discardableResult func read() -> Int { lock.withLock { reads += 1; return reads } }
}
private final class MetadataSourceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while held { condition.wait() }
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Clipboard metadata original batch authority", .serialized)
@MainActor struct ClipboardMetadataAuthorityTests {
    private func file(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("private.bytes"); try Data([1, 2, 3]).write(to: url); return url
    }
    private func worker(_ state: MetadataAuthorityState) -> MediaWorker {
        MediaWorker(executable: URL(fileURLWithPath: "/usr/bin/true"), requiresLifecycle: true, run: { p, _ in
            state.run()
            let request = try JSONDecoder().decode(MediaRequest.self, from: p.stdin!)
            var response = MediaResponse(id: request.id)
            switch request.clipboard!.kind {
            case .pdf: response.clipboard = .init(pages: 7)
            case .duration: response.clipboard = .init(duration: 3)
            case .waveform: response.clipboard = .init(duration: 3, waveform: Array(repeating: 0.5, count: 180))
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

    @Test func preReadyFailureKeepsProjectionIdentityUntilExplicitNewScope() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = MetadataAuthorityState(), worker = self.worker(state)
        let provider = ClipboardMediaInfoProvider(worker: worker, readSource: { url in
            state.read(); return try .init(url)
        })
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]), scope = AskImagePresentationScope()
        let request = ClipboardMediaInfoProvider.Request(url: url, options: .init(kind: .pdf))
        let model = ClipboardMediaProjection(read: { try await provider.load($0) })
        func access() -> AskImagePresentationAccess { .init(scope: scope, epoch: scope.epoch, authorize: { true }) }
        await model.load(request, access: access())
        #expect(model.value == nil && state.counts == [0, 0])
        try await registry.start(.clipboardMetadata)
        await model.load(request, access: access())
        #expect(model.value == nil && state.counts == [0, 0])
        scope.invalidate(); await model.load(request, access: access())
        #expect(model.value?.pages == 7 && state.counts == [1, 2])
        scope.invalidate(); #expect(model.value == nil)
        await registry.shutdown()
    }

    @Test(arguments: [MediaClipboardOptions.Kind.pdf, .duration, .waveform])
    func sourcePreparationCannotAdoptRecoveredLane(_ kind: MediaClipboardOptions.Kind) async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = MetadataAuthorityState(), worker = self.worker(state), gate = MetadataSourceGate()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let provider = ClipboardMediaInfoProvider(worker: worker, readSource: { url in
            let stamp = try ClipboardMediaInfoProvider.Stamp(url); state.read(); gate.wait(); return stamp
        })
        let request = ClipboardMediaInfoProvider.Request(url: url, options: .init(kind: kind))
        let pending = Task { try await provider.load(request) }
        await wait { state.counts[1] == 1 }
        await registry.disable(.clipboardMetadata); try await registry.start(.clipboardMetadata)
        #expect(state.counts == [0, 1] && worker.activeCount == 0)
        gate.release()
        do { _ = try await pending.value; Issue.record("Old preparation adopted recovered lane") } catch {}
        #expect(state.counts == [0, 1])
        let fresh = try await provider.load(request); try fresh.validate(for: request.options)
        #expect(state.counts == [1, 3])
        await registry.shutdown()
    }

    @Test func canceledSourceReadersKeepBothSlotsUntilActualReturn() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = MetadataAuthorityState(), worker = self.worker(state), gate = MetadataSourceGate()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let provider = ClipboardMediaInfoProvider(worker: worker, readSource: { url in
            let stamp = try ClipboardMediaInfoProvider.Stamp(url); state.read(); gate.wait(); return stamp
        })
        let request = ClipboardMediaInfoProvider.Request(url: url, options: .init(kind: .pdf))
        let a = Task { try await provider.load(request) }, b = Task { try await provider.load(request) }
        await wait { state.counts[1] == 2 }; a.cancel(); b.cancel()
        do { _ = try await provider.load(request); Issue.record("Released occupied source slot") } catch {}
        #expect(state.counts == [0, 2])
        gate.release(); _ = await a.result; _ = await b.result
        #expect(state.counts == [0, 2])
        #expect(try await provider.load(request).pages == 7)
        await registry.shutdown()
    }

    @Test func revocationDuringFinalSourceCheckRejectsCompletedNativeValue() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = MetadataAuthorityState(), worker = self.worker(state)
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let provider = ClipboardMediaInfoProvider(worker: worker, readSource: { url in
            let stamp = try ClipboardMediaInfoProvider.Stamp(url)
            if state.read() == 2 { worker.preventNewWork() }
            return stamp
        })
        do { _ = try await provider.load(.init(url: url, options: .init(kind: .pdf))); Issue.record("Retired result delivered") } catch {}
        #expect(state.counts == [1, 2] && worker.activeCount == 0)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        await registry.shutdown()
    }

    @Test func scopeReplacementCancelsHeldPreparationWithoutPublishingOrReplaying() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try file(root), state = MetadataAuthorityState(), worker = self.worker(state), gate = MetadataSourceGate()
        let module = MediaExtractionModule(worker: worker, healthDirectory: root, domain: .clipboardMetadata)
        let registry = ModuleRegistry([module.registration]); try await registry.start(.clipboardMetadata)
        let provider = ClipboardMediaInfoProvider(worker: worker, readSource: { url in
            let stamp = try ClipboardMediaInfoProvider.Stamp(url)
            if state.read() == 1 { gate.wait() }; return stamp
        })
        let scope = AskImagePresentationScope(), request = ClipboardMediaInfoProvider.Request(url: url, options: .init(kind: .pdf))
        let old = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        let model = ClipboardMediaProjection(read: { try await provider.load($0) })
        let pending = Task { await model.load(request, access: old) }
        await wait { state.counts[1] == 1 }; scope.invalidate()
        let fresh = AskImagePresentationAccess(scope: scope, epoch: scope.epoch, authorize: { true })
        await model.load(request, access: fresh)
        #expect(model.displayed(request, access: fresh)?.pages == 7)
        gate.release(); await pending.value
        #expect(model.displayed(request, access: fresh)?.pages == 7 && state.counts == [1, 3])
        await model.load(request, access: old)
        #expect(state.counts == [1, 3] && model.displayed(request, access: fresh)?.pages == 7)
        model.cancel(); await registry.shutdown()
    }
}
