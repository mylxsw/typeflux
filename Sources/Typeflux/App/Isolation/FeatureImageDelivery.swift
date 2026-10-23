import Foundation

/// Preserve the original encoded capture if either private staging or delivery
/// fails. The producer stays busy through the fallback save and acknowledgement.
@MainActor
enum FeatureImageDelivery {
    enum Outcome: Equatable { case delivered, saved(URL) }
    static func deliver(_ data: Data,
        write: @escaping @Sendable (Data, UUID) throws -> Void = { try FeatureImageTransfer.write($0, id: $1) },
        send: @MainActor (UUID) async throws -> Void,
        save: @MainActor (Data) async throws -> URL) async throws -> Outcome {
        let id = UUID()
        defer { FeatureImageTransfer.remove(id) }
        do {
            try await Task.detached(priority: .userInitiated) { try write(data, id) }.value
            try await send(id)
            return .delivered
        } catch {
            return try await .saved(save(data))
        }
    }
}
