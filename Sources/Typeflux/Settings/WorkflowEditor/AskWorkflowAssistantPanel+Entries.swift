import Foundation

extension AskWorkflowAssistantPanel {
    /// What the conversation shows: messages and proposals, with each run of tool
    /// steps folded into one line.
    enum Entry: Identifiable, Equatable {
        case item(AskWorkflowAssistant.Item)
        case steps(id: String, summaries: [String])

        var id: String {
            switch self {
            case let .item(item): item.id
            case let .steps(id, _): id
            }
        }
    }

    static func entries(_ items: [AskWorkflowAssistant.Item]) -> [Entry] {
        var entries: [Entry] = []
        for item in items {
            guard case let .tool(id, summary, _) = item else {
                entries.append(.item(item))
                continue
            }
            if case let .steps(first, summaries) = entries.last {
                entries[entries.count - 1] = .steps(id: first, summaries: summaries + [summary])
            } else {
                entries.append(.steps(id: "steps-" + id.uuidString, summaries: [summary]))
            }
        }
        return entries
    }
}
