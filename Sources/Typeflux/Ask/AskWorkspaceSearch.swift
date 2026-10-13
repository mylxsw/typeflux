import Foundation

/// Toolbar search filters the already loaded sidebar without issuing network requests.
enum AskWorkspaceSearch {
    static func filter(_ conversations: [AskConversationSummary], query: String) -> [AskConversationSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
}
