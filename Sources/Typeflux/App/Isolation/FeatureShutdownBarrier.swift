import Foundation

/// Own cleanup independently of RPC cancellation. A timed-out request can retry
/// the same drain without starting overlapping storage/module shutdowns.
@MainActor
final class FeatureShutdownBarrier {
    private var generation = UUID()
    private var task: Task<Void, Error>?

    func run(_ cleanup: @escaping @MainActor () async throws -> Void) async throws {
        if task == nil {
            generation = UUID()
            task = Task { try await cleanup() }
        }
        let owned = generation
        guard let current = task else { return }
        do {
            try await current.value
        } catch {
            if generation == owned { task = nil }
            throw error
        }
    }
}
