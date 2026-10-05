import Foundation

/// Created only before dispatch. A failed preparation has no unknown side effect.
struct AskToolPreparationFailure: LocalizedError {
    let message: String
    let status: AskExecutionStatus

    init(_ error: Error) {
        if let failure = error as? Self {
            self = failure
            return
        }
        switch error {
        case AskObservationError.disabled:
            message = L("ask.tool.automationUnavailable")
            status = .denied
        case AskObservationError.needsObservation:
            message = L("ask.tool.observationExpired")
            status = .invalid
        case AskObservationError.invalid:
            message = L("ask.tool.invalid")
            status = .invalid
        case AskProjectError.denied, AskArtifactError.denied,
             AskProjectRuntimeError.disabled, AskProjectRuntimeError.denied:
            message = error.localizedDescription
            status = .denied
        default:
            message = error.localizedDescription
            status = .invalid
        }
    }

    var errorDescription: String? {
        message
    }

    var outcome: AskExecutionOutcome {
        .init(status: status.rawValue, eventDispatched: false, effectVerified: false)
    }
}

extension AskToolExecuting {
    /// Keep this boundary separate from executeApproved, which may dispatch effects.
    func preparedBinding(for call: AskToolCall, conversationId: String) async throws -> AskToolBinding {
        try Task.checkCancellation()
        do {
            return try await approvalBinding(for: call, conversationId: conversationId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw AskToolPreparationFailure(error)
        }
    }
}
