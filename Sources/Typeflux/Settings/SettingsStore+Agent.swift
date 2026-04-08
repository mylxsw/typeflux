import Foundation

extension SettingsStore {
    var strictEditApplyFallbackEnabled: Bool {
        get {
            let stored = defaults.object(forKey: "feature.strictEditApplyFallbackEnabled")
            return stored == nil ? true : defaults.bool(forKey: "feature.strictEditApplyFallbackEnabled")
        }
        set {
            defaults.set(newValue, forKey: "feature.strictEditApplyFallbackEnabled")
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
    }

    var agentFrameworkEnabled: Bool {
        get { defaults.bool(forKey: "agent.frameworkEnabled") }
        set {
            defaults.set(newValue, forKey: "agent.frameworkEnabled")
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
    }

    var agentEnabled: Bool {
        get {
            let stored = defaults.object(forKey: "agent.enabled")
            return stored == nil ? true : defaults.bool(forKey: "agent.enabled")
        }
        set {
            defaults.set(newValue, forKey: "agent.enabled")
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
    }

    var agentStepLoggingEnabled: Bool {
        get { defaults.bool(forKey: "agent.stepLoggingEnabled") }
        set {
            defaults.set(newValue, forKey: "agent.stepLoggingEnabled")
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
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
            NotificationCenter.default.post(name: .agentConfigurationDidChange, object: self)
        }
    }
}
