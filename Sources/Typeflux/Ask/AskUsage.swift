import Foundation

struct AskTokenUsage: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var incomplete: Bool? = nil
    /// Prompt tokens served from the provider's prompt cache; Cloud bills them
    /// at one tenth of the input rate. Always a subset of `promptTokens`.
    var cachedTokens: Int? = nil

    var isValid: Bool {
        (0 ... 10_000_000).contains(promptTokens) && (0 ... 10_000_000).contains(completionTokens)
            && (max(promptTokens, completionTokens) ... 10_000_000).contains(totalTokens)
            && (0 ... promptTokens).contains(cachedTokens ?? 0)
    }

    static func parse(_ body: [String: Any], style: AskProviderStream.Style, previous: Self? = nil) -> Self? {
        var input: Int?, output: Int?, total: Int?, cached: Int?
        switch style {
        case .openAI:
            guard let usage = body["usage"] as? [String: Any] else { return previous }
            input = usage["prompt_tokens"] as? Int; output = usage["completion_tokens"] as? Int
            total = usage["total_tokens"] as? Int
            cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                ?? usage["prompt_cache_hit_tokens"] as? Int ?? usage["cached_tokens"] as? Int
        case .anthropic:
            let message = body["message"] as? [String: Any]
            guard let usage = (body["usage"] ?? message?["usage"]) as? [String: Any] else { return previous }
            if let n = usage["input_tokens"] as? Int {
                input = boundedSum([n, usage["cache_read_input_tokens"] as? Int ?? 0, usage["cache_creation_input_tokens"] as? Int ?? 0])
                cached = usage["cache_read_input_tokens"] as? Int
            } else { input = previous?.promptTokens; cached = previous?.cachedTokens }
            output = usage["output_tokens"] as? Int ?? previous?.completionTokens
        case .gemini:
            guard let usage = body["usageMetadata"] as? [String: Any] else { return previous }
            input = usage["promptTokenCount"] as? Int
            cached = usage["cachedContentTokenCount"] as? Int
            if let n = usage["candidatesTokenCount"] as? Int { output = boundedSum([n, usage["thoughtsTokenCount"] as? Int ?? 0]) }
            total = usage["totalTokenCount"] as? Int
        }
        guard let input, let output, (0 ... 10_000_000).contains(input), (0 ... 10_000_000).contains(output) else { return previous }
        var value = Self(promptTokens: input, completionTokens: output, totalTokens: total ?? input + output)
        if let cached, cached > 0 { value.cachedTokens = min(cached, input) }
        if style == .anthropic { value.incomplete = body["type"] as? String == "message_start" }
        if style == .gemini, let candidates = body["candidates"] as? [[String: Any]] {
            value.incomplete = candidates.first?["finishReason"] == nil
        }
        return value.isValid ? value : previous
    }
    private static func boundedSum(_ values: [Int]) -> Int? {
        guard values.allSatisfy({ (0 ... 10_000_000).contains($0) }) else { return nil }
        return values.reduce(0, +)
    }
}

struct AskUsageTotals: Codable, Equatable, Sendable {
    var inputTokens: Int64 = 0
    /// Part of `inputTokens` billed at the cached rate. Optional so snapshots
    /// from servers that predate cache pricing still decode.
    var cachedInputTokens: Int64? = nil
    var outputTokens: Int64 = 0
    var totalTokens: Int64 = 0
    var microcredits: Int64 = 0
    var calls: Int = 0
    var pending: Int = 0
    var missing: Int = 0
    var estimated: Int = 0
    var external: Int = 0

    func tokenText(_ value: Int64) -> String {
        if calls == 0 || (missing == calls && value == 0) { return "—" }
        let prefix = missing > 0 ? "≥" : estimated > 0 ? "≈" : ""
        return prefix + AccountUsageDisplayFormatter.count(value)
    }

    var creditsText: String {
        if calls == 0 { return "—" }
        if external != calls && microcredits == 0 && (pending > 0 || missing > 0) { return "—" }
        if microcredits > 0 && microcredits < 10_000 { return "<0.01" }
        let amount = Decimal(microcredits) / 1_000_000
        let formatter = NumberFormatter()
        formatter.locale = .current; formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }

    var statusKey: String {
        if pending > 0 { return "ask.usage.pending" }
        if missing > 0 { return "ask.usage.incomplete" }
        if external == calls && calls > 0 { return "ask.usage.external" }
        return "ask.usage.confirmed"
    }
}

struct AskConversationUsage: Codable, Equatable, Sendable {
    var version: Int64
    var since: Date
    var historicalGap: Bool
    var total: AskUsageTotals
    var runs: [String: AskUsageTotals]
}

struct AskContextUsage: Codable, Equatable, Sendable {
    var modelRef: String
    var inputTokens: Int
    var outputReserve: Int
    var capacity: Int?
    var summarized: Bool
    var estimated: Bool? = nil
    var trimmed: Bool? = nil
    var remaining: Int? { capacity.flatMap { $0 > 0 ? max(0, $0 - inputTokens - outputReserve) : nil } }
    var fraction: Double? { capacity.flatMap { $0 > 0 ? Double(inputTokens) / Double($0) : nil } }
    var isHigh: Bool { remaining == 0 }
}

struct AskUsageInvocation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var runId: String
    var messageId: String?
    var modelRef: String
    var purpose: String
    var createdAt: Date
    var tokens: AskTokenUsage?
    var source: String
    var microcredits: Int64?
    var status: String
    var version: Int64
}

struct AskUsagePage: Codable, Sendable {
    var items: [AskUsageInvocation]
    var nextCursor: Int64?
}

extension AskConversation {
    // Content and metering advance independently, including after cancellation.
    func mergingUsage(from older: Self?) -> Self {
        guard let older, older.id == id else { return self }
        var result = self
        if (older.usage?.version ?? 0) > (usage?.version ?? 0) { result.usage = older.usage }
        if older.run?.id == run?.id, (older.run?.budget?.version ?? 0) > (run?.budget?.version ?? 0) {
            result.run?.budget = older.run?.budget
        }
        return result
    }
    func reconciling(_ incoming: Self, preservingEqualRevisionContent: Bool = false) -> Self {
        guard incoming.id == id else { return incoming }
        if preservingEqualRevisionContent, incoming.revision == revision { return mergingUsage(from: incoming) }
        var result = incoming.revision >= revision ? incoming.mergingUsage(from: self) : mergingUsage(from: incoming)
        // A legacy server cannot echo typed receipts; retain them only on the same
        // persisted message identity. Never resurrect a deleted message or permission.
        let prior = incoming.revision >= revision ? self : incoming
        for index in result.messages.indices
        where result.messages[index].role == "tool" && result.messages[index].harness == nil {
            let message = result.messages[index]
            if let old = prior.messages.first(where: { $0.id == message.id && $0.toolCallId == message.toolCallId }) {
                result.messages[index].harness = old.harness
                result.messages[index].diagnostic = old.diagnostic
                result.messages[index].runId = old.runId ?? message.runId
            }
        }
        return result
    }
    func isNewer(than older: Self) -> Bool {
        revision > older.revision || (usage?.version ?? 0) > (older.usage?.version ?? 0)
            || (run?.id == older.run?.id && (run?.budget?.version ?? 0) > (older.run?.budget?.version ?? 0))
    }
}
