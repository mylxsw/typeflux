import Foundation

/// A service keeps separate query, document and media lineages across worker
/// replacement. Neither a blocked host operation nor an unreaped child frees it.
final class SemanticEmbeddingOwnership: @unchecked Sendable {
    let native = AskFileReaderOwnership()
    private let state = NSLock()
    private var occupied = false
    private let requiresLifecycle: Bool
    private var gate: ModuleWorkerGate?
    private var waiter: CheckedContinuation<Void, Never>?
    struct Authorization: Sendable { let generation: UUID? }

    init(requiresLifecycle: Bool = false) { self.requiresLifecycle = requiresLifecycle }
    func bind(_ gate: ModuleWorkerGate) -> Bool {
        state.withLock {
            guard self.gate == nil, !occupied,
                  native.bind(gate, invalidate: {}) else { return false }
            self.gate = gate; return true
        }
    }
    func authorization() -> Authorization { state.withLock { .init(generation: try? gate?.admit()) } }
    func permits(_ authorization: Authorization) -> Bool {
        state.withLock { gate.map { $0.permits(authorization.generation) } ?? !requiresLifecycle }
    }
    func invalidVector(_ authorization: Authorization) {
        state.withLock { gate?.failed(authorization.generation, configuration: false) }
        native.stopOwned()
    }
    func retireManaged() async {
        native.stopOwned()
        await withCheckedContinuation { continuation in
            let done = state.withLock {
                guard occupied else { return true }
                waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
        await native.waitUntilRetired()
    }

    private func acquire(requireRetired: Bool) -> Bool {
        state.withLock {
            guard !occupied, !requireRetired || !native.isOccupied else { return false }
            occupied = true; return true
        }
    }
    fileprivate func acquireMutation() -> Bool { acquire(requireRetired: true) }
    fileprivate func release() {
        let (waiter, gate) = state.withLock {
            occupied = false
            let pending = self.waiter; self.waiter = nil
            return (pending, self.gate)
        }
        waiter?.resume(); gate?.changed()
    }

    func perform<T>(authorization: Authorization? = nil, cancelled: () -> Bool, _ body: () throws -> T) throws -> T {
        let authorization = authorization ?? self.authorization()
        guard permits(authorization) else { throw AskFileReadError.unavailable }
        guard !cancelled() else { throw CancellationError() }
        guard acquire(requireRetired: false) else { throw AskFileReadError.unavailable }
        defer { release() }
        guard permits(authorization) else { throw AskFileReadError.unavailable }
        guard !cancelled() else { throw CancellationError() }
        let result = try body()
        guard !cancelled() else { throw CancellationError() }
        guard permits(authorization) else { throw AskFileReadError.unavailable }
        return result
    }

    var isIdle: Bool {
        state.withLock { !occupied && !native.isOccupied }
    }
}

final class SemanticEmbeddingOwners: @unchecked Sendable {
    enum Artifact { case model, projector }
    let query: SemanticEmbeddingOwnership
    let indexing: SemanticEmbeddingOwnership
    let media: SemanticEmbeddingOwnership
    init(requiresLifecycle: Bool = false) {
        query = .init(requiresLifecycle: requiresLifecycle)
        indexing = .init(requiresLifecycle: requiresLifecycle)
        media = .init(requiresLifecycle: requiresLifecycle)
    }
    struct Authorization: Sendable {
        let query, indexing, media: SemanticEmbeddingOwnership.Authorization
    }
    func authorization() -> Authorization {
        .init(query: query.authorization(), indexing: indexing.authorization(), media: media.authorization())
    }

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
