import Foundation

extension AskLocalEngine {
    func budgetJournal(_ record: AskLocalRecord,
                       _ change: (inout AskBudgetController) throws -> Void) throws -> AskBudgetController? {
        guard let run = record.conversation.run, run.budgetEnabled == true else { return nil }
        guard let root = run.budgetRootId, let deadline = run.budgetDeadline,
              let limits = run.budgetLimits else { throw AskBudgetError.invalid }
        let initial = AskBudgetController(runId: root, limits: limits, deadline: deadline)
        return try AskBudgetStore(directory: directory).update(
            conversation: record.conversation.id,
            root: root,
            initial: initial,
            change
        )
    }

    func refreshBudget(_ record: inout AskLocalRecord) throws {
        if let journal = try budgetJournal(record, { _ in }) {
            record.conversation.run?.budget = journal.summary
            if let reason = record.conversation.run?.stopReason {
                record.conversation.run?.budget?.stopReason = reason
            }
        }
    }

    func reserveBudget(
        _ record: AskLocalRecord,
        operationId: String,
        callId: String,
        kind: String,
        resources: AskBudgetResources
    ) throws {
        let instant = now()
        _ = try budgetJournal(record) { journal in
            try journal.reserve(.init(
                runId: record.conversation.run?.id,
                operationId: operationId,
                stepId: String(record.conversation.run?.steps ?? 0),
                callId: callId,
                kind: kind,
                reserved: resources
            ), at: instant)
            try journal.start(operationId, at: instant)
        }
    }

    func reserveBudgetTool(_ record: AskLocalRecord, call: AskToolCall) throws {
        try reserveBudget(
            record,
            operationId: toolOperation(record, call.id),
            callId: call.id,
            kind: call.function.name,
            resources: .init(
                webRequests: ["web_search", "web_fetch"].contains(call.function.name) ? 1 : 0,
                operations: 1
            )
        )
    }

    func settleBudgetTool(_ record: AskLocalRecord, callId: String) throws {
        _ = try budgetJournal(record) { journal in
            try journal.settle(
                toolOperation(record, callId),
                actual: .init(),
                source: "scheduler",
                tokensFinal: true,
                costFinal: true
            )
        }
    }

    func settleInference(_ record: AskLocalRecord, _ receipt: AskInferenceResult) throws {
        guard receipt.usage?.isValid != false else { throw AskBudgetError.invalid }
        _ = try budgetJournal(record) { journal in
            let tokens = receipt.usage.map { max($0.totalTokens, $0.promptTokens + $0.completionTokens) } ?? 0
            try journal.settle(
                receipt.inferenceId,
                actual: .init(tokens: Int64(tokens)),
                source: "client",
                tokensFinal: false,
                costFinal: false
            )
        }
    }

    func toolOperation(_ record: AskLocalRecord, _ callId: String) -> String {
        "\(record.conversation.run?.id ?? "")/\(callId)/tool"
    }

    func stopBudget(_ record: inout AskLocalRecord, error: Error) throws -> AskConversation {
        var reason = "budget_unavailable"
        if case let AskBudgetError.reached(value) = error {
            reason = value
        }
        record.conversation.run?.stopReason = reason
        // Finish from existing evidence without another billable model request.
        let evidence = record.conversation.messages.filter { $0.role == "tool" && $0.isError != true }.suffix(3)
            .map { AskContextPlanner.excerpt($0.text, size: 1000) }.joined(separator: "\n\n")
        if !evidence.isEmpty {
            record.conversation.messages.append(.init(id: UUID().uuidString.lowercased(), role: "assistant",
                                                      text: L("ask.budget.evidence") + "\n\n" + evidence,
                                                      createdAt: now(), runId: record.conversation.run?.id))
        }
        return try fail(&record, L("ask.budget.stopped", L("ask.budget.reason." + reason)))
    }
}
