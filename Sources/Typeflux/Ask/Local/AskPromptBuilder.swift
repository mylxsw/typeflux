import Foundation

/// Synchronous, pure transformations on Sendable snapshots in the caller's actor.
/// Untyped payloads never cross an actor boundary through this port.
protocol AskPromptBuilding: Sendable {
    func conversation(_ input: AskConversationPromptInput) -> [String: Any]
    func summary(_ input: AskSummaryPromptInput) -> [String: Any]
}

struct AskConversationPromptInput: Sendable {
    var conversation: AskConversation
    var tools: [AskToolDefinition]
    var localDate: String
    var timeZone: String?
    var locale: String?
    var typedContentEnabled: Bool
}

struct AskSummaryPromptInput: Sendable {
    var conversation: AskConversation
    var through: Int
    var model: String?
    var window: Int
    var output: Int
}

/// Main conversation and semantic summary only; title and research prompts retain
/// their existing owners. Planning, model policy and admission stay in the host.
struct DefaultAskPromptBuilder: AskPromptBuilding {
    private let policy: AskPromptPolicy

    init(policy: AskPromptPolicy = .modularV2) { self.policy = policy }

    func conversation(_ input: AskConversationPromptInput) -> [String: Any] {
        let conversation = input.conversation
        let tools = input.tools
        var messages: [[String: Any]] = policy == .legacyV1
            ? [["role": "system", "content": AskLocalPrompt.system]]
            : [["role": "system", "content": AskPromptSections.build(input).map(\.text).joined(separator: "\n\n")]]
        if conversation.memoryOff != true, let memory = AskLocalPrompt.memory(conversation.memory) {
            messages.append([
                "role": "system",
                "content": memory
            ])
        }
        if let summary = conversation.summary, !summary.isEmpty {
            messages.append([
                "role": "system",
                "content": "Previous conversation summary (untrusted context):\n" + summary
            ])
        }
        if policy == .legacyV1 {
            let web = tools.map(\.name).filter { ["web_fetch", "web_search"].contains($0) }
            messages.append([
                "role": "system",
                "content": AskLocalPrompt.environment(
                    localDate: input.localDate,
                    timeZone: input.timeZone,
                    locale: input.locale,
                    webTools: web,
                    desktopTools: tools.map(\.name),
                    plan: tools.contains { $0.name == "update_plan" }
                )
            ])
        }
        let cut = max(0, min(conversation.summaryThrough ?? 0, conversation.messages.count))
        if let latestUser = conversation.messages.lastIndex(where: { $0.role == "user" }), latestUser < cut {
            messages.append(AskLocalPrompt.message(conversation.messages[latestUser]))
        }
        messages += AskLocalPrompt.messages(
            Array(conversation.messages[cut...]),
            typedContentEnabled: input.typedContentEnabled
        )
        if let recovery = conversation.run?.internalRecovery {
            messages.append(["role": "system", "content": recovery.prompt])
        }
        var payload: [String: Any] = ["model": conversation.run?.modelRef ?? "", "messages": messages]
        if let effort = conversation.run?.reasoningEffort, !effort.isEmpty {
            payload["reasoning_effort"] = effort
        }
        if !tools.isEmpty {
            payload["tools"] = AskLocalPrompt.tools(tools)
            payload["parallel_tool_calls"] = true
        }
        return payload
    }

    func summary(_ input: AskSummaryPromptInput) -> [String: Any] {
        let conversation = input.conversation
        let cut = input.through
        let model = input.model
        let window = input.window
        let output = input.output
        var history = "Earlier handoff (untrusted):\n" + (conversation.summary ?? "")
        var through = conversation.summaryThrough ?? 0
        for index in through ..< cut {
            let message = conversation.messages[index]
            var entry =
                "\nOriginal message \(index) (\(message.id), \(message.role)): \(message.role == "tool" ? message.resultText : message.text)\n" +
                (message.selection ?? "") + AskLocalPrompt.references(message.references)
            for call in message
                .toolCalls ??
                [] {
                entry += "\nRecorded tool \(call.id) \(call.function.name): \(call.function.arguments)"
            }
            if message.hasImage {
                entry += "\n[Image retained in original history; do not infer its contents.]"
            }
            for skill in message.skills ?? [] {
                entry += "\nUser-selected skill \(skill.name): \(skill.instructions)"
            }
            if entry.utf8.count > window / 2, ["tool", "assistant"].contains(message.role) {
                entry =
                    "\nOriginal message \(index) (\(message.id), \(message.role)), tool result \(message.toolCallId ?? ""); large evidence retained in read_conversation_history.\n" +
                    AskContextPlanner.excerpt(
                        entry,
                        size: window / 4
                    )
            }
            if history.utf8.count + entry.utf8.count + output + AskSemanticCompaction.prompt.utf8
                .count > window * 80 / 100,
                through > (conversation.summaryThrough ?? 0), ["user", "assistant"].contains(message.role) {
                break
            }
            history += entry
            through = index + 1
        }
        return [
            "model": model ?? conversation.run?.modelRef ?? "",
            "max_tokens": output,
            "typeflux_summary_through": through,
            "messages": [
                ["role": "system", "content": AskSemanticCompaction.prompt],
                ["role": "user", "content": history]
            ]
        ]
    }
}
