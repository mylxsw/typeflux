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
        _ = try AskAgentBinding.resolve(run.agentBinding)
        let receipt = AskToolResultRequest(
            approveExecution: value.run?.approvalTool(for: call) != nil ? false : nil,
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
                           current: AskRoute, operationId: UUID? = nil) async throws -> AskConversation {
        let response = try await sendToolResult(result, identity: identity, current: current, operationId: operationId)
        try await acknowledgeExecution(identity, response: response, current: current)
        cloudApprovals[identity.key] = nil
        return response
    }

    /// Transport only. A saved approval is an execution intent and needs live authority;
    /// completed receipts can reconcile their original execution without another grant.
    func sendToolResult(_ result: AskToolResultRequest, identity: AskExecutionIdentity,
                        current: AskRoute, operationId: UUID? = nil) async throws -> AskConversation {
        let generation = recoveryGeneration
        let operation = operationId ?? operationGenerations[identity.conversationId]
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard session()?.owner == current.account, identity.owner == current.account,
                  identity.deviceId == deviceId,
                  recoveryGeneration == generation,
                  operationGenerations[identity.conversationId] == operation else { throw CancellationError() }
        }
        try checkCurrent()
        guard AskExecutionReceipt.tool(result).matches(identity) else { throw AskRecoveryError.unknown }
        if result.approveExecution == true {
            let latest = try await api.conversation(id: identity.conversationId, token: current.token)
            try checkCurrent()
            try await accept(latest, route: current)
            try checkCurrent()
            guard let snapshot = snapshots[identity.conversationId] else { throw AskRecoveryError.unknown }
            if snapshot.messages.contains(where: {
                $0.role == "tool" && $0.toolCallId == identity.callId &&
                    ($0.runId == identity.runId || ($0.runId == nil && snapshot.run?.id == identity.runId))
            }) { return snapshot }
            guard let run = snapshot.run, run.id == identity.runId, run.deviceId == identity.deviceId,
                  String(run.steps) == identity.stepId, run.budgetRootId == identity.rootId,
                  run.status == "waiting_tool", !run.needsRecoveryInspection,
                  let call = run.pending.first, call.id == identity.callId,
                  let definition = run.approvalTool(for: call),
                  let approval = cloudApprovals[identity.key],
                  approval.request.context.ownerId == identity.owner,
                  approval.request.context.conversationId == identity.conversationId,
                  approval.request.context.runId == identity.runId,
                  approval.request.context.stepId == identity.stepId,
                  approval.request.context.toolCallId == identity.callId,
                  approval.request.context.toolName == call.function.name,
                  approval.request.context.argumentsHash == AskToolPolicy.digest(call.function.arguments) else {
                throw AskLocalError.message(L("ask.recovery.approvalChanged"))
            }
            _ = try AskAgentBinding.resolve(run.agentBinding)
            if run.recoveryCheck == true, !run.permitsRecoveryTool(call) {
                throw AskLocalError.message(L("ask.recovery.readOnly"))
            }
            let binding = try await preparedToolBinding(call, conversationId: snapshot.id, cloudDefinition: definition)
            try checkCurrent()
            guard snapshots[snapshot.id]?.run == run,
                  binding == approval.request.binding,
                  approvalStore.validateDispatch(approval.id, for: approval.request) else {
                throw AskLocalError.message(L("ask.recovery.approvalChanged"))
            }
        }
        return try await api.result(conversationId: identity.conversationId,
                                    request: result, token: current.token)
    }
}
