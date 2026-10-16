import Foundation

/// A service keeps separate query, document and media lineages across worker
/// replacement. Neither a blocked host operation nor an unreaped child frees it.
final class SemanticEmbeddingOwnership: @unchecked Sendable {
    let native = AskFileReaderOwnership()
    private let state = NSLock()
    private var occupied = false

    private func acquire(requireRetired: Bool) -> Bool {
        state.withLock {
            guard !occupied, !requireRetired || !native.isOccupied else { return false }
            occupied = true; return true
        }
    }
    fileprivate func acquireMutation() -> Bool { acquire(requireRetired: true) }
    fileprivate func release() { state.withLock { occupied = false } }

    func perform<T>(cancelled: () -> Bool, _ body: () throws -> T) throws -> T {
        guard !cancelled() else { throw CancellationError() }
        guard acquire(requireRetired: false) else { throw AskFileReadError.unavailable }
        defer { release() }
        guard !cancelled() else { throw CancellationError() }
        let result = try body()
        guard !cancelled() else { throw CancellationError() }
        return result
    }

    var isIdle: Bool {
        state.withLock { !occupied && !native.isOccupied }
    }
}

final class SemanticEmbeddingOwners: @unchecked Sendable {
    enum Artifact { case model, projector }
    let query = SemanticEmbeddingOwnership()
    let indexing = SemanticEmbeddingOwnership()
    let media = SemanticEmbeddingOwnership()

    /// Admission only: no waiting, filesystem work, cancellation or producer replay.
    /// The lease may cross actors; no thread-owned lock crosses an await.
    func mutation(_ artifact: Artifact) throws -> Mutation {
        let owners = artifact == .model ? [query, indexing, media] : [media]
        var acquired: [SemanticEmbeddingOwnership] = []
        for owner in owners {
            guard owner.acquireMutation() else {
                acquired.forEach { $0.release() }
                throw AskFileReadError.unavailable
            }
            acquired.append(owner)
        }
        return Mutation(acquired)
    }

    final class Mutation: @unchecked Sendable {
        private let owners: [SemanticEmbeddingOwnership]
        private let state = NSLock()
        private var finished = false
        fileprivate init(_ owners: [SemanticEmbeddingOwnership]) { self.owners = owners }
        func finish() {
            state.withLock {
                guard !finished else { return }
                finished = true; owners.forEach { $0.release() }
            }
        }
        deinit { finish() }
    }

    // Only the process stop handle is thread safe. Reader FD/cache cleanup stays
    // on each worker's serial owner, even when the service is released on UI.
    func stop() { for owner in [query, indexing, media] { owner.native.stopOwned() } }

    func waitUntilIdle(timeout: TimeInterval = 2) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ![query, indexing, media].allSatisfy({ $0.isIdle }) {
            guard ContinuousClock.now < deadline else { throw AskFileReadError.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
