import Foundation

struct AskReadBatchProgress: Equatable {
    var runID: String
    var running: Set<String> = []
    var completed: [AskMessage] = []
}

private struct AskPreparedRead: Sendable {
    let call: AskToolCall
    let identity: AskExecutionIdentity
    let request: AskApprovalRequest
    let grant: String
    let permissionRevision: String
}

extension AskConversationModel {
    /// Manual consent, mutations and recovery are barriers. Automatic approval still
    /// produces a distinct, single-use grant and journal entry for every invocation.
    func driveReadBatch(_ value: AskConversation, current: AskRoute, operationId: UUID) async throws -> AskConversation? {
        guard let run = value.run, run.status == "waiting_tool", !run.needsRecoveryInspection,
              run.recoveryCheck != true, run.pending.count > 1 else { return nil }
        var prepared: [AskPreparedRead] = []
        defer { for entry in prepared { approvalStore.revoke(entry.grant) } }
        for call in run.pending.prefix(3) {
            let cloud = run.approvalTool(for: call)
            let independent = cloud != nil ? ["web_search", "web_fetch"].contains(call.function.name)
                : await tools.allowsConcurrentRead(call)
            guard independent, cloud != nil || value.dispatchKind.offers(call.function.name),
                  AskSkillCatalog.permits(call, catalog: value.messages.last(where: { $0.role == "user" })?.skillCatalog),
                  automaticallyApproves(call, risk: toolRisk(call, cloudDefinition: cloud), conversationId: value.id) else { break }
            let identity = AskExecutionIdentity(owner: current.account, conversation: value, run: run, callId: call.id, kind: "tool")
            // Recovery and retransmission keep their existing single-call path.
            guard try await cache.execution(id: identity.key, owner: current.owner) == nil else { break }
            let binding: AskToolBinding
            do { binding = try await preparedToolBinding(call, conversationId: value.id, cloudDefinition: cloud) }
            catch { break } // The ordinary path records the precise preparation refusal.
            guard !binding.requiresExplicitConsent else { break }
            let request = AskToolPolicy.request(call: call, owner: current.account, conversation: value.id,
                                                run: run.id, step: String(run.steps), binding: binding,
                                                risk: toolRisk(call, cloudDefinition: cloud), reuseEnabled: false,
                                                now: approvalStore.now())
            guard let grant = approvalStore.issue(request) else { break }
            prepared.append(.init(call: call, identity: identity, request: request, grant: grant,
                                  permissionRevision: modelLibrary.settings.toolPermissionRevision))
        }
        guard prepared.count > 1 else { return nil }
        try checkOperation(value.id, operationId: operationId, account: current.account)
        let latest = try await api.conversation(id: value.id, token: current.token)
        guard latest.run == run else { return nil }
        try await accept(latest, route: current, operationId: operationId)
        tools.bindExecution(ownerId: current.account, conversationId: value.id, runId: run.id,
                            deviceId: deviceId, persistent: !isTemporary(value.id))
        tools.setExecutionDeadline(run.budgetEnabled == true ? run.budgetDeadline : nil, conversationId: value.id)
        let entries = prepared
        readBatchProgress[value.id] = .init(runID: run.id)
        defer {
            if readBatchProgress[value.id]?.runID == run.id { readBatchProgress[value.id] = nil }
        }
        guard let response = try await api.readBatch(conversationId: value.id, runId: run.id,
                                                      calls: entries.map(\.call), token: current.token,
                                                      execute: { [self] call, builtin in
            guard let entry = entries.first(where: { $0.call == call }) else { throw AskRecoveryError.unknown }
            return try await executePreparedRead(entry, value: value, current: current,
                                                 operationId: operationId, builtin: builtin)
        }) else { return nil }
        for entry in entries where response.run?.id == run.id && response.run?.status != "cancelled" && response.messages.contains(where: {
            $0.role == "tool" && $0.toolCallId == entry.call.id && $0.runId == run.id
        }) {
            // Budget admission can stop the run before any execution claim exists.
            guard let saved = try await cache.execution(id: entry.identity.key, owner: current.owner),
                  saved.receipt?.matches(entry.identity) == true else { continue }
            try await acknowledgeExecution(entry.identity, response: response, current: current)
        }
        try await accept(response, route: current, operationId: operationId)
        return response
    }

