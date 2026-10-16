import Foundation

/// A service keeps separate query, document and media lineages across worker
/// replacement. Neither a blocked host operation nor an unreaped child frees it.
final class SemanticEmbeddingOwnership: @unchecked Sendable {
    let native = AskFileReaderOwnership()
    private let operation = NSLock()

    func perform<T>(cancelled: () -> Bool, _ body: () throws -> T) throws -> T {
        guard !cancelled() else { throw CancellationError() }
        guard operation.try() else { throw AskFileReadError.unavailable }
        defer { operation.unlock() }
        guard !cancelled() else { throw CancellationError() }
        let result = try body()
        guard !cancelled() else { throw CancellationError() }
        return result
    }

    var isIdle: Bool {
        guard operation.try() else { return false }
        defer { operation.unlock() }
        return !native.isOccupied
    }
}

final class SemanticEmbeddingOwners: @unchecked Sendable {
    let query = SemanticEmbeddingOwnership()
    let indexing = SemanticEmbeddingOwnership()
    let media = SemanticEmbeddingOwnership()

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
