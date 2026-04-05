import Foundation

extension SettingsStore {
    var strictEditApplyFallbackEnabled: Bool {
        get {
            let stored = defaults.object(forKey: "feature.strictEditApplyFallbackEnabled")
            return stored == nil ? true : defaults.bool(forKey: "feature.strictEditApplyFallbackEnabled")
        }
        set { defaults.set(newValue, forKey: "feature.strictEditApplyFallbackEnabled") }
    }

    var agentFrameworkEnabled: Bool {
        get { defaults.bool(forKey: "agent.frameworkEnabled") }
        set { defaults.set(newValue, forKey: "agent.frameworkEnabled") }
    }

    var agentEnabled: Bool {
        get {
            let stored = defaults.object(forKey: "agent.enabled")
            return stored == nil ? true : defaults.bool(forKey: "agent.enabled")
        }
        set { defaults.set(newValue, forKey: "agent.enabled") }
    }

    var agentStepLoggingEnabled: Bool {
        get { defaults.bool(forKey: "agent.stepLoggingEnabled") }
        set { defaults.set(newValue, forKey: "agent.stepLoggingEnabled") }
    }

    var mcpServers: [MCPServerConfig] {
        get {
            guard let data = defaults.data(forKey: "agent.mcpServers"),
                  let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
            else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "agent.mcpServers")
            }
        }
    }

    var agentSkills: [AgentSkill] {
        get {
            guard let data = defaults.data(forKey: "agent.skills"),
                  let skills = try? JSONDecoder().decode([AgentSkill].self, from: data)
            else {
                return BuiltinSkillCatalog.all
            }
            // Ensure builtin skills are always present
            var result = skills
            let savedNames = Set(skills.map(\.name))
            for builtin in BuiltinSkillCatalog.all where !savedNames.contains(builtin.name) {
                result.append(builtin)
            }
            return result
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "agent.skills")
            }
        }
    }
}
