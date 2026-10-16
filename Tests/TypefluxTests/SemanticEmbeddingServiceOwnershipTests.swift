import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic model retirement at service boundaries", .serialized, .exclusiveUIState)
@MainActor
struct SemanticEmbeddingServiceOwnershipTests {
    @Test func clearRetainsArtifactsUntilOwnedHostAndChildRetire() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let owners = SemanticEmbeddingOwners()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }, embeddingOwners: owners)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        let native = try owners.query.native.reserve { false }
        let entered = AskSearchCancellation(), release = DispatchSemaphore(value: 0)
        let host = Task.detached {
            try owners.query.perform(cancelled: { false }) {
                entered.cancel(); _ = release.wait(timeout: .now() + 8)
            }
        }
        try await SemanticFileServiceTests.wait { entered.isCancelled }
        await service.clear(removeModel: true)
        #expect(service.phase == .failed)
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("semantic-files.sqlite").path))
        owners.query.native.reaped(native)
        #expect(!owners.query.isIdle, "Collection alone cannot authorize model deletion")
        release.signal(); try await host.value
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path), "Retirement never replays clear")
        await service.clear(removeModel: true)
        #expect(service.phase == .off && !FileManager.default.fileExists(atPath: service.modelURL.path))
    }

    @Test func defaultNativeQueryAndIndexReuseServiceLineagesAcrossScopes() async throws {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let vectors = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        // /bin/sh reads this private placeholder as a script. No real model or engine.
        try Data("while IFS= read -r line; do printf '%s\\n' '{\"entries\":[],\"embeddings\":\(vectors)}'; done\n".utf8).write(to: base.modelURL)
        let owners = SemanticEmbeddingOwners()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
            helper: URL(fileURLWithPath: "/bin/sh"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, embeddingOwners: owners)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(await service.search("reimbursement", type: .all, limit: 5).count == 1)
        #expect(owners.query.native.isOccupied)
        service.start(force: true)
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(await service.search("reimbursement", type: .all, limit: 5).count == 1)
        await service.clear(removeModel: true)
        #expect(service.phase == .off)
        try await owners.waitUntilIdle()
    }
}
