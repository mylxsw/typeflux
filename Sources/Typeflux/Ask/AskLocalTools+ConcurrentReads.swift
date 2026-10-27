import Foundation

extension AskLocalTools {
    /// Scheduling hints never grant permission. MCP still needs an explicit local allow
    /// policy, and its live definition and connection are pinned by the approval binding.
    func allowsConcurrentRead(_ call: AskToolCall) async -> Bool {
        if call.function.name == "files" {
            guard let args = try? Self.jsonArguments(call.function.arguments) else { return false }
            return ["read", "list", "search"].contains(args["action"] as? String ?? "")
        }
        guard let server = mcpIdentities[call.function.name],
              let entry = Self.mcpToolNames(await registry.registeredTools()).first(where: { $0.0 == call.function.name }),
              entry.1.serverId == server else { return false }
        let hints = entry.1.tool.toolDef.annotations
        return hints?.readOnlyHint == true && hints?.destructiveHint != true
    }
}
