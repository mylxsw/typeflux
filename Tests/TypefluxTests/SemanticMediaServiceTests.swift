import Foundation
import Testing
@testable import Typeflux

@Suite("Media service scheduling and recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticMediaServiceTests {
    private func fixture(idle: Bool, mediaFailure: Bool = false) throws
        -> (SemanticFileSearchService, URL) {
        let (original, root, _, models) = try SemanticFileServiceTests().fixture()
        try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        let reader = SemanticMediaFixtureReader(root: root.path)
        reader.names = ["image.png", "document.md"]
        let media = SemanticFixtureMediaEncoder()
        if mediaFailure { media.before = { _ in throw URLError(.badServerResponse) } }
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, resourceConstrained: { false }, models: models,
            mediaModels: SemanticMediaFixtureModels(source: models.source), idle: { idle },
            makeMediaEncoder: { _, _, _ in media }, makeReader: { reader },
            makeEncoder: { _, _ in SemanticFixtureEncoder() }, makeQuery: { _, _ in SemanticFixtureQuery() })
        return (service, root)
    }

    @Test func documentsStaySearchableWhileMediaWaitsForIdle() async throws {
        let (service, root) = try fixture(idle: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.indexProgress?.waitingForIdle == true }
        #expect(service.isEnabled)
        #expect(service.status().tone == .ready)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.name) == ["document.md"])
        service.pause(true)
        try await SemanticFileServiceTests.wait { service.phase == .paused }
        #expect(!service.isEnabled, "manual pause keeps the existing content-search policy")
        await service.clear(removeModel: true)
    }

    @Test func mediaFailureDoesNotInvalidateTheTextModelOrDocumentIndex() async throws {
        let (service, root) = try fixture(idle: true, mediaFailure: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        #expect(service.mediaFailed && service.modelReady && service.isEnabled)
        #expect(service.status().action == .retry)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.name) == ["document.md"])
        #expect(FileManager.default.fileExists(atPath: service.mediaModelURL.path))
        #expect(service.storage().model > 0)
        await service.clear(removeModel: true)
        #expect(!FileManager.default.fileExists(atPath: service.mediaModelURL.path))
    }

    @Test func idleWaitingDoesNotRetainADiscardedService() async throws {
        var context: (SemanticFileSearchService, URL)? = try fixture(idle: false)
        let root = try #require(context?.1)
        defer { try? FileManager.default.removeItem(at: root) }
        var service = context?.0
        context = nil
        weak let reference = service
        #expect(service?.setEnabled(true) == true)
        try await SemanticFileServiceTests.wait { reference?.indexProgress?.waitingForIdle == true }
        // Only the worker's weak progress callbacks remain.
        service = nil
        try await SemanticFileServiceTests.wait { reference == nil }
        try await Task.sleep(for: .milliseconds(300))
    }
}