    private func executePreparedRead(_ entry: AskPreparedRead, value: AskConversation, current: AskRoute,
                                     operationId: UUID, builtin: AskBuiltinReadOperation?) async throws -> AskToolResultRequest {
        let call = entry.call
        let run = value.run!
        func authorize() throws {
            try Task.checkCancellation()
            try checkOperation(value.id, operationId: operationId, account: current.account)
            guard session()?.owner == current.account,
                  modelLibrary.settings.toolPermissionRevision == entry.permissionRevision,
                  automaticallyApproves(call, risk: entry.request.risk, conversationId: value.id),
                  let live = snapshots[value.id]?.run, live.id == run.id, live.deviceId == run.deviceId,
                  live.agentBinding == run.agentBinding, ["waiting_tool", "running"].contains(live.status),
                  live.pending.contains(call), !live.needsRecoveryInspection,
                  approvalStore.validateDispatch(entry.grant, for: entry.request) else {
                throw AskLocalError.message(L("ask.approval.changed"))
            }
            _ = try AskAgentBinding.resolve(live.agentBinding)
            if run.budgetEnabled == true, let deadline = run.budgetDeadline, Date() >= deadline {
                throw AskBudgetError.reached("duration")
            }
        }
        // Claim before any effect, and keep each completed receipt even when its siblings fail.
        let audit = AskExecutionAudit(identity: entry.identity, toolVersion: entry.request.binding.toolVersion,
                                      toolName: call.function.name, argumentsHash: entry.request.context.argumentsHash,
                                      approvalId: entry.grant, approvedAt: approvalStore.now())
        guard try await cache.claimExecution(audit, owner: current.owner) else { throw AskRecoveryError.unknown }
        var context = entry.request.context
        context.approvalId = entry.grant
        var result = AskToolResultRequest(runId: run.id, deviceId: run.deviceId, toolCallId: call.id,
            content: "Tool was not dispatched.", isError: true,
            harness: .init(version: 1, context: context, approval: approvalStore.auditScope(entry.grant),
                           outcome: .init(status: "denied")))
        do {
            let binding = try await preparedToolBinding(call, conversationId: value.id, cloudDefinition: run.approvalTool(for: call))
            guard binding == entry.request.binding,
                  approvalStore.consume(entry.grant, for: entry.request) else {
                throw AskLocalError.message(L("ask.approval.changed"))
            }
            try authorize()
            result.harness?.approval = approvalStore.auditScope(entry.grant)
            readBatchProgress[value.id]?.running.insert(call.id)
            result.harness?.outcome?.status = "unknown"
            let output: AskLocalToolOutput
            if let builtin {
                output = await builtin()
            } else {
                guard await tools.allowsConcurrentRead(call) else { throw AskLocalError.message(L("ask.approval.changed")) }
                output = try await tools.executeApproved(call, conversationId: value.id, binding: binding, authorize: authorize)
            }
            result.record(output)
        } catch {
            result.content = error.localizedDescription
            result.isError = true
            if let failure = error as? AskToolPreparationFailure { result.harness?.outcome = failure.outcome }
            else if error is CancellationError { result.harness?.outcome?.status = "cancelled" }
            else if case MCPClientError.timedOut = error { result.harness?.outcome?.status = "timeout" }
            else if error is MCPInputError { result.harness?.outcome?.status = "invalid" }
        }
        if let scope = approvalStore.auditScope(entry.grant) { result.harness?.approval = scope }
        try await cache.saveReceipt(.tool(result), identity: entry.identity, owner: current.owner)
        if readBatchProgress[value.id]?.runID == run.id {
            readBatchProgress[value.id]?.running.remove(call.id)
            readBatchProgress[value.id]?.completed.append(result.message(step: run.steps, now: Date()))
        }
        return result
    }
}
