import Foundation
import Testing
@testable import Typeflux

private final class MediaAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if released { return true }
                self.continuation = continuation; return false
            }
            if immediate { continuation.resume() }
        }
    }
    func release() {
        let saved = lock.withLock { released = true; let saved = continuation; continuation = nil; return saved }
        saved?.resume()
    }
}

private final class MediaAdmissionModels: SemanticModelHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var verifications = 0, transfers = 0, installations = 0
    private var temporary: URL?
    let source: URL
    let missing: Bool
    let gate: MediaAdmissionGate?
    let onVerify: @Sendable () -> Void
    let onInstall: @Sendable () -> Void
    init(source: URL, missing: Bool = false, gate: MediaAdmissionGate? = nil,
         onVerify: @escaping @Sendable () -> Void = {}, onInstall: @escaping @Sendable () -> Void = {}) {
        self.source = source; self.missing = missing; self.gate = gate
        self.onVerify = onVerify; self.onInstall = onInstall
    }
    var counts: [Int] { lock.withLock { [verifications, transfers, installations] } }
    var downloaded: URL? { lock.withLock { temporary } }
    // Deliberately uncooperative: the caller must own admission and delivery.
    func verify(_: URL, cancelled _: @Sendable () -> Bool) throws {
        lock.withLock { verifications += 1 }; onVerify()
        if missing { throw URLError(.fileDoesNotExist) }
    }
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        lock.withLock { transfers += 1 }; progress(100)
        if let gate { await gate.wait() }
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: copy)
        lock.withLock { temporary = copy }
        return (copy, HTTPURLResponse(url: URL(string: "https://example.invalid/private-fixture")!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!)
    }
    func install(_ url: URL, to target: URL, cancelled _: @Sendable () -> Bool) throws {
        lock.withLock { installations += 1 }; onInstall()
        try FileManager.default.copyItem(at: url, to: target)
    }
}

private final class MediaAdmissionEncoder: SemanticMediaEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0, factories = 0
    let onEmbed: @Sendable () -> Void
    init(onEmbed: @escaping @Sendable () -> Void = {}) { self.onEmbed = onEmbed }
    var counts: [Int] { lock.withLock { [factories, calls] } }
    func make() -> MediaAdmissionEncoder { lock.withLock { factories += 1 }; return self }
    func embed(_: SemanticMediaInput, cancelled _: () -> Bool) throws -> [Float] {
        lock.withLock { calls += 1 }; onEmbed(); return semanticVector()
    }
}

private final class MediaAdmissionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func append(_ value: Double?) { lock.withLock { values.append(value) } }
    var snapshot: [Double?] { lock.withLock { values } }
}

@Suite("Original media operation admission", .serialized)
struct SemanticMediaAdmissionTests {
    private func source(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("placeholder-model")
        try Data("private synthetic placeholder".utf8).write(to: url); return url
    }
    private let input = SemanticMediaInput(kind: .image, path: "/private-fixture/not-read.jpg")

