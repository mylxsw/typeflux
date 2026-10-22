import Foundation

/// What a conversation may do, chosen before its first message and fixed afterwards.
/// A chat only talks: it is never offered a tool that reads or changes this Mac.
/// Work runs on this Mac with files, commands, apps and local MCP servers, under
/// the permission mode. Where a conversation is kept is a separate choice.
enum AskConversationKind: String, CaseIterable, Sendable {
    case chat, work

    /// A value written by a newer client reads as chat: an unknown kind never
    /// gains access to this Mac.
    init(stored: String) { self = Self(rawValue: stored) ?? .chat }

    var titleKey: String { "ask.kind." + rawValue }
    var symbol: String { self == .chat ? "bubble.left" : "terminal" }

    /// Device tools a chat keeps: none of them read or change files, apps or the system.
    static let chatDeviceTools: Set<String> = ["skill", "memory", "generate_image"]

    /// Tools the engine or Typeflux Cloud runs itself; they never touch this Mac.
    static let engineTools: Set<String> = [
        "web_search", "web_fetch", "web_research", "research", "update_plan", "read_conversation_history",
    ]

    func offers(_ name: String) -> Bool {
        self == .work || Self.chatDeviceTools.contains(name) || AskLocalTools.workflowChatNames.contains(name)
    }

    func offered(_ tools: [AskToolDefinition]) -> [AskToolDefinition] { tools.filter { offers($0.name) } }

    /// A conversation from before kinds existed did work on this Mac when its transcript
    /// called a device tool outside chat's set, and keeps doing so; any other reads as chat.
    static func inferred(_ messages: [AskMessage]) -> Self {
        let worked = messages.contains { message in
            message.toolCalls?.contains { !chat.offers($0.function.name) && !engineTools.contains($0.function.name) } == true
        }
        return worked ? .work : .chat
    }
}

extension AskConversation {
    var resolvedKind: AskConversationKind { kind.map(AskConversationKind.init(stored:)) ?? .inferred(messages) }

    /// The kind that decides whether a pending device call may run. Only a stored kind
    /// refuses one: a conversation from before kinds existed may be mid-run with tools it
    /// was offered then (synced snapshots drop the run's tool list), so it dispatches as
    /// before, under approval. Later sends offer it tools by `resolvedKind`.
    var dispatchKind: AskConversationKind { kind.map(AskConversationKind.init(stored:)) ?? .work }
}

extension AskConversationSummary {
    init(_ conversation: AskConversation) {
        self.init(id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt,
                  kind: conversation.resolvedKind.rawValue)
    }

    /// Rows listed by a server that predates kinds have none; they read as chat until opened.
    var resolvedKind: AskConversationKind { kind.map(AskConversationKind.init(stored:)) ?? .chat }
}
