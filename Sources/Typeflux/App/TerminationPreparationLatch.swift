import Foundation

/// Runs termination preparation at most once successfully. Once it has succeeded, a later quit
/// must not prepare again: the feature processes it would talk to are already gone. Concurrent
/// callers share the running attempt; a refused attempt can be retried.
@MainActor
final class TerminationPreparationLatch {
    private var succeeded = false
    private var inFlight: Task<Bool, Never>?

    var hasSucceeded: Bool { succeeded }

    func run(_ body: @escaping @MainActor () async -> Bool) async -> Bool {
        if succeeded { return true }
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in await body() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if result { succeeded = true }
        return result
    }
}
