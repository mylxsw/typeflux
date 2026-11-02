import Foundation

/// Provider-standard participant names distinguish host context from literal user text.
enum AskPromptContext {
    static func message(_ content: String, name: String, legacy: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["role": legacy ? "system" : "user", "content": content]
        if !legacy { result["name"] = name }
        return result
    }

    static func isHistorical(_ message: [String: Any]) -> Bool {
        guard let role = message["role"] as? String, let text = message["content"] as? String else { return false }
        let markers = [AskPromptPolicyText.memoryName: AskPromptPolicyText.memoryPrefix,
                       AskPromptPolicyText.summaryName: AskPromptPolicyText.summaryPrefix,
                       AskPromptPolicyText.anchorsName: AskPromptPolicyText.anchorsPrefix,
                       AskPromptPolicyText.planName: AskTaskProgress.planContextPrefix]
        if role == "system" { return markers.values.contains { text.hasPrefix($0) } }
        guard role == "user", let name = message["name"] as? String, let prefix = markers[name] else { return false }
        return text.hasPrefix(prefix)
    }

    static func isPinned(_ message: [String: Any]) -> Bool {
        guard isHistorical(message), let text = message["content"] as? String else { return false }
        return text.hasPrefix(AskPromptPolicyText.memoryPrefix) || text.hasPrefix(AskPromptPolicyText.anchorsPrefix)
            || text.hasPrefix(AskTaskProgress.planContextPrefix)
    }
}
