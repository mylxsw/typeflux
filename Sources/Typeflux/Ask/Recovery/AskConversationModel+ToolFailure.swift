import Foundation

extension AskConversationModel {
    /// Settle a rejected preparation without granting authority or dispatching the tool.
    func rejectToolPreparation(_ failure: AskToolPreparationFailure, call: AskToolCall,
                               value: AskConversation, identity: AskExecutionIdentity,
                               current: AskRoute) async throws -> AskToolResultRequest? {
        try Task.checkCancellation()
        guard session()?.owner == current.account else { throw CancellationError() }
        let latest = try await api.conversation(id: value.id, token: current.token)
        try await accept(latest, route: current)
        try Task.checkCancellation()
        guard session()?.owner == current.account else { throw CancellationError() }
        guard let run = snapshots[value.id]?.run, run.id == identity.runId,
              run.deviceId == identity.deviceId, run.status == "waiting_tool",
              !run.needsRecoveryInspection, run.pending.first == call else { return nil }
        let receipt = AskToolResultRequest(
            runId: identity.runId, deviceId: identity.deviceId, toolCallId: call.id,
            content: L("ask.tool.notExecuted", failure.message), isError: true,
            harness: .init(version: 1, outcome: failure.outcome)
        )
        // No target binding or approval was obtained. This version describes only
        // the refusal record, never a tool definition or an execution permission.
        let audit = AskExecutionAudit(identity: identity, toolVersion: "preparation-refusal-v1",
                                      toolName: call.function.name,
                                      argumentsHash: AskToolPolicy.digest(call.function.arguments))
        try await cache.saveRejectedToolReceipt(audit: audit, receipt: receipt, owner: current.owner)
        return receipt
    }

    func deliverToolResult(_ result: AskToolResultRequest, identity: AskExecutionIdentity,
                           current: AskRoute) async throws -> AskConversation {
        try Task.checkCancellation()
        guard session()?.owner == current.account else { throw CancellationError() }
        if result.approveExecution == true {
            guard let approval = cloudApprovals[identity.key],
                  approvalStore.validateDispatch(approval.id, for: approval.request) else {
                throw AskLocalError.message(L("ask.approval.changed"))
            }
        }
        let response = try await api.result(conversationId: identity.conversationId,
                                            request: result, token: current.token)
        try await cache.recordExecution(id: identity.key, event: .acknowledged, owner: current.owner)
        cloudApprovals[identity.key] = nil
        return response
    }
}
