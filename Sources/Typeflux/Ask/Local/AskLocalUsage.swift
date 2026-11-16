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
        if item.tokens == nil || item.tokens?.incomplete == true {
            missingTokens = (missingTokens ?? 0) + 1
        } else if item.status == "unavailable" {
            // A missing charge does not make complete provider tokens a lower bound.
            missingTokens = missingTokens ?? 0
        }
        if item.status == "confirmed", let cost = item.microcredits, cost >= 0 {
            microcredits += cost / max(1, item.unitScale ?? 1)
        }
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
            createdAt: date, source: "unknown", status: "pending", version: usage.version,
            billingKey: AskDeviceModelClient.receiptKey(inference.id)
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
        // Provider tokens do not prove the Cloud charge. New calls await an
        // authoritative receipt; legacy calls without a billing key stay unknown.
        if item.status != "confirmed" {
            item.status = item.modelRef.hasPrefix("cloud:")
                ? (item.billingKey != nil && !receipt.failed ? "pending" : "unavailable") : "external"
        }
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
            if usage.invocations[index].usage.modelRef.hasPrefix("cloud:"),
               usage.invocations[index].usage.billingKey != nil,
               usage.invocations[index].usage.tokens != nil { continue }
            usage.version += 1
            usage.invocations[index].usage.status = usage.invocations[index].usage.modelRef.hasPrefix("cloud:") ? "unavailable" : "external"
            usage.invocations[index].usage.version = usage.version
        }
        localUsage = usage
        conversation.usage = usage.summary
    }
}

struct AskBillingReceipt: Codable, Equatable, Sendable {
    var key: String
    var microcredits: Int64
    var unitScale: Int64
}

extension AskLocalEngine {
    /// Billing summary reconciliation is independent from visible detail pagination.
    func pendingBillingKeys(id: String) throws -> [String] {
        let pending = try record(id).localUsage?.invocations.reversed().filter {
            $0.usage.modelRef.hasPrefix("cloud:") && $0.usage.status == "pending"
        }.compactMap(\.usage.billingKey) ?? []
        return Array(pending.prefix(100))
    }

    func reconcileUsage(id: String, receipts: [AskBillingReceipt]) throws {
        var record = try record(id)
        guard var usage = record.localUsage else { return }
        var changed = false
        for index in usage.invocations.indices {
            var item = usage.invocations[index].usage
            guard item.modelRef.hasPrefix("cloud:"), item.status != "confirmed",
                  let key = item.billingKey,
                  let receipt = receipts.first(where: { $0.key == key }),
                  receipt.microcredits >= 0, receipt.unitScale > 0 else { continue }
            usage.version += 1
            item.microcredits = receipt.microcredits
            item.unitScale = receipt.unitScale
            item.status = "confirmed"
            item.version = usage.version
            usage.invocations[index].usage = item
            changed = true
        }
        if !changed && record.conversation.usage != usage.summary { usage.version += 1; changed = true }
        guard changed else { return }
        record.localUsage = usage
        record.conversation.usage = usage.summary
        try persist(record)
    }
}
