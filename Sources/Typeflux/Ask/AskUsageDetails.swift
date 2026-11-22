import Combine
import Foundation

/// Invocation paging scoped to one account, conversation and run.
@MainActor
final class AskUsageDetails: ObservableObject {
    @Published private(set) var items: [AskUsageInvocation] = []
    @Published private(set) var cursor: Int64?
    @Published private(set) var loading = false
    @Published private(set) var loadError = false
    private var loadedPages = 0
    private var generation = UUID()
    private var currentKey: String?

    func load(key: String, hasRecords: Bool, reset: Bool,
              page: (Int64?) async throws -> AskUsagePage) async {
        guard reset || currentKey != key || !loading else { return }
        let request = UUID()
        generation = request
        if currentKey != key || !hasRecords {
            items = []
            cursor = nil
            loadedPages = 0
        }
        currentKey = key
        let backgroundRefresh = reset && !items.isEmpty
        loadError = false
        loading = hasRecords
        guard hasRecords else { return }
        do {
            var next = reset ? nil : cursor
            var updated = reset ? [] : items
            var seen = Set(updated.map(\.id))
            var pages = reset ? 0 : loadedPages
            let limit = reset ? max(1, loadedPages) : loadedPages + 1
            repeat {
                let result = try await page(next)
                guard generation == request else { return }
                try Task.checkCancellation()
                updated += result.items.filter { seen.insert($0.id).inserted }
                next = result.nextCursor
                pages += 1
            } while next != nil && pages < limit
            if reset && next != nil {
                updated += items.filter { seen.insert($0.id).inserted }
            }
            // Some servers page by modification version. Settlement must not
            // move an old call above newer ones in the visible list.
            updated.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            if items != updated { items = updated }
            cursor = next
            loadedPages = pages
        } catch {
            guard generation == request else { return }
            loadError = !backgroundRefresh && !Task.isCancelled && !(error is CancellationError)
        }
        loading = false
    }
}
