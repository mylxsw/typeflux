import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic artifact mutation admission", .serialized, .exclusiveUIState)
@MainActor
struct SemanticArtifactServiceTests {
    private func fixture(_ root: URL, settings: SettingsStore, reader: SemanticFixtureReader,
                         models: ArtifactModels, owners: SemanticEmbeddingOwners) -> SemanticFileSearchService {
        SemanticFileSearchService(settings: settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: SemanticFixtureWatcher(),
            access: { true }, automaticStart: false, lowPowerMode: { false }, thermalConstrained: { false },
            models: models, makeReader: { reader }, makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }, embeddingOwners: owners)
    }

    @Test func occupiedModelRefusesBeforeDownloadAndOnlyExplicitRetryRuns() async throws {
        let (base, root, reader, original) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owners = SemanticEmbeddingOwners(), models = ArtifactModels(source: original.source)
        let service = fixture(root, settings: base.settings, reader: reader, models: models, owners: owners)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        let old = Data("existing".utf8); try old.write(to: service.modelURL)
        let id = try owners.indexing.native.reserve { false }
        service.downloadModel()
        #expect(service.phase == .failed && models.fetches == 0)
        #expect(try Data(contentsOf: service.modelURL) == old)
        owners.indexing.native.reaped(id)
        #expect(models.fetches == 0)
        service.downloadModel()
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        #expect(models.fetches == 1 && models.installs == 1)
        await service.clear(removeModel: true)
    }

    @Test func cancelledUncooperativeInstallKeepsAdmissionUntilJoinedAndNeverReportsReady() async throws {
        let (base, root, reader, original) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owners = SemanticEmbeddingOwners(), models = ArtifactModels(source: original.source)
        models.blockInstall = true
        let service = fixture(root, settings: base.settings, reader: reader, models: models, owners: owners)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        service.downloadModel()
        try await SemanticFileServiceTests.wait { models.entered.isCancelled }
        service.cancelDownload(); service.downloadModel()
        #expect(models.fetches == 1 && models.installs == 1)
        #expect(throws: AskFileReadError.self) { try owners.query.perform(cancelled: { false }) { 1 } }
        #expect(throws: AskFileReadError.self) { try owners.mutation(.projector) }
        models.release.signal()
        try await SemanticFileServiceTests.wait { service.phase == .failed }
        #expect(!service.modelReady)
        #expect(try Data(contentsOf: service.modelURL) == Data(contentsOf: original.source),
                "Already dispatched effects are retained, not falsely rolled back")
        #expect(models.fetches == 1 && models.installs == 1)
        try await owners.waitUntilIdle()
        await service.clear(removeModel: false)
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
    }

    @Test func defaultProjectorWorkerSharesMutationAdmissionWithItsNativeChild() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let vectors = String(decoding: try JSONEncoder().encode([semanticVector()]), as: UTF8.self)
        let source = root.appendingPathComponent("model.sh"), projector = root.appendingPathComponent("projector")
        try Data("while IFS= read -r line; do printf '%s\\n' '{\"entries\":[],\"embeddings\":\(vectors)}'; done\n".utf8).write(to: source)
        try Data("projector".utf8).write(to: projector)
        let owners = SemanticEmbeddingOwners(), models = ArtifactModels(source: source)
        var worker: SemanticMediaWorker? = SemanticMediaWorker(helper: URL(fileURLWithPath: "/bin/sh"),
            model: source, projector: projector, models: models, embeddingOwners: owners)
        #expect(try worker?.embed(.init(kind: .image, path: "/private-fixture"), cancelled: { false }) == semanticVector())
        #expect(owners.media.native.isOccupied)
        #expect(throws: AskFileReadError.self) { try owners.mutation(.projector) }
        worker = nil
        try await owners.waitUntilIdle()
        let mutation = try owners.mutation(.projector); mutation.finish()
        #expect(models.fetches == 0 && models.installs == 0)
    }

    @Test func revokedScopeBeforeTaskStartsDoesNotFetchOrInstall() async throws {
        let (base, root, reader, original) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owners = SemanticEmbeddingOwners(), models = ArtifactModels(source: original.source)
        let service = fixture(root, settings: base.settings, reader: reader, models: models, owners: owners)
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        service.downloadModel()
        #expect(service.setEnabled(false))
        try await owners.waitUntilIdle()
        #expect(service.phase == .off && !service.modelReady)
        #expect(models.fetches == 0 && models.installs == 0)
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path))
        await service.clear()
    }
}
