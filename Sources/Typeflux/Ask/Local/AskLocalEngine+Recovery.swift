import Foundation

extension AskLocalEngine {
    func recover(conversationId: String, request: AskRecoveryRequest, token: String) async throws -> AskConversation {
        guard token.isEmpty else { throw AskLocalError.message(L("ask.local.conflict")) }
        var record = try record(conversationId)
        guard let run = record.conversation.run, run.id == request.runId, run.deviceId == request.deviceId,
              run.status != "cancelled", run.status != "completed" else {
            throw AskLocalError.message(L("ask.local.conflict"))
        }
        _ = try resolveTurn(record)
        if let recovery = run.internalRecovery,
           request.callIds.allSatisfy({ recovery.handledCallIds.contains($0) }),
           request.inferenceId.map({ recovery.handledCallIds.contains($0) }) ?? true,
           !run.needsRecoveryInspection { return record.conversation }
        guard request.inferenceId == nil || request.inferenceId == run.inference?.id else {
            throw AskLocalError.message(L("ask.local.conflict"))
        }
        let pending = Set(run.pending.map(\.id))
        let recorded = Set(record.conversation.messages.filter {
            $0.runId == run.id && ["unknown", "timeout", "cancelled"].contains($0.harness?.outcome?.status ?? "")
        }.compactMap(\.toolCallId))
        guard request.callIds.allSatisfy({ pending.contains($0) || recorded.contains($0) }),
              run.needsRecoveryInspection || !request.callIds.isEmpty ||
                (request.inferenceId != nil && request.inferenceId == run.inference?.id) else {
            throw AskLocalError.message(L("ask.local.conflict"))
        }
        keepPartial(&record)
        record.closeUsage()
        record.conversation.run?.inference = nil
        let unhandled = recorded.subtracting(run.internalRecovery?.handledCallIds ?? [])
        let uncertain = Array(Set(request.callIds).union(unhandled)).sorted()
        // A lost inference never executed its proposed tools. A lost device
        // receipt requires observation before any mutation can continue.
        if let inferenceId = request.inferenceId {
            if record.conversation.run?.internalRecovery == nil {
                record.conversation.run?.internalRecovery = .init(phase: .continued, handledCallIds: [inferenceId],
                    uncertainCallIds: [], evidenceStart: record.conversation.messages.count, startedStep: run.steps)
            } else {
                record.conversation.run?.internalRecovery?.handledCallIds.append(inferenceId)
            }
        }
        if uncertain.isEmpty, pending.isEmpty {
            record.conversation.run?.recovery = nil
            record.conversation.run?.status = "running"
            record.conversation.run?.error = nil
            record.conversation.run?.errorCode = nil
            try save(&record)
            return try await step(&record)
        }
        return try await beginInternalRecovery(&record, uncertain: uncertain.isEmpty ? Array(pending) : uncertain)
    }

    func beginInternalRecovery(_ record: inout AskLocalRecord, uncertain: [String]) async throws -> AskConversation {
        guard let run = record.conversation.run else { return record.conversation }
        // Close only the pending calls. Their original arguments remain in the
        // assistant message; none are replayed by this transition.
        for call in run.pending {
            let unknown = uncertain.contains(call.id)
            // Only dispatched calls have reservations; preserve consumed quotas
            // while releasing their concurrency slot, never invent zero usage.
            try compensateUnlaunchedBudgetTool(record, callId: call.id)
            let receipt = AskToolResultRequest(runId: run.id, deviceId: run.deviceId, toolCallId: call.id,
                content: unknown ? "The result was interrupted. Inspect the current state before repeating this operation."
                    : "This queued call was not dispatched because an earlier operation needs inspection.",
                isError: true, harness: .init(version: 1, outcome: .init(status: unknown ? "unknown" : "invalid",
                                                                       eventDispatched: unknown ? nil : false)))
            record.conversation.messages.append(receipt.message(step: run.steps, now: now()))
        }
        let previous = run.internalRecovery
        record.conversation.run?.internalRecovery = .init(
            handledCallIds: Array(Set(previous?.handledCallIds ?? []).union(uncertain)).sorted(),
            uncertainCallIds: uncertain, evidenceStart: record.conversation.messages.count,
            startedStep: run.steps, attempts: (previous?.attempts ?? 0) + 1
        )
        record.conversation.run?.pending = []
        record.conversation.run?.recovery = nil
        record.conversation.run?.recoveryCheck = true
        record.conversation.run?.status = "running"
        record.conversation.run?.error = nil
        record.conversation.run?.errorCode = nil
        // Keep the run ID, task permissions, plan, budget and step count.
        try save(&record)
        return try await step(&record)
    }

    func finishInternalRecovery(_ record: inout AskLocalRecord, call: AskToolCall) {
        guard var recovery = record.conversation.run?.internalRecovery else { return }
        let accepted = recovery.resolve(call, conversation: record.conversation)
        if accepted {
            record.conversation.run?.internalRecovery = recovery
            record.conversation.run?.recoveryCheck = recovery.phase != .continued
        }
        let text = accepted
            ? (recovery.phase == .continued ? "Inspection recorded. Continue the original user task from verified progress. Do not repeat completed effects or ask the user to resend the task."
                : "Explain the concrete missing information or access and the smallest useful user action. Do not repeat the uncertain operation.")
            : "Inspection is not complete. Call this tool alone with a nonempty explanation and actual fresh successful observation call IDs. If the outcome cannot be established, use blocked and identify the concrete missing fact."
        appendRecoveryControlResult(&record, call: call, text: text, failed: !accepted)
    }

    func appendRecoveryControlResult(_ record: inout AskLocalRecord, call: AskToolCall, text: String, failed: Bool) {
        record.conversation.messages.append(.init(id: UUID().uuidString, role: "tool", text: text,
            toolCallId: call.id, isError: failed, createdAt: now(), runId: record.conversation.run?.id,
            harness: .init(version: 1, outcome: .init(status: failed ? "invalid" : "ok", eventDispatched: false))))
        record.conversation.run?.pending.removeFirst()
    }
}
