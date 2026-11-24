import Foundation

/// A chat can ask the app to show an action. Only a click can open and send a task.
struct AskTaskModeHandoff: Equatable {
    static let toolName = "continue_in_task"
    static let definition = AskToolDefinition(
        name: toolName,
        description: """
        Show a button to continue the latest request in a new Task on this Mac.
        Use it when Chat cannot fulfill the request without live information from this Mac, such as the computer's
        current load, or without a local action. Use it before trying any workaround.
        Do not use it for general advice or questions answerable from provided content or the web.
        Write the reply the user should see before the button. In their language, answer what you can in Chat and explain
        what needs access to this Mac. When useful, include a short step the user can take themselves, and say what the
        Task can help with. The user decides whether to start the Task. Return this call on its own.
        """,
        parameters: JSONValue(data: Data(#"""
        {"type":"object","properties":{"reply":{"type":"string","maxLength":500,"description":"A short reply to the user, in their language, shown before the button."}},"required":["reply"],"additionalProperties":false}
        """#.utf8))
    )

    let conversationID: String
    let runID: String
    let question: AskMessage
    let stalled: Bool
    let reply: String

    static func reply(from call: AskToolCall) -> String? {
        guard let args = try? AskLocalTools.jsonArguments(call.function.arguments),
              let text = args["reply"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 500 ? nil : trimmed
    }

    init?(conversation: AskConversation, needsRecovery: Bool) {
        guard conversation.resolvedKind == .chat, let run = conversation.run, run.recoveryCheck != true,
              run.internalRecovery?.phase != .inspecting,
              let questionIndex = conversation.messages.lastIndex(where: {
                  $0.role == "user" && $0.steered != true
              }) else { return nil }
        let question = conversation.messages[questionIndex]
        guard question.runId == nil || question.runId == run.id else { return nil }
        let turn = conversation.messages.suffix(from: questionIndex)
        let calls = turn.flatMap { $0.toolCalls ?? [] }
        let pendingAndSent = calls + run.pending
        let names = Set(pendingAndSent.map(\.function.name))
        let deviceCalls = Set(calls.filter { call in
            let name = call.function.name
            return !AskConversationKind.chat.offers(name)
                && AskToolAuthorization.builtins.contains { $0.tool == name }
        }.map(\.id))
        let refusedDeviceCall = turn.contains {
            $0.isRecoverableToolRefusal && $0.toolCallId.map(deviceCalls.contains) == true
        }
        let requested = names.contains(Self.toolName) || refusedDeviceCall
        // Older chats could stall in workflow discovery before any draft existed.
        // Do not suggest replaying a turn that may have run an action.
        let stalled = !requested && needsRecovery && names.contains("workflow_check_keyword")
            && names.isSubset(of: ["workflow_list", "workflow_read", "workflow_environment", "workflow_check_keyword"])
        guard requested || stalled else { return nil }
        conversationID = conversation.id
        runID = run.id
        self.question = question
        self.stalled = stalled
        reply = pendingAndSent.last(where: { $0.function.name == Self.toolName }).flatMap(Self.reply(from:))
            ?? L(stalled ? "ask.kind.stalledChat" : "ask.kind.taskModeHelp")
    }
}

extension AskConversationModel {
    var taskModeHandoff: AskTaskModeHandoff? {
        guard let selected else { return nil }
        return AskTaskModeHandoff(conversation: selected, needsRecovery: recoveryPresentation.unknown)
    }

    func continueInTask(_ handoff: AskTaskModeHandoff) {
        guard session()?.owner == owner, let source = selected, let run = source.run,
              source.id == handoff.conversationID, run.id == handoff.runID,
              let current = taskModeHandoff, current.question.id == handoff.question.id else { return }
        let question = current.question
        let temporary = isTemporary(source.id)
        let keptLocally = isLocal(source.id)
        if run.isActive, run.deviceId == deviceId { stop(id: source.id) }
        guard newConversation(storesLocally: keptLocally) else { return }
        draft.kind = AskConversationKind.work.rawValue
        draft.temporary = temporary ? true : nil
        draft.includeScreenshot = false
        draft.text = question.text
        draft.selection = question.selection
        draft.attachments = question.attachments
        draft.references = question.references
        draft.skills = question.skillCatalog?.map(\.name)
        draft.mcpServers = question.mcpServers
        draft.modelRef = source.modelRef
        draft.reasoningEffort = question.reasoningEffort
        if source.memoryOff == true { draft.memoryOff = true }
        persistDrafts()
        submitDraft()
    }
}
