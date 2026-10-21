import Foundation

/// Trusted application composition for admitted built-in calls. Approval, budget
/// reservation, execution ownership and state application stay in the engine.
protocol AskBuiltinToolHosting: Sendable {
    func definitions() -> [AskToolDefinition]
    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput
}

/// An immutable, already admitted account-scoped conversation snapshot.
struct AskBuiltinToolInput: Sendable {
    let call: AskToolCall
    let conversation: AskConversation
    /// Restricts transport after authorization; it does not grant approval.
    let budgeted: Bool
}

struct AskBuiltinToolOutput: Sendable {
    var text: String
    var isError: Bool
    var plan: [AskPlanItem]?
}

struct DefaultAskBuiltinToolHost: AskBuiltinToolHosting {
    let webTools: AskLocalWebTools

    func definitions() -> [AskToolDefinition] {
        [AskBuiltinPlan.definition] + webTools.definitions()
    }

    func execute(_ input: AskBuiltinToolInput) async -> AskBuiltinToolOutput {
        let call = input.call
        let conversation = input.conversation
        let budgeted = input.budgeted
        if call.function.name == AskSemanticCompaction.historyTool.name {
            do { return try AskBuiltinToolOutput(
                text: AskSemanticCompaction.readHistory(conversation, arguments: call.function.arguments),
                isError: false
            ) } catch {
                return AskBuiltinToolOutput(text: "Invalid original message index, offset or limit.", isError: true)
            }
        }
        if call.function.name == "update_plan" {
            do {
                return try AskBuiltinToolOutput(text: "Plan updated.", isError: false,
                                                plan: AskBuiltinPlan.parse(call.function.arguments))
            } catch { return AskBuiltinToolOutput(text: error.localizedDescription, isError: true) }
        }
        var boundedTools = webTools
        if budgeted {
            // One reservation authorizes one request; redirect follow-ups require
            // a fresh reservation, so this local adapter refuses them.
            boundedTools.session = URLSession(
                configuration: webTools.session.configuration,
                delegate: AskModelRedirectPolicy(),
                delegateQueue: nil
            )
        }
        defer {
            if budgeted {
                boundedTools.session.finishTasksAndInvalidate()
            }
        }
        let (text, failed) = await boundedTools.execute(name: call.function.name, arguments: call.function.arguments)
        return AskBuiltinToolOutput(text: text, isError: failed)
    }
}
