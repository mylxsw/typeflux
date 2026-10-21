import Foundation

/// Synchronous host budget state, independent of adapter-private snapshots.
protocol AskBudgetJournaling: Sendable {
    func update(conversation: String, root: String, initial: AskBudgetController?,
                _ change: (inout AskBudgetController) throws -> Void) throws -> AskBudgetController
}
