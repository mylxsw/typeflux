import Foundation

/// Provider-reported tokens for local conversations; never a billing authority.
struct AskLocalUsage: Codable, Equatable, Sendable {
    struct Invocation: Codable, Equatable, Sendable {
        var deviceId: String
        var budgetRootId: String?
        var usage: AskUsageInvocation
    }

    var since: Date
    var historicalGap: Bool
    var version: Int64 = 0
    var invocations: [Invocation] = []

    func contains(_ receipt: AskInferenceResult) -> Bool {
        invocations.contains {
            $0.usage.id == receipt.inferenceId && $0.usage.runId == receipt.runId && $0.deviceId == receipt.deviceId
        }
    }

    func budgetRoot(for receipt: AskInferenceResult) -> String? {
        invocations.first {
            $0.usage.id == receipt.inferenceId && $0.usage.runId == receipt.runId && $0.deviceId == receipt.deviceId
        }?.budgetRootId
    }

    func page(runId: String?, cursor: Int64?) -> AskUsagePage {
        // Insertion positions are stable even when older calls receive late tokens.
        let matching = invocations.enumerated().reversed().filter {
            (runId == nil || $0.element.usage.runId == runId) && Int64($0.offset + 1) < (cursor ?? Int64.max)
        }
        let page = matching.prefix(50)
        return AskUsagePage(items: page.map(\.element.usage),
                            nextCursor: matching.count > 50 ? page.last.map { Int64($0.offset + 1) } : nil)
    }

    var summary: AskConversationUsage {
        var total = AskUsageTotals()
        var runs: [String: AskUsageTotals] = [:]
        for entry in invocations {
            total.addLocal(entry.usage)
            runs[entry.usage.runId, default: .init()].addLocal(entry.usage)
        }
        return .init(version: version, since: since, historicalGap: historicalGap, total: total, runs: runs)
    }
}

private extension AskUsageTotals {
    mutating func addLocal(_ item: AskUsageInvocation) {
        calls += 1
        if item.status == "external" { external += 1 }
        if item.status == "pending" {
            pending += 1
        }
        if item.tokens == nil || item.tokens?.incomplete == true || item.status == "unavailable" {
            missing += 1
        }
        if let tokens = item.tokens {
            inputTokens += Int64(tokens.promptTokens)
            outputTokens += Int64(tokens.completionTokens)
            totalTokens += Int64(tokens.totalTokens)
            if let cached = tokens.cachedTokens {
                cachedInputTokens = (cachedInputTokens ?? 0) + Int64(cached)
            }
        }
    }
}

extension AskLocalRecord {
    mutating func startUsage(_ inference: AskInference, at date: Date) {
        guard let run = conversation.run else { return }
        if localUsage == nil {
            localUsage = .init(since: date, historicalGap: conversation.messages.contains { $0.role == "assistant" }
                || conversation.summary != nil)
        }
        guard var usage = localUsage,
              !usage.invocations.contains(where: { $0.usage.id == inference.id }) else { return }
        usage.version += 1
        usage.invocations.append(.init(deviceId: run.deviceId, budgetRootId: run.budgetRootId, usage: .init(
            id: inference.id, runId: run.id, messageId: inference.summaryThrough == nil ? run.assistantId : nil,
            modelRef: ((try? JSONSerialization.jsonObject(with: Data(inference.payload.utf8))) as? [String: Any])?["model"] as? String ?? run.modelRef ?? conversation.modelRef ?? "",
            purpose: inference.summaryThrough == nil ? "answer" : "summary",
            createdAt: date, source: "unknown", status: "pending", version: usage.version
        )))
        localUsage = usage
        conversation.usage = usage.summary
    }

    @discardableResult
    mutating func settleUsage(_ receipt: AskInferenceResult) -> Bool {
        guard let index = localUsage?.invocations.firstIndex(where: {
            $0.usage.id == receipt.inferenceId && $0.usage.runId == receipt.runId && $0.deviceId == receipt.deviceId
        }), var item = localUsage?.invocations[index].usage else { return false }
        let previous = item
        if let tokens = receipt.usage, tokens.isValid {
            // Partial or absent reports cannot erase a complete provider report.
            if item.tokens == nil || (item.tokens?.incomplete == true && (tokens.incomplete != true
                    || (tokens.promptTokens >= (item.tokens?.promptTokens ?? 0)
                        && tokens.completionTokens >= (item.tokens?.completionTokens ?? 0)
                        && tokens.totalTokens >= (item.tokens?.totalTokens ?? 0)))) {
                item.tokens = tokens
                item.source = "client"
            }
        }
        // Provider-reported tokens do not prove the Cloud charge. Keep its cost
        // explicitly unavailable rather than labeling it as a user's own model.
        item.status = item.modelRef.hasPrefix("cloud:") ? "unavailable" : "external"
        guard item != previous else { return false }
        localUsage?.version += 1
        item.version = localUsage?.version ?? 0
        localUsage?.invocations[index].usage = item
        conversation.usage = localUsage?.summary
        return true
    }

    mutating func closeUsage() {
        guard let run = conversation.run, var usage = localUsage else { return }
        for index in usage.invocations.indices where usage.invocations[index].usage.runId == run.id
            && usage.invocations[index].usage.status == "pending" {
            usage.version += 1
            usage.invocations[index].usage.status = "external"
            usage.invocations[index].usage.version = usage.version
        }
        localUsage = usage
        conversation.usage = usage.summary
    }
}
