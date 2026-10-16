import Foundation
import Testing
@testable import Typeflux

private final class RetainedSemanticValidation: AskFileReading, @unchecked Sendable {
    let entered = AskSearchCancellation()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocking = false, count = 0
    let base: SemanticFixtureReader
    init(_ base: SemanticFixtureReader) { self.base = base }
    func block() { lock.withLock { blocking = true } }
    var validations: Int { lock.withLock { count } }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if request.operation == .content, request.readText == false {
            let blocked = lock.withLock {
                count += 1; let blocked = blocking; blocking = false; return blocked
            }
            if blocked {
                entered.cancel()
                guard release.wait(timeout: .now() + 8) == .success else { throw AskFileReadError.timeout }
            }
        }
        // Deliberately ignore cancellation: the outer owner must reject late success.
        return try base.read(request, isCancelled: { false })
    }
    func unblock() { lock.withLock { blocking = false }; release.signal() }
}

@Suite("Semantic reader service replacement", .serialized, .exclusiveUIState)
@MainActor
struct SemanticReaderServiceTests {
    @Test func `scope replacement retains blocked validation and does not replay a query`() async throws {
        let (base, root, source, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let reader = RetainedSemanticValidation(source), query = SemanticQueryProbe()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in query })
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        reader.block()
        let old = Task { await service.search("reimbursement", type: .all, limit: 5) }
        try await SemanticFileServiceTests.wait { reader.entered.isCancelled }
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let calls = reader.validations
        #expect(await service.search("reimbursement", type: .all, limit: 5).isEmpty)
        #expect(service.queryState == .degraded)
        #expect(reader.validations == calls && query.calls == 0)
        reader.unblock()
        #expect(await old.value.isEmpty)
        #expect(reader.validations == calls, "Retirement must not replay either old or rejected queries")
        #expect(await service.search("reimbursement", type: .all, limit: 5).count == 1)
        #expect(query.calls == 1)
        await service.clear(removeModel: true)
    }
}
