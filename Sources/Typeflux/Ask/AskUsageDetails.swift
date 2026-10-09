import Combine
import Foundation

/// Invocation paging scoped to one conversation, run and usage revision.
@MainActor
final class AskUsageDetails: ObservableObject {
    @Published private(set) var items: [AskUsageInvocation] = []
    @Published private(set) var cursor: Int64?
    @Published private(set) var loading = false
    @Published private(set) var loadError = false
    private var generation = UUID()
    private var currentKey: String?

    func load(key: String, hasRecords: Bool, reset: Bool,
              page: (Int64?) async throws -> AskUsagePage) async {
        guard reset || currentKey != key || !loading else { return }
        let request = UUID()
        generation = request
        if reset || currentKey != key || !hasRecords {
            items = []; cursor = nil
        }
        currentKey = key
        loadError = false
        loading = hasRecords
        guard hasRecords else { return }
        do {
            let value = try await page(cursor)
            guard generation == request else { return }
            if !Task.isCancelled {
                var existing = Set(items.map(\.id))
                items += value.items.filter { existing.insert($0.id).inserted }
                cursor = value.nextCursor
            }
        } catch {
            guard generation == request else { return }
            loadError = !Task.isCancelled && !(error is CancellationError)
        }
        loading = false
    }
}
