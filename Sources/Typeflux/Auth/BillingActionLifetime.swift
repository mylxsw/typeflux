import Combine
import Foundation

/// Owns one billing button request. A cancelled request cannot release the
/// busy state of a later request or deliver browser/navigation side effects.
@MainActor
final class BillingActionLifetime: ObservableObject {
    @Published private(set) var isBusy = false
    private(set) var task: Task<Void, Never>?
    private var owner = UUID()

    nonisolated init() {}

    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        let owner = UUID()
        self.owner = owner
        isBusy = true
        task = Task {
            defer {
                if self.owner == owner {
                    self.isBusy = false
                    self.task = nil
                }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        owner = UUID()
        task?.cancel()
        task = nil
        isBusy = false
    }
}
