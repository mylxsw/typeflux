import Foundation
import SQLite3
import Testing
@testable import Typeflux

private struct ScanAdmissionSnapshot: Equatable {
    let changes: Int32
    let rows: [Int]
    let failed: [String]
    let pending: String?
    let prune: Bool
    let event: UInt64?
    let counts: SemanticFileStore.Counts
    init(_ store: SemanticFileStore, scope: AskFileScope) throws {
        rows = try store.lock.withLock {
            try ["files", "chunks", "jobs", "work_queue", "discovery", "scan_directories", "scan_scope"].map {
                try store.count($0)
            }
        }
        changes = store.lock.withLock { sqlite3_total_changes(store.database) }
        failed = try store.failedDirectories(); pending = try store.nextDirectory()
        prune = try store.hasPendingPrune()
        event = try store.completedEventID(scope: scope, volumeSignature: "private-scan-volume")
        counts = try store.counts()
    }
}

@Suite("Semantic scan preparation admission")
struct SemanticScanAdmissionTests {
    @Test(arguments: ["run", "discover", "resume", "reconcile"])
    func precancelledPreparationPreservesCommittedQueueAndScopeReceipts(_ entry: String) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = semanticScope(root.path), path = root.path + "/old.md"
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        try store.replace(path: path, modified: Date(timeIntervalSince1970: 100), bytes: 20,
                          chunks: [.init(text: "committed private fixture", page: nil)], vectors: [semanticVector()])
        try store.beginDiscovery(scope: scope)
        _ = try store.discover([(path, .document)])
        try store.recordDirectories([root.path + "/failed", root.path + "/pending"])
        try store.finishDirectory(root.path, failed: false)
        try store.finishDirectory(root.path + "/failed", failed: true)
        try store.saveEventID(100, scope: scope, volumeSignature: "private-scan-volume")
        let before = try ScanAdmissionSnapshot(store, scope: scope)
        let token = AskSearchCancellation(); token.cancel()
        let reader = SemanticFixtureReader(path: root.path + "/new.md"), encoder = SemanticFixtureEncoder()
        var summary = SemanticFileIndexer.Summary(), progress = 0, receipts = 0
        #expect(throws: CancellationError.self) {
            if entry == "run" {
                _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
                    cancelled: { token.isCancelled }, progress: { _ in progress += 1 }, discovered: { receipts += 1 })
            } else if entry == "reconcile" {
                _ = try SemanticFileIndexer.reconcile(paths: [reader.path], scope: scope, store: store,
                    reader: reader, encoder: encoder, cancelled: { token.isCancelled }, progress: { _ in progress += 1 },
                    directories: [root.path + "/pending"], prunePending: true)
            } else {
                try SemanticFileIndexer.discover(scope: scope, store: store, reader: reader,
                    paused: { false }, cancelled: { token.isCancelled }, summary: &summary,
                    progress: { _ in progress += 1 }, preparing: entry == "discover")
            }
        }
        #expect(try ScanAdmissionSnapshot(store, scope: scope) == before)
        #expect(reader.directoryReads == 0 && encoder.calls == 0 && progress == 0 && receipts == 0)
        #expect(summary == .init())
    }

    @Test func progressRevocationPreservesEnteredDiscoveryButCannotAcknowledgeIt() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = semanticScope(root.path), store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let token = AskSearchCancellation(), reader = SemanticFixtureReader(path: root.path + "/new.md")
        let encoder = SemanticFixtureEncoder()
        try store.saveEventID(100, scope: scope, volumeSignature: "private-scan-volume")
        var receipts = 0
        #expect(throws: CancellationError.self) {
            _ = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
                cancelled: { token.isCancelled }, progress: { if $0.total != nil { token.cancel() } }, discovered: {
                    receipts += 1
                    try store.saveEventID(200, scope: scope, volumeSignature: "private-scan-volume")
                })
        }
        #expect(receipts == 0 && encoder.calls == 0 && reader.directoryReads == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-scan-volume") == 100)
        #expect(try store.hasPendingPrune())
        #expect(try store.lock.withLock { try store.count("discovery") } == 1)
        #expect(try store.lock.withLock { try store.count("work_queue") } == 1)
        // An explicit new operation may resume committed work; cancellation did not replay it.
        let next = AskSearchCancellation()
        let result = try SemanticFileIndexer.run(scope: scope, store: store, reader: reader, encoder: encoder,
            cancelled: { next.isCancelled }, progress: { _ in }, discovered: {
                receipts += 1
                try store.saveEventID(200, scope: scope, volumeSignature: "private-scan-volume")
            })
        #expect(result.files == 1 && receipts == 1 && encoder.calls == 1)
        #expect(try store.counts().files == 1)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "private-scan-volume") == 200)
        #expect(try !store.hasPendingPrune())
    }
}

private final class ScanAdmissionAccess: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true, entered = false
    var waiting: Bool { condition.withLock { entered && held } }
    func read() -> Bool {
        condition.lock(); defer { condition.unlock() }; entered = true
        while held { condition.wait() }
        return true
    }
    func release() { condition.withLock { held = false; condition.broadcast() } }
}

@Suite("Semantic startup preparation admission", .serialized, .exclusiveUIState)
@MainActor
struct SemanticStartupAdmissionTests {
    @Test func sourceRevokedDuringFactoryCannotResetExistingDiscovery() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        let gate = ScanAdmissionAccess()
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let scope = SemanticFilePolicy.scope(names: base.settings.askLauncherSearchSettings, fullDiskAccess: true)
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        try store.replace(path: reader.path, modified: reader.modified, bytes: 20,
                          chunks: [.init(text: "already committed", page: nil)], vectors: [semanticVector()])
        try store.beginDiscovery(scope: scope)
        _ = try store.discover([(reader.path, .document)])
        try store.finishDirectory(root.path, failed: true)
        try store.saveEventID(90, scope: scope, volumeSignature: "older-private-volume")
        let before = try ScanAdmissionSnapshot(store, scope: scope)
        base.settings.semanticFileSearch = .init(enabled: true)
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: true, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, idle: { true }, makeReader: { reader }, makeEncoder: { _, _ in
                _ = gate.read(); return SemanticFixtureEncoder()
            }, makeQuery: { _, _ in SemanticFixtureQuery() }, eventHistory: { _ in (100, "private-scan-volume") })
        try await SemanticFileServiceTests.wait { gate.waiting }
        service.settings.semanticFileSearch = .init(enabled: false)
        gate.release()
        await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { service.phase == .off }
        #expect(try ScanAdmissionSnapshot(store, scope: scope) == before)
        #expect(try store.completedEventID(scope: scope, volumeSignature: "older-private-volume") == 90)
        #expect(reader.directoryReads == 0)
        await service.clear(removeModel: true)
    }

    @Test func scopeRevokedDuringAccessCannotOpenTheDatabase() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        let gate = ScanAdmissionAccess()
        defer { gate.release(); try? FileManager.default.removeItem(at: root) }
        base.settings.semanticFileSearch = .init(enabled: true)
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { gate.read() }, automaticStart: true, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, idle: { true }, makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }, eventHistory: { _ in (100, "private-scan-volume") })
        try await SemanticFileServiceTests.wait { gate.waiting }
        service.settings.semanticFileSearch = .init(enabled: false)
        #expect(service.phase == .preparing)
        gate.release()
        await service.prepareModelIfNeeded()
        try await SemanticFileServiceTests.wait { service.phase == .off }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains {
            $0.hasPrefix("semantic-files.sqlite")
        })
        #expect(reader.directoryReads == 0 && service.files == 0)
        await service.clear(removeModel: true)
    }
}
