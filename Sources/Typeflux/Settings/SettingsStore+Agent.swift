import Foundation

extension SettingsStore {
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

    /// Skills the user turned off; they are not offered to the model.
    var askDisabledSkills: Set<String> {
        get { Set(defaults.stringArray(forKey: "ask.disabledSkills") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ask.disabledSkills") }
    }

    /// Runs Ask on this Mac with the user's own models even when signed in.
    var askLocalModeEnabled: Bool {
        get { defaults.bool(forKey: "ask.localMode") }
        set { defaults.set(newValue, forKey: "ask.localMode") }
    }
}
