import Foundation

extension SettingsStore {
    var agentFrameworkEnabled: Bool {
        get { defaults.bool(forKey: "agent.frameworkEnabled") }
        set { defaults.set(newValue, forKey: "agent.frameworkEnabled") }
    }

    var agentStepLoggingEnabled: Bool {
        get { defaults.bool(forKey: "agent.stepLoggingEnabled") }
        set { defaults.set(newValue, forKey: "agent.stepLoggingEnabled") }
    }

    var mcpServers: [MCPServerConfig] {
        get {
            guard let data = defaults.data(forKey: "agent.mcpServers"),
                  let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
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
}
