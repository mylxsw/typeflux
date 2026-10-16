import Foundation
import Testing
@testable import Typeflux

private final class SemanticPreparationReader: AskFileReading, @unchecked Sendable {
    let base: SemanticFixtureReader
    private let lock = NSLock()
    private var enabled = false, contentBlocked = false, starts = 0, finishes = 0
    var started: Int {
        lock.withLock { starts }
    }

    var finished: Int {
        lock.withLock { finishes }
    }

    init(base: SemanticFixtureReader) {
        self.base = base
    }

    func stall() {
        lock.withLock { enabled = true }
    }

    func stallContent(_ value: Bool) {
        lock.withLock { contentBlocked = value }
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if request.operation == .content, lock.withLock({ contentBlocked }) {
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            throw AskFileReadError.cancelled
        }
        if request.operation == .resolve, lock.withLock({ enabled }) {
            lock.withLock { starts += 1 }
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            lock.withLock { finishes += 1 }
            throw AskFileReadError.cancelled
        }
        return try base.read(request, isCancelled: isCancelled)
    }
}

@Suite("Cancellable search preparation and permission budgets", .serialized, .exclusiveUIState)
@MainActor
struct SemanticPreparationServiceTests {
    @Test func `closing search and foreground voice cancel detached permission preparation`() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let preparation = SemanticPreparationReader(base: reader), query = SemanticQueryProbe()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: SemanticFixtureWatcher(), access: { true },
                                                automaticStart: false,
                                                lowPowerMode: { false }, thermalConstrained: { false }, models: models,
                                                makeReader: { preparation },
                                                makeEncoder: { _, _ in SemanticFixtureEncoder() },
                                                makeQuery: { _, _ in query })
        try #require(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        service.prepareForSearch()
        try await SemanticFileServiceTests.wait { service.queryState != .warming }
        preparation.stallContent(true)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(await service.search("reimbursement", type: .all, limit: 5).isEmpty)
        #expect(service.queryState == .degraded, "a budget-limited FTS publication must report incomplete validation")
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.3)
        #expect(query.calls == 0, "an exhausted FTS budget must not trigger a second cold validation in the same query")
        preparation.stallContent(false)
        #expect(await service.search("reimbursement", type: .all, limit: 5).count == 1)
        #expect(service.queryState == .idle)
        preparation.stall()
        for round in 1 ... 2 {
            service.prepareForSearch()
            try await SemanticFileServiceTests.wait { preparation.started == round }
            let start = ProcessInfo.processInfo.systemUptime
            if round == 1 {
                service.endSearch()
            } else {
                service.setForegroundBusy(true)
            }
            try await SemanticFileServiceTests.wait { preparation.finished == round }
            #expect(ProcessInfo.processInfo.systemUptime - start < 0.3,
                    "cancellation must reach detached I/O rather than waiting for its startup deadline")
            #expect(service.queryState != .warming)
        }
        await service.clear(removeModel: true)
    }
}
