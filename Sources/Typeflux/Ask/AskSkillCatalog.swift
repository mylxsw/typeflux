import Foundation

/// A per-message snapshot of available skills. Full instructions stay on disk
/// until the model calls `skill`; an empty catalog explicitly offers no skills.
struct AskSkillCatalogEntry: Codable, Equatable, Sendable {
    var name: String
    var description: String
}

enum AskSkillCatalog {
    static func definition(_ entries: [AskSkillCatalogEntry]) -> AskToolDefinition? {
        guard !entries.isEmpty else { return nil }
        let header = "Load the full instructions of a skill before doing a task it covers, then follow them. Skills:"
        // Keep every name while fitting the API's 8 KB tool-description budget.
        let overhead = entries.reduce(header.utf8.count) { $0 + $1.name.utf8.count + 5 }
        let budget = max(0, (8000 - overhead) / entries.count)
        let index = entries.map { entry in
            var detail = ""
            for character in entry.description {
                guard detail.utf8.count + String(character).utf8.count <= budget else { break }
                detail.append(character)
            }
            return "\n- \(entry.name): \(detail)"
        }.joined()
        let schema: [String: Any] = [
            "type": "object", "required": ["name"], "additionalProperties": false,
            "properties": ["name": ["type": "string", "enum": entries.map(\.name)]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys) else { return nil }
        return .init(name: "skill", description: header + index, parameters: JSONValue(data: data))
    }

    /// Nil preserves legacy toolsets. A catalog replaces only the skill tool;
    /// other tools and their authority are unchanged.
    static func applying(_ catalog: [AskSkillCatalogEntry]?, to tools: [AskToolDefinition],
                         allowAdding: Bool = false) -> [AskToolDefinition] {
        guard let catalog else { return tools }
        let offered = tools.contains { $0.name == "skill" }
        var result = tools.filter { $0.name != "skill" }
        if offered || allowAdding, let skill = definition(catalog) { result.append(skill) }
        return result
    }

    static func permits(_ call: AskToolCall, catalog: [AskSkillCatalogEntry]?) -> Bool {
        guard call.function.name == "skill", let catalog else { return true }
        guard let data = call.function.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = args["name"] as? String else { return false }
        return catalog.contains { $0.name == name }
    }
}
