import Foundation

/// Status of an agent job.
enum AgentJobStatus: String, Codable {
    case running
    case completed
    case failed
}

/// A single recorded step within an agent job.
struct AgentJobStep: Codable, Identifiable {
    let id: String
    let stepIndex: Int
    let toolCalls: [AgentJobToolCall]
    let assistantText: String?
    let durationMs: Int64
    let tokenUsage: LLMTokenUsage?

    init(
        stepIndex: Int,
        toolCalls: [AgentJobToolCall],
        assistantText: String?,
        durationMs: Int64,
        tokenUsage: LLMTokenUsage? = nil,
    ) {
        id = "\(stepIndex)"
        self.stepIndex = stepIndex
        self.toolCalls = toolCalls
        self.assistantText = assistantText
        self.durationMs = durationMs
        self.tokenUsage = tokenUsage
    }

    /// Human-readable description of what this step did.
    var stepDescription: String {
        if toolCalls.isEmpty {
            return assistantText != nil ? "Generating response" : "Processing"
        }
        if toolCalls.count == 1 {
            return toolCalls[0].name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let names = toolCalls.map(\.name).joined(separator: ", ")
        return "\(toolCalls.count) tools: \(names)"
    }

    /// Formatted duration: shows ms for under 1 s, seconds otherwise.
    var formattedDuration: String {
        if durationMs < 1000 {
            return "\(durationMs)ms"
        }
        return String(format: "%.1fs", Double(durationMs) / 1000.0)
    }
}

/// A recorded tool call within a step.
struct AgentJobToolCall: Codable, Identifiable {
    let id: String
    let name: String
    let argumentsJSON: String
    let resultContent: String
    let isError: Bool
}

/// A complete agent job record.
struct AgentJob: Codable, Identifiable {
    let id: UUID
    var createdAt: Date
    var completedAt: Date?
    var status: AgentJobStatus
    var title: String?
    var userPrompt: String
    var selectedText: String?
    var resultText: String?
    var errorMessage: String?
    var steps: [AgentJobStep]
    var totalDurationMs: Int64?
    var outcomeType: String?
    var totalTokenUsage: LLMTokenUsage?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        status: AgentJobStatus = .running,
        title: String? = nil,
        userPrompt: String,
        selectedText: String? = nil,
        resultText: String? = nil,
        errorMessage: String? = nil,
        steps: [AgentJobStep] = [],
        totalDurationMs: Int64? = nil,
        outcomeType: String? = nil,
        totalTokenUsage: LLMTokenUsage? = nil,
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.title = title
        self.userPrompt = userPrompt
        self.selectedText = selectedText
        self.resultText = resultText
        self.errorMessage = errorMessage
        self.steps = steps
        self.totalDurationMs = totalDurationMs
        self.outcomeType = outcomeType
        self.totalTokenUsage = totalTokenUsage
    }

    /// Display title: generated title or truncated user prompt.
    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        let truncated = userPrompt.prefix(60)
        return truncated.count < userPrompt.count ? "\(truncated)…" : String(truncated)
    }

    /// Whether the job completed successfully.
    var isSuccess: Bool {
        status == .completed
    }

    /// Number of tool calls across all steps.
    var totalToolCalls: Int {
        steps.reduce(0) { $0 + $1.toolCalls.count }
    }

    /// Formatted duration string.
    var formattedDuration: String? {
        guard let ms = totalDurationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.1fs", seconds)
    }

    /// Formatted total token count for display.
    var formattedTotalTokens: String? {
        guard let usage = totalTokenUsage, usage.totalTokens > 0 else { return nil }
        let total = usage.totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(total) / 1_000_000.0)
        }
        if total >= 1000 {
            return String(format: "%.1fK tokens", Double(total) / 1000.0)
        }
        return "\(total) tokens"
    }
}