    @Test func preCancelledColdAndCachedCallsNeverEnterModelsOrEncoder() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try source(root), models = MediaAdmissionModels(source: url), encoder = MediaAdmissionEncoder()
        let worker = SemanticMediaWorker(helper: url, model: url, projector: url, models: models,
                                         makeEncoder: { _, _, _ in encoder.make() })
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { true }) }
        #expect(models.counts == [0, 0, 0] && encoder.counts == [0, 0])
        #expect(try worker.embed(input, cancelled: { false }) == semanticVector())
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { true }) }
        #expect(models.counts == [1, 0, 0] && encoder.counts == [1, 1])
    }

    @Test(arguments: [false, true])
    func verificationRevocationCannotEnterDownloadOrFactory(_ missing: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root)
        let models = MediaAdmissionModels(source: url, missing: missing, onVerify: { token.cancel() })
        let encoder = MediaAdmissionEncoder()
        let worker = SemanticMediaWorker(helper: url, model: url, projector: url, models: models,
                                         makeEncoder: { _, _, _ in encoder.make() })
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { token.isCancelled }) }
        #expect(models.counts == [1, 0, 0] && encoder.counts == [0, 0])
    }

    @Test func factoryRevocationCannotEnterNativeCall() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root), encoder = MediaAdmissionEncoder()
        let worker = SemanticMediaWorker(helper: url, model: url, projector: url,
            models: MediaAdmissionModels(source: url), makeEncoder: { _, _, _ in
                token.cancel(); return encoder.make()
            })
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { token.isCancelled }) }
        #expect(encoder.counts == [1, 0])
    }

    @Test(arguments: [false, true])
    func enteredNativeResultCannotEscapeOriginalCancellation(_ cached: Bool) throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root)
        // First call builds the cache when requested; the selected later call revokes.
        let encoder = MediaAdmissionEncoder(), revoking = MediaAdmissionEncoder(onEmbed: { token.cancel() })
        let models = MediaAdmissionModels(source: url)
        let worker = SemanticMediaWorker(helper: url, model: url, projector: url, models: models,
                                         makeEncoder: { _, _, _ in (cached ? encoder : revoking).make() })
        if cached {
            _ = try worker.embed(input, cancelled: { false })
            // Revocation is observed by the post-call boundary even with a cached encoder.
            let cancellationSamples = AskSearchCancellation()
            #expect(throws: CancellationError.self) {
                try worker.embed(input, cancelled: {
                    if encoder.counts[1] == 2 { cancellationSamples.cancel() }
                    return cancellationSamples.isCancelled
                })
            }
            #expect(encoder.counts == [1, 2])
        } else {
            #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { token.isCancelled }) }
            #expect(revoking.counts == [1, 1])
        }
        #expect(models.counts == [1, 0, 0])
    }

    @Test func progressRevocationBeforeTransferKeepsTerminalResetAndReleasesMutation() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root), owners = SemanticEmbeddingOwners()
        let models = MediaAdmissionModels(source: url, missing: true), encoder = MediaAdmissionEncoder()
        let progress = MediaAdmissionProgress()
        let worker = SemanticMediaWorker(helper: url, model: url, projector: root.appendingPathComponent("projector"),
            models: models, makeEncoder: { _, _, _ in encoder.make() }, progress: {
                progress.append($0); if $0 == 0 { token.cancel() }
            }, embeddingOwners: owners)
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { token.isCancelled }) }
        #expect(models.counts == [1, 0, 0] && encoder.counts == [0, 0])
        #expect(progress.snapshot == [0, nil])
        let mutation = try owners.mutation(.projector); mutation.finish()
    }

    @Test func enteredInstallCannotBeRolledBackButCannotPrepareEncoder() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root), target = root.appendingPathComponent("projector")
        let models = MediaAdmissionModels(source: url, missing: true, onInstall: { token.cancel() })
        let encoder = MediaAdmissionEncoder()
        let worker = SemanticMediaWorker(helper: url, model: url, projector: target, models: models,
                                         makeEncoder: { _, _, _ in encoder.make() })
        #expect(throws: CancellationError.self) { try worker.embed(input, cancelled: { token.isCancelled }) }
        #expect(models.counts == [1, 1, 1] && encoder.counts == [0, 0])
        #expect(try Data(contentsOf: target) == Data(contentsOf: url))
    }

    @Test func cancelledUncooperativeTransferOwnsMutationUntilActualCollection() async throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = AskSearchCancellation(), url = try source(root), target = root.appendingPathComponent("projector")
        let gate = MediaAdmissionGate(), owners = SemanticEmbeddingOwners(), encoder = MediaAdmissionEncoder()
        let models = MediaAdmissionModels(source: url, missing: true, gate: gate), progress = MediaAdmissionProgress()
        let job = Task.detached {
            let worker = SemanticMediaWorker(helper: url, model: url, projector: target, models: models,
                makeEncoder: { _, _, _ in encoder.make() }, progress: { progress.append($0) }, embeddingOwners: owners)
            do {
                _ = try worker.embed(.init(kind: .image, path: "/private-fixture/not-read.jpg"),
                                     cancelled: { token.isCancelled })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.waiting, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.waiting)
        token.cancel()
        #expect(throws: AskFileReadError.self) { try owners.mutation(.projector) }
        #expect(models.counts == [1, 1, 0] && encoder.counts == [0, 0])
        gate.release()
        #expect(await job.value)
        #expect(models.counts == [1, 1, 0] && encoder.counts == [0, 0])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let temporary = try #require(models.downloaded)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(progress.snapshot.last == .some(nil))
        let mutation = try owners.mutation(.projector); mutation.finish()
    }
}
