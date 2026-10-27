import Foundation

/// In-process capability only; neither model payloads nor remote APIs can supply an executor.
/// The client checks each permission and owns each durable execution receipt.
typealias AskReadBatchExecutor = @Sendable (AskToolCall, AskBuiltinReadOperation?) async throws -> AskToolResultRequest
typealias AskBuiltinReadOperation = @Sendable () async -> AskLocalToolOutput

struct AskReadBatchFlight {
    let id: UUID
    let runID: String
    let task: Task<[AskToolResultRequest], Error>
}

extension AskLocalEngine {
    func readBatch(conversationId: String, runId: String, calls: [AskToolCall], token: String,
                   execute: @escaping AskReadBatchExecutor) async throws -> AskConversation? {
        guard token.isEmpty else { throw AskLocalError.message(L("ask.local.conflict")) }
        var record = try record(conversationId)
        _ = try resolveTurn(record)
        guard let run = record.conversation.run, run.id == runId, run.status == "waiting_tool",
              !run.needsRecoveryInspection, run.recoveryCheck != true,
              (2...3).contains(calls.count), Array(run.pending.prefix(calls.count)) == calls,
              readFlights[conversationId] == nil else { throw AskLocalError.message(L("ask.local.conflict")) }
        // Built-in ownership is checked independently of the client's read classification.
        for call in calls where isBuiltin(call, record) {
            guard ["web_search", "web_fetch"].contains(call.function.name),
                  let definition = record.builtinTools.first(where: { $0.name == call.function.name }),
                  builtinTools.executionClassification(for: definition) == .independentWebRead else {
                throw AskLocalError.message(L("ask.local.conflict"))
            }
        }
        var admitted: [AskToolCall] = []
        do {
            for (index, call) in calls.enumerated() {
                admitted.append(call)
                try reserveReadBatchTool(record, call: call, alreadyReserved: index == 0 && !isBuiltin(call, record))
            }
            try Task.checkCancellation()
        } catch {
            for call in admitted { try compensateUnlaunchedBudgetTool(record, callId: call.id) }
            if error is AskBudgetError { return try stopBudget(&record, error: error) }
            throw error
        }
        record.conversation.run?.status = "running"
        record.readBatchCallIDs = calls.map(\.id)
        do { try save(&record) }
        catch {
            for call in admitted { try compensateUnlaunchedBudgetTool(record, callId: call.id) }
            throw error
        }
        let original = record
        let host = builtinTools
        var cloudIndex = record.cloudCalls
        let operations: [AskBuiltinReadOperation?] = calls.map { call in
            guard isBuiltin(call, original) else { return nil }
            let allowed = builtinAllowed(call, count: cloudIndex)
            cloudIndex += 1
            let input = AskBuiltinToolInput(call: call, conversation: original.conversation,
                                            budgeted: run.budgetEnabled == true)
            return {
                guard allowed else { return .init(content: "Web tool limit for this request reached.", isError: true, outcome: .init(status: "failed")) }
                let output = await host.execute(input)
                return .init(content: output.text, isError: output.isError, outcome: .init(status: output.isError ? "failed" : "ok"))
            }
        }
        let flightID = UUID()
        let task = Task {
            try await withThrowingTaskGroup(of: (Int, AskToolResultRequest).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try await execute(call, operations[index]))
                    }
                }
                var results: [Int: AskToolResultRequest] = [:]
                for try await (index, result) in group { results[index] = result }
                return calls.indices.map { results[$0]! }
            }
        }
        readFlights[conversationId] = .init(id: flightID, runID: runId, task: task)
        let outcome = await withTaskCancellationHandler(operation: { await task.result }, onCancel: { task.cancel() })
        if readFlights[conversationId]?.id == flightID { readFlights[conversationId] = nil }
        // Settle against the original root even after replacement, deletion or cancellation.
        var settlementError: Error?
        for call in admitted {
            do { try settleBudgetTool(original, callId: call.id) }
            catch { settlementError = settlementError ?? error }
        }
        guard var latest = records[conversationId] else {
            if let settlementError { throw settlementError }
            throw AskLocalError.message(L("ask.local.notFound"))
        }
        guard latest.conversation.run?.id == runId, latest.conversation.run?.status == "running",
              latest.conversation.run?.agentBinding == run.agentBinding,
              Array((latest.conversation.run?.pending ?? []).prefix(calls.count)) == calls else {
            if let settlementError { throw settlementError }
            return latest.conversation
        }
        _ = try resolveTurn(latest)
        let results: [AskToolResultRequest]
        do {
            results = try outcome.get()
            for (call, result) in zip(calls, results) {
                guard result.runId == runId, result.deviceId == run.deviceId, result.toolCallId == call.id,
                      result.approveExecution == nil else { throw AskLocalError.message(L("ask.local.conflict")) }
            }
        }
        catch {
            latest.conversation.run?.status = "waiting_tool"
            latest.conversation.run?.recovery = .init(state: "unknown_outcome", sequence: latest.conversation.revision)
            try save(&latest)
            throw error
        }
        for (call, result) in zip(calls, results) {
            latest.conversation.messages.append(result.message(step: run.steps, now: now()))
            if isBuiltin(call, original) { latest.cloudCalls += 1 }
        }
        latest.conversation.run?.taskResolution = nil
        latest.conversation.run?.pending.removeFirst(calls.count)
        latest.readBatchCallIDs = nil
        // A failed snapshot write must not replay completed tools in this process.
        records[conversationId] = latest
        try save(&latest)
        if let settlementError { throw settlementError }
        try Task.checkCancellation()
        let uncertain = results.filter { ["unknown", "timeout", "cancelled"].contains(AskExecutionReceipt.tool($0).status) }.map(\.toolCallId)
        if !uncertain.isEmpty { return try await beginInternalRecovery(&latest, uncertain: uncertain) }
        return try await continueTools(&latest)
    }
}
