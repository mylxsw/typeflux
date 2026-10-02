import Foundation

extension SettingsStore {
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

    /// Folders the Ask files tool may read and edit.
    var askFileAccessFolders: [String] {
        get { defaults.stringArray(forKey: "ask.fileAccessFolders") ?? [] }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { !$0.isEmpty && seen.insert($0).inserted }, forKey: "ask.fileAccessFolders")
        }
    }

    /// Whether Ask may run programs in the local sandbox.
    var askCodeExecutionEnabled: Bool {
        get { defaults.object(forKey: "ask.codeExecutionEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ask.codeExecutionEnabled") }
    }

    /// Runs Ask on this Mac with the user's own models even when signed in.
    var askLocalModeEnabled: Bool {
        get { defaults.bool(forKey: "ask.localMode") }
        set { defaults.set(newValue, forKey: "ask.localMode") }
    }
}
