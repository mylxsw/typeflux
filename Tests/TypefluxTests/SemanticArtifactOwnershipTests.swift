import CryptoKit
import Foundation
import XCTest
@testable import Typeflux

final class SemanticArtifactOwnershipTests: XCTestCase {
    func testModelMutationExcludesAllReadersAndDuplicateFinishCannotFreeNewLease() throws {
        let owners = SemanticEmbeddingOwners()
        let first = try owners.mutation(.model)
        for owner in [owners.query, owners.indexing, owners.media] {
            XCTAssertThrowsError(try owner.perform(cancelled: { false }) { XCTFail("Admitted during mutation") })
            XCTAssertFalse(owner.isIdle)
        }
        XCTAssertThrowsError(try owners.mutation(.model))
        XCTAssertThrowsError(try owners.mutation(.projector))
        first.finish()
        let second = try owners.mutation(.model)
        first.finish()
        XCTAssertThrowsError(try owners.query.perform(cancelled: { false }) { 1 })
        second.finish()
        XCTAssertEqual(try owners.query.perform(cancelled: { false }) { 2 }, 2)
    }

    func testProjectorOnlyExcludesMediaAndPartialAdmissionRollsBack() throws {
        let owners = SemanticEmbeddingOwners()
        var lease: SemanticEmbeddingOwners.Mutation? = try owners.mutation(.projector)
        XCTAssertNotNil(lease)
        XCTAssertEqual(try owners.query.perform(cancelled: { false }) { 1 }, 1)
        XCTAssertEqual(try owners.indexing.perform(cancelled: { false }) { 2 }, 2)
        XCTAssertThrowsError(try owners.mutation(.model))
        XCTAssertEqual(try owners.query.perform(cancelled: { false }) { 3 }, 3)
        XCTAssertEqual(try owners.indexing.perform(cancelled: { false }) { 4 }, 4)
        lease = nil
        XCTAssertTrue(owners.media.isIdle)
        let next = try owners.mutation(.model); next.finish()
    }

    func testChildAndHostRetirementBothRequiredWithoutStoppingOrReplaying() throws {
        let owners = SemanticEmbeddingOwners()
        let id = try owners.query.native.reserve { false }
        try owners.query.native.begin(id)
        XCTAssertThrowsError(try owners.mutation(.model))
        let projector = try owners.mutation(.projector); projector.finish()
        owners.query.native.reaped(id)
        XCTAssertThrowsError(try owners.mutation(.model))
        owners.query.native.end(id)
        try owners.indexing.perform(cancelled: { false }) {
            XCTAssertThrowsError(try owners.mutation(.model))
        }
        XCTAssertTrue(owners.query.isIdle)
        let mutation = try owners.mutation(.model); mutation.finish()
    }

    func testProjectorRefusalHappensBeforeFetchAndPreservesExistingArtifact() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), projector = root.appendingPathComponent("projector")
        try Data("old".utf8).write(to: projector); try Data("new".utf8).write(to: source)
        let owners = SemanticEmbeddingOwners(), id = try owners.media.native.reserve { false }
        let models = ArtifactModels(source: source); models.rejectVerification = true
        let encoder = SemanticFixtureMediaEncoder()
        let worker = SemanticMediaWorker(helper: source, model: source, projector: projector, models: models,
            makeEncoder: { _, _, _ in encoder }, embeddingOwners: owners)
        XCTAssertThrowsError(try worker.embed(.init(kind: .image, path: "/private-fixture"), cancelled: { false }))
        XCTAssertEqual(models.fetches, 0); XCTAssertEqual(try Data(contentsOf: projector), Data("old".utf8))
        owners.media.native.reaped(id)
        XCTAssertEqual(models.fetches, 0, "Retirement cannot restart download")
        XCTAssertEqual(try worker.embed(.init(kind: .image, path: "/private-fixture"), cancelled: { false }), semanticVector())
        XCTAssertEqual(models.fetches, 1); XCTAssertEqual(models.installs, 1)
        XCTAssertTrue(owners.media.isIdle)
    }

    func testInstallValidatesCopiedBytesBeforeReplacingExistingModel() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let bytes = Data("good".utf8), old = Data("old!".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: source); try old.write(to: target)
        var checks = 0
        XCTAssertThrowsError(try SemanticModel.install(source, to: target, bytes: 4, sha256: hash) {
            checks += 1
            if checks == 2 { try? Data("evil".utf8).write(to: source) }
            return false
        })
        XCTAssertEqual(try Data(contentsOf: target), old)
        try bytes.write(to: source)
        try SemanticModel.install(source, to: target, bytes: 4, sha256: hash, cancelled: { false })
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["source", "target"])
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}

final class ArtifactModels: SemanticModelHandling, @unchecked Sendable {
    let source: URL
    var rejectVerification = false
    var blockInstall = false
    let entered = AskSearchCancellation()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var fetched = 0, installed = 0
    var fetches: Int { lock.withLock { fetched } }
    var installs: Int { lock.withLock { installed } }
    init(source: URL) { self.source = source }
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        if rejectVerification || !FileManager.default.fileExists(atPath: url.path) { throw URLError(.fileDoesNotExist) }
    }
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        lock.withLock { fetched += 1 }; progress(4)
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, HTTPURLResponse(url: URL(string: "https://fixture.invalid/model")!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!)
    }
    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        lock.withLock { installed += 1 }
        if blockInstall {
            entered.cancel()
            guard release.wait(timeout: .now() + 8) == .success else { throw AskFileReadError.timeout }
            // Deliberately ignore later cancellation: dispatched filesystem work can finish.
        }
        try Data(contentsOf: url).write(to: target)
    }
}
